package io.github.ghosthack.microhm.app.mcphost;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

/**
 * The registry's single-owner lock: an {@code instance.lock} file beside the registry
 * file. Saves are full-snapshot rewrites, so two processes on one registry would clobber
 * each other's entries; the app and the headless MCP host both take this lock and hand
 * it over rather than share it. Held for the process lifetime; the OS releases it on
 * exit, however the process ends.
 */
public final class InstanceLock {

    /** What {@link #tryAcquire} found. */
    public enum Result {
        /** This process now holds the lock. */
        ACQUIRED,
        /** Another process holds it. */
        HELD,
        /** The lock could not even be attempted (unwritable directory, exotic
         * filesystem); callers run unguarded, as a working session manager beats
         * refusing to start. */
        UNAVAILABLE,
    }

    private static final Duration POLL = Duration.ofMillis(100);

    /** Never closed deliberately: kept reachable so each lock lives as long as the JVM.
     * Keyed by lock file, as tests take locks on scratch registries. */
    private static final Map<Path, FileChannel> HELD = new HashMap<>();

    public static Path lockFile(Path registryFile) {
        return registryFile.toAbsolutePath().resolveSibling("instance.lock");
    }

    /** One attempt. */
    public static synchronized Result tryAcquire(Path registryFile) {
        Path lockFile = lockFile(registryFile);
        if (HELD.containsKey(lockFile)) {
            return Result.ACQUIRED;
        }
        try {
            Path parent = lockFile.getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            FileChannel channel = FileChannel.open(lockFile, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
            Optional<FileLock> lock;
            try {
                lock = Optional.ofNullable(channel.tryLock());
            } catch (OverlappingFileLockException e) {
                lock = Optional.empty();
            }
            if (lock.isEmpty()) {
                channel.close();
                return Result.HELD;
            }
            HELD.put(lockFile, channel);
            return Result.ACQUIRED;
        } catch (IOException e) {
            return Result.UNAVAILABLE;
        }
    }

    /** Retries until the lock is free or {@code timeout} passes; HELD on timeout. */
    public static Result acquire(Path registryFile, Duration timeout) throws InterruptedException {
        long deadline = System.nanoTime() + timeout.toNanos();
        while (true) {
            Result result = tryAcquire(registryFile);
            if (result != Result.HELD || System.nanoTime() - deadline >= 0) {
                return result;
            }
            Thread.sleep(POLL);
        }
    }

    private InstanceLock() {
    }
}
