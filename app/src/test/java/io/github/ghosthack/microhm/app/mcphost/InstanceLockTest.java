package io.github.ghosthack.microhm.app.mcphost;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class InstanceLockTest {

    @TempDir
    Path dir;

    @Test
    void eachRegistryHasItsOwnLock() {
        Path a = dir.resolve("a").resolve("sessions.json");
        Path b = dir.resolve("b").resolve("sessions.json");
        assertEquals(InstanceLock.Result.ACQUIRED, InstanceLock.tryAcquire(a));
        assertEquals(InstanceLock.Result.ACQUIRED, InstanceLock.tryAcquire(a), "re-acquiring is idempotent");
        assertEquals(InstanceLock.Result.ACQUIRED, InstanceLock.tryAcquire(b));
    }

    @Test
    void waitingForAHeldLockGivesUpAfterTheTimeout() throws Exception {
        Path registry = dir.resolve("c").resolve("sessions.json");
        java.nio.file.Files.createDirectories(registry.getParent());
        // Another holder in this JVM looks to tryLock like an overlapping lock: HELD.
        try (FileChannel other = FileChannel.open(InstanceLock.lockFile(registry),
                StandardOpenOption.CREATE, StandardOpenOption.WRITE);
             FileLock ignored = other.lock()) {
            long t0 = System.nanoTime();
            assertEquals(InstanceLock.Result.HELD, InstanceLock.acquire(registry, Duration.ofMillis(300)));
            assertTrue(System.nanoTime() - t0 >= Duration.ofMillis(300).toNanos());
        }
        assertEquals(InstanceLock.Result.ACQUIRED, InstanceLock.tryAcquire(registry));
    }
}
