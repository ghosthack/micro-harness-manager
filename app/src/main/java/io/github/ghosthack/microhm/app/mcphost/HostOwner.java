package io.github.ghosthack.microhm.app.mcphost;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;
import java.time.Instant;
import java.util.Optional;
import java.util.function.LongFunction;

/**
 * Who the headless MCP host is: an {@code mcp-host.pid} file beside the registry holding
 * the host's pid and its start instant. The pair, not the pid alone, identifies the
 * process, so the app never signals an unrelated process that reused the number.
 */
public final class HostOwner {

    /** The recorded identity of a host process. */
    public record Record(long pid, long startEpochMillis) {

        String encode() {
            return pid + " " + startEpochMillis + "\n";
        }

        static Optional<Record> decode(String text) {
            String[] parts = text.strip().split("\\s+");
            if (parts.length != 2) {
                return Optional.empty();
            }
            try {
                return Optional.of(new Record(Long.parseLong(parts[0]), Long.parseLong(parts[1])));
            } catch (NumberFormatException e) {
                return Optional.empty();
            }
        }
    }

    /** Start instants are compared with this slack: platforms report them at different
     * resolutions, and a reused pid starts far later than that. */
    static final Duration START_TOLERANCE = Duration.ofSeconds(2);

    public static Path file(Path registryFile) {
        return registryFile.toAbsolutePath().resolveSibling("mcp-host.pid");
    }

    /** This process's record, or empty when the platform does not report a start time. */
    public static Optional<Record> current() {
        ProcessHandle self = ProcessHandle.current();
        return self.info().startInstant().map(start -> new Record(self.pid(), start.toEpochMilli()));
    }

    /** Writes {@code record} atomically, so a reader never sees half of it. */
    public static void write(Path registryFile, Record record) throws IOException {
        Path target = file(registryFile);
        Path tmp = target.resolveSibling(target.getFileName() + ".tmp");
        Files.writeString(tmp, record.encode(), StandardCharsets.UTF_8);
        Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
    }

    public static Optional<Record> read(Path registryFile) {
        try {
            return Record.decode(Files.readString(file(registryFile), StandardCharsets.UTF_8));
        } catch (IOException e) {
            return Optional.empty();
        }
    }

    /** Removes the file only if it still names {@code record}: a newer host's file stays. */
    public static void clear(Path registryFile, Record record) {
        if (read(registryFile).filter(record::equals).isPresent()) {
            try {
                Files.deleteIfExists(file(registryFile));
            } catch (IOException ignored) {
                // A stale file is harmless: it fails verification.
            }
        }
    }

    /** The live process {@code record} names, if it is still that process. */
    public static Optional<ProcessHandle> live(Record record) {
        return live(record, pid -> ProcessHandle.of(pid));
    }

    static Optional<ProcessHandle> live(Record record, LongFunction<Optional<ProcessHandle>> lookup) {
        return lookup.apply(record.pid())
                .filter(ProcessHandle::isAlive)
                .filter(handle -> handle.info().startInstant()
                        .map(start -> Math.abs(start.toEpochMilli() - record.startEpochMillis())
                                <= START_TOLERANCE.toMillis())
                        .orElse(false));
    }

    /**
     * Stops the recorded host, if one is running, and waits up to {@code timeout} for it to
     * exit (it releases the instance lock as it does). True when no host is left running.
     */
    public static boolean stop(Path registryFile, Duration timeout) throws InterruptedException {
        Optional<Record> record = read(registryFile);
        if (record.isEmpty()) {
            return true;
        }
        Optional<ProcessHandle> host = live(record.get());
        if (host.isEmpty()) {
            clear(registryFile, record.get());
            return true;
        }
        host.get().destroy(); // SIGTERM: its shutdown hook stops the server and clears the file
        long deadline = System.nanoTime() + timeout.toNanos();
        while (host.get().isAlive() && System.nanoTime() - deadline < 0) {
            Thread.sleep(50);
        }
        if (host.get().isAlive()) {
            host.get().destroyForcibly();
            Thread.sleep(200);
        }
        clear(registryFile, record.get());
        return !host.get().isAlive();
    }

    /** For log lines. */
    static String describe(Record record) {
        return "pid " + record.pid() + ", started " + Instant.ofEpochMilli(record.startEpochMillis());
    }

    private HostOwner() {
    }
}
