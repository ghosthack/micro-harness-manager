package io.github.ghosthack.microhm.app.status;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;
import java.util.function.LongFunction;
import java.util.function.LongSupplier;
import java.util.function.Predicate;
import java.util.stream.Stream;

/** Finds a session's transcript from the files the harness process under a pane's shell
 * has open: Codex keeps its rollout open, Muse its session directory's lock. Each
 * harness process's answer is remembered so {@code lsof} is forked once per process
 * rather than once per status tick. A process whose lookup found nothing is retried
 * after {@link #MISS_RETRY_NANOS} (a just-started harness opens its file a moment
 * later); a found transcript is re-checked after {@link #HIT_REFRESH_NANOS} so a
 * {@code /new} or {@code /resume} inside the same process is still picked up. Entries for
 * processes that have exited are dropped. No {@code lsof} (Windows) finds nothing.
 * Thread-safe. */
public final class OpenFileLocator implements LongFunction<Optional<Path>> {

    static final long MISS_RETRY_NANOS = TimeUnit.SECONDS.toNanos(30);
    static final long HIT_REFRESH_NANOS = TimeUnit.MINUTES.toNanos(2);
    static final long PRUNE_INTERVAL_NANOS = TimeUnit.SECONDS.toNanos(30);

    /** A harness process, identified by pid and start time so a reused pid is not confused
     * with the process that held it before. */
    public record HarnessProcess(long pid, long startMillis) { }

    private record Lookup(Optional<Path> transcript, long checkedAtNanos) { }

    private final LongFunction<List<HarnessProcess>> harnessProcesses;
    private final Function<HarnessProcess, Optional<Path>> openTranscript;
    private final Predicate<HarnessProcess> stillRunning;
    private final LongSupplier nanoClock;
    private final ConcurrentHashMap<HarnessProcess, Lookup> lookups = new ConcurrentHashMap<>();
    private volatile long lastPruneNanos;

    /**
     * Over the live process table and {@code lsof}.
     *
     * @param executable   whether an executable's file name is the harness's
     * @param transcriptOf the transcript an open file shows the process is writing, or
     *                     empty when the file says nothing about one; of several, the
     *                     most recently modified wins
     */
    public static OpenFileLocator overLsof(Predicate<String> executable, Function<Path, Optional<Path>> transcriptOf) {
        return new OpenFileLocator(pane -> processes(pane, executable),
                process -> openTranscript(process.pid(), transcriptOf),
                OpenFileLocator::isRunning,
                System::nanoTime);
    }

    /** Test seam: the process walk, the per-process {@code lsof}, the liveness check and
     * the clock are all injected. */
    OpenFileLocator(LongFunction<List<HarnessProcess>> harnessProcesses,
                    Function<HarnessProcess, Optional<Path>> openTranscript,
                    Predicate<HarnessProcess> stillRunning,
                    LongSupplier nanoClock) {
        this.harnessProcesses = harnessProcesses;
        this.openTranscript = openTranscript;
        this.stillRunning = stillRunning;
        this.nanoClock = nanoClock;
        this.lastPruneNanos = nanoClock.getAsLong();
    }

    @Override
    public Optional<Path> apply(long paneProcessId) {
        long now = nanoClock.getAsLong();
        pruneIfDue(now);
        return harnessProcesses.apply(paneProcessId).stream()
                .map(process -> lookup(process, now))
                .flatMap(Optional::stream)
                .max(Comparator.comparingLong(OpenFileLocator::lastModified));
    }

    /** Number of harness processes currently remembered (for tests). */
    int cachedProcessCount() {
        return lookups.size();
    }

    private Optional<Path> lookup(HarnessProcess process, long now) {
        Lookup cached = lookups.get(process);
        if (cached != null) {
            long age = now - cached.checkedAtNanos();
            long ttl = cached.transcript().isPresent() ? HIT_REFRESH_NANOS : MISS_RETRY_NANOS;
            if (age < ttl) {
                return cached.transcript();
            }
        }
        Optional<Path> found = openTranscript.apply(process);
        lookups.put(process, new Lookup(found, now));
        return found;
    }

    private void pruneIfDue(long now) {
        if (now - lastPruneNanos < PRUNE_INTERVAL_NANOS) {
            return;
        }
        lastPruneNanos = now;
        lookups.keySet().removeIf(process -> !stillRunning.test(process));
    }

    /** The pane's shell and its descendants whose executable's file name passes
     * {@code executable}; empty when the pane is gone. */
    public static List<HarnessProcess> processes(long paneProcessId, Predicate<String> executable) {
        if (paneProcessId <= 0) {
            return List.of();
        }
        Optional<ProcessHandle> pane = ProcessHandle.of(paneProcessId);
        if (pane.isEmpty()) {
            return List.of();
        }
        return Stream.concat(Stream.of(pane.get()), pane.get().descendants())
                .flatMap(handle -> {
                    ProcessHandle.Info info = handle.info();
                    boolean harness = info.command()
                            .map(command -> {
                                Path name = Path.of(command).getFileName();
                                return name != null && executable.test(name.toString());
                            })
                            .orElse(false);
                    return harness
                            ? Stream.of(new HarnessProcess(handle.pid(), startMillis(info)))
                            : Stream.empty();
                })
                .toList();
    }

    private static boolean isRunning(HarnessProcess process) {
        return ProcessHandle.of(process.pid())
                .filter(ProcessHandle::isAlive)
                .map(handle -> startMillis(handle.info()) == process.startMillis())
                .orElse(false);
    }

    private static long startMillis(ProcessHandle.Info info) {
        return info.startInstant().map(Instant::toEpochMilli).orElse(0L);
    }

    private static Optional<Path> openTranscript(long processId, Function<Path, Optional<Path>> transcriptOf) {
        Process process = null;
        Path listing = null;
        try {
            // Into a file, not a pipe: nothing reads a pipe while this waits, so a process
            // with more open files than the pipe holds would block lsof until the timeout.
            listing = Files.createTempFile("microhm-lsof-", ".txt");
            process = new ProcessBuilder("lsof", "-a", "-p", Long.toString(processId), "-Fn")
                    .redirectErrorStream(true).redirectOutput(listing.toFile()).start();
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                return Optional.empty();
            }
            Path newest = null;
            try (BufferedReader output = new BufferedReader(new java.io.InputStreamReader(
                    Files.newInputStream(listing), java.nio.charset.Charset.defaultCharset()))) {
                for (String line; (line = output.readLine()) != null; ) {
                    if (!line.startsWith("n/")) {
                        continue;
                    }
                    Optional<Path> candidate;
                    try {
                        candidate = transcriptOf.apply(Path.of(line.substring(1)).toAbsolutePath().normalize());
                    } catch (RuntimeException e) {
                        continue; // not a path this platform can parse
                    }
                    if (candidate.isPresent()
                            && (newest == null || lastModified(candidate.get()) > lastModified(newest))) {
                        newest = candidate.get();
                    }
                }
            }
            return Optional.ofNullable(newest);
        } catch (IOException e) {
            return Optional.empty();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        } finally {
            if (process != null && process.isAlive()) {
                process.destroyForcibly();
            }
            if (listing != null) {
                try {
                    Files.deleteIfExists(listing);
                } catch (IOException ignored) {
                    // a leftover temp file is harmless
                }
            }
        }
    }

    static long lastModified(Path path) {
        try {
            return Files.getLastModifiedTime(path).toMillis();
        } catch (IOException e) {
            return Long.MIN_VALUE;
        }
    }
}
