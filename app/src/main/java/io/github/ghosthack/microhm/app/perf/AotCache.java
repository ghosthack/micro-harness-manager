package io.github.ghosthack.microhm.app.perf;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.concurrent.TimeUnit;

/**
 * The app's AOT cache, made on the first launch. The packaged launcher always passes
 * {@code -XX:AOTCache=$HOME/.micro-harness-manager/aot/microhm-VERSION.aot}; while that
 * file is missing the JVM just starts without it. Then, a little after the window is up,
 * the app records a start of itself in the background (a separate JVM with the same
 * options, never showing a window) and writes the cache there, so every later launch of
 * this version opens its window in about half the time. Older versions' caches in the
 * same directory are deleted.
 *
 * <p>Runs from source pass no {@code -XX:AOTCache}, so nothing is made.
 */
public final class AotCache {

    private static final Logger LOG = LoggerFactory.getLogger(AotCache.class);

    /** The app flag a recording run starts with: a normal start that builds the window
     * without showing it, then quits. */
    public static final String TRAIN_FLAG = "--aot-train";

    private static final String CACHE_OPTION = "-XX:AOTCache=";
    private static final Duration STEP_TIMEOUT = Duration.ofMinutes(2);

    /** What the cache is doing for this run of the app. */
    public enum State {
        /** No {@code -XX:AOTCache} option (a run from source): no cache is made. */
        NOT_CONFIGURED("not used (run from source)"),
        /** The cache was there when this run started, so the JVM loaded it. */
        USED("used for this launch"),
        /** Missing at launch; will be made shortly after the window is up. */
        MISSING("missing; will be made in the background"),
        CREATING("being made in the background"),
        /** Made during this run: the next launch uses it. */
        CREATED("made; the next launch will use it"),
        /** Another copy of the app is making it. */
        BUSY("being made by another window"),
        FAILED("not available with this Java version");

        private final String description;

        State(String description) {
            this.description = description;
        }

        public String description() {
            return description;
        }
    }

    private static volatile AotCache current;

    private final Path path;
    private volatile State state;

    private AotCache(Path path, State state) {
        this.path = path;
        this.state = state;
    }

    /** This run's cache, decided from the JVM's options at startup. */
    public static synchronized AotCache current() {
        if (current == null) {
            current = detect(ManagementFactory.getRuntimeMXBean().getInputArguments(),
                    Instant.ofEpochMilli(ManagementFactory.getRuntimeMXBean().getStartTime()));
        }
        return current;
    }

    static AotCache detect(List<String> jvmArguments, Instant jvmStart) {
        Optional<Path> configured = configuredPath(jvmArguments);
        if (configured.isEmpty()) {
            return new AotCache(null, State.NOT_CONFIGURED);
        }
        Path path = configured.get();
        boolean usable = false;
        try {
            usable = Files.size(path) > 0 && Files.getLastModifiedTime(path).toInstant().isBefore(jvmStart);
        } catch (IOException e) {
            // missing
        }
        if (!usable && Files.exists(failedMarker(path))) {
            return new AotCache(path, State.FAILED);
        }
        return new AotCache(path, usable ? State.USED : State.MISSING);
    }

    /** The cache path the JVM was given, when it is a real absolute path (a launcher
     * that left a {@code $VARIABLE} unexpanded gives none). */
    static Optional<Path> configuredPath(List<String> jvmArguments) {
        String value = null;
        for (String argument : jvmArguments) {
            if (argument.startsWith(CACHE_OPTION)) {
                value = argument.substring(CACHE_OPTION.length());
            }
        }
        if (value == null || value.isBlank() || value.contains("$") || value.contains("%")) {
            return Optional.empty();
        }
        Path path = Path.of(value);
        return path.isAbsolute() ? Optional.of(path) : Optional.empty();
    }

    public State state() {
        return state;
    }

    /** The cache file, or empty when none is configured. */
    public Optional<Path> path() {
        return Optional.ofNullable(path);
    }

    /** The cache file's size, or -1 when it does not exist. */
    public long size() {
        try {
            return path == null ? -1 : Files.size(path);
        } catch (IOException e) {
            return -1;
        }
    }

    /** Makes the cache on a background thread after {@code delay}, when it is missing. */
    public void createLaterIfMissing(Duration delay, String mainClass) {
        if (state != State.MISSING) {
            return;
        }
        Thread.ofPlatform().daemon().name("mhm-aot-cache").start(() -> {
            try {
                Thread.sleep(delay);
                create(mainClass);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
    }

    private void create(String mainClass) throws InterruptedException {
        Path dir = path.getParent();
        try {
            Files.createDirectories(dir);
            try (FileChannel channel = FileChannel.open(dir.resolve(".lock"),
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
                 FileLock lock = channel.tryLock()) {
                if (lock == null) {
                    state = State.BUSY;
                    return;
                }
                if (Files.exists(path)) {
                    state = State.CREATED;
                    return;
                }
                if (Files.exists(failedMarker(path))) {
                    state = State.FAILED;
                    return;
                }
                state = State.CREATING;
                // Older versions' caches (and leftovers) go first, whatever happens next.
                deleteOthers(dir);
                long started = System.nanoTime();
                makeVerified(dir, mainClass);
                state = State.CREATED;
                LOG.info("AOT cache made in {} ms: {}", (System.nanoTime() - started) / 1_000_000, path);
            }
        } catch (IOException | RuntimeException e) {
            state = State.FAILED;
            LOG.warn("could not make the AOT cache {}: {}", path, e.toString());
        }
    }

    /**
     * A cache that the JVM fails to start with leaves the app unable to open at all (the
     * JVM stops before any app code runs: JDK 26.0.2 does this with AOT-linked classes,
     * "Unexpected exception when loading aot-linked classes"). So each cache is tried by a
     * real start of the app with it before it is moved into place: first the full cache,
     * then one without AOT-linked classes (most of the gain, and it works there). When
     * neither starts, a marker keeps this version from trying again.
     */
    private void makeVerified(Path dir, String mainClass) throws IOException, InterruptedException {
        IOException last = null;
        for (boolean linking : new boolean[]{true, false}) {
            try {
                record(dir, mainClass, linking);
                return;
            } catch (IOException e) {
                last = e;
                LOG.info("AOT cache {} class linking was not usable: {}", linking ? "with" : "without", e.getMessage());
            }
        }
        try {
            Files.writeString(failedMarker(path), String.valueOf(last));
        } catch (IOException e) {
            LOG.debug("could not write {}: {}", failedMarker(path), e.toString());
        }
        throw last;
    }

    /** Beside the cache: this version's caches would not start, so none is made. */
    static Path failedMarker(Path cache) {
        return cache.resolveSibling(cache.getFileName() + ".failed");
    }

    /** Records a start (a JVM that builds the window without showing it), assembles the
     * cache from the recording, and starts the app once more with it (the same window-less
     * run) before moving it into place: a cache only replaces nothing once a JVM has
     * started with it and exited cleanly. */
    private void record(Path dir, String mainClass, boolean linking) throws IOException, InterruptedException {
        Path config = dir.resolve(path.getFileName() + ".config.tmp");
        Path partial = dir.resolve(path.getFileName() + ".tmp");
        Path scratch = Files.createTempDirectory("microhm-aot");
        try {
            List<String> base = baseCommand();
            if (!linking) {
                base.add("-XX:-AOTClassLinking");
            }
            String classPath = System.getProperty("java.class.path");
            List<String> appRun = List.of("-cp", classPath, mainClass, TRAIN_FLAG,
                    "--registry=" + scratch.resolve("sessions.json"), "--mux-home=" + scratch.resolve("mux"));

            List<String> recordRun = new ArrayList<>(base);
            recordRun.addAll(List.of("-XX:AOTMode=record", "-XX:AOTConfiguration=" + config));
            recordRun.addAll(appRun);
            run(recordRun, "recording");

            List<String> createRun = new ArrayList<>(base);
            createRun.addAll(List.of("-XX:AOTMode=create", "-XX:AOTConfiguration=" + config,
                    "-XX:AOTCache=" + partial, "-cp", classPath, mainClass));
            run(createRun, "assembly");

            if (!Files.isRegularFile(partial) || Files.size(partial) == 0) {
                throw new IOException("the JVM wrote no cache");
            }

            // The check: started exactly as the launcher starts (its options, which include
            // no -XX:-AOTClassLinking), with the new cache.
            List<String> checkRun = new ArrayList<>(baseCommand());
            checkRun.add("-XX:AOTCache=" + partial);
            checkRun.addAll(appRun);
            run(checkRun, "check");

            Files.move(partial, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(config);
            Files.deleteIfExists(partial);
            deleteTree(scratch);
        }
    }

    /** This JVM's binary and options, minus the AOT ones each step sets itself. */
    private static List<String> baseCommand() {
        boolean windows = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows");
        List<String> command = new ArrayList<>();
        command.add(Path.of(System.getProperty("java.home"), "bin", windows ? "java.exe" : "java").toString());
        for (String argument : ManagementFactory.getRuntimeMXBean().getInputArguments()) {
            if (!argument.startsWith("-XX:AOT")) {
                command.add(argument);
            }
        }
        return command;
    }

    private static void run(List<String> command, String step) throws IOException, InterruptedException {
        Process process = new ProcessBuilder(command)
                .redirectErrorStream(true)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .start();
        if (!process.waitFor(STEP_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS)) {
            process.destroyForcibly();
            throw new IOException("the AOT " + step + " run did not finish");
        }
        if (process.exitValue() != 0) {
            throw new IOException("the AOT " + step + " run exited with " + process.exitValue());
        }
    }

    /** Older versions' caches and leftovers of interrupted runs. */
    private void deleteOthers(Path dir) {
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(dir, "microhm-*")) {
            for (Path entry : entries) {
                if (!entry.equals(path)) {
                    Files.deleteIfExists(entry);
                }
            }
        } catch (IOException e) {
            LOG.debug("could not tidy {}: {}", dir, e.toString());
        }
    }

    private static void deleteTree(Path root) {
        try (var walk = Files.walk(root)) {
            walk.sorted(java.util.Comparator.reverseOrder()).forEach(p -> {
                try {
                    Files.deleteIfExists(p);
                } catch (IOException e) {
                    // best effort
                }
            });
        } catch (IOException e) {
            // best effort
        }
    }
}
