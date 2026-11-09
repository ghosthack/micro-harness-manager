package io.github.ghosthack.microhm.app.status;

import io.github.ghosthack.microhm.app.status.OpenFileLocator.HarnessProcess;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

final class OpenFileLocatorTest {

    private static final Path ROLLOUT =
            Path.of("/codex/sessions/rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl");

    @Test
    void lsofRunsOnceForTheSameHarnessProcessAcrossTicks() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicLong clock = new AtomicLong();
        OpenFileLocator locator = new OpenFileLocator(
                pane -> List.of(new HarnessProcess(100, 1)),
                process -> {
                    lsofCalls.incrementAndGet();
                    return Optional.of(ROLLOUT);
                },
                process -> true, clock::get);

        for (int tick = 0; tick < 20; tick++) {
            assertEquals(ROLLOUT, locator.apply(42).orElseThrow());
            clock.addAndGet(TimeUnit.SECONDS.toNanos(4));
        }
        assertEquals(1, lsofCalls.get());
    }

    @Test
    void aNewHarnessProcessIsLookedUpAgain() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicReference<HarnessProcess> current = new AtomicReference<>(new HarnessProcess(100, 1));
        OpenFileLocator locator = new OpenFileLocator(
                pane -> List.of(current.get()),
                process -> {
                    lsofCalls.incrementAndGet();
                    return Optional.of(ROLLOUT);
                },
                process -> true, () -> 0L);

        locator.apply(42);
        locator.apply(42);
        current.set(new HarnessProcess(101, 2));
        locator.apply(42);
        locator.apply(42);
        // The same pid reused by a later process is a different process.
        current.set(new HarnessProcess(100, 3));
        locator.apply(42);
        assertEquals(3, lsofCalls.get());
    }

    @Test
    void aMissIsRetriedOnlyAfterBackOff() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicLong clock = new AtomicLong();
        OpenFileLocator locator = new OpenFileLocator(
                pane -> List.of(new HarnessProcess(100, 1)),
                process -> lsofCalls.incrementAndGet() < 2 ? Optional.empty() : Optional.of(ROLLOUT),
                process -> true, clock::get);

        assertTrue(locator.apply(42).isEmpty());
        clock.addAndGet(OpenFileLocator.MISS_RETRY_NANOS - 1);
        assertTrue(locator.apply(42).isEmpty());
        assertEquals(1, lsofCalls.get());
        clock.addAndGet(1);
        assertEquals(ROLLOUT, locator.apply(42).orElseThrow());
        assertEquals(2, lsofCalls.get());
    }

    @Test
    void aHitIsRecheckedAfterTheRefreshInterval() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicLong clock = new AtomicLong();
        OpenFileLocator locator = new OpenFileLocator(
                pane -> List.of(new HarnessProcess(100, 1)),
                process -> {
                    lsofCalls.incrementAndGet();
                    return Optional.of(ROLLOUT);
                },
                process -> true, clock::get);

        locator.apply(42);
        clock.addAndGet(OpenFileLocator.HIT_REFRESH_NANOS);
        locator.apply(42);
        assertEquals(2, lsofCalls.get());
    }

    @Test
    void exitedProcessesAreForgotten() {
        AtomicLong clock = new AtomicLong();
        Set<Long> alive = new HashSet<>(Set.of(100L, 101L));
        OpenFileLocator locator = new OpenFileLocator(
                pane -> List.of(new HarnessProcess(pane, 1)),
                process -> Optional.of(ROLLOUT),
                process -> alive.contains(process.pid()), clock::get);

        locator.apply(100);
        locator.apply(101);
        assertEquals(2, locator.cachedProcessCount());
        alive.remove(100L);
        clock.addAndGet(OpenFileLocator.PRUNE_INTERVAL_NANOS);
        locator.apply(101);
        assertEquals(1, locator.cachedProcessCount());
    }

    @TempDir
    Path dir;

    /** The real thing: this JVM holds a file open, and lsof over the JVM's own process
     * finds it and maps it to the transcript beside it. */
    @Test
    void overLsofFindsTheFileTheHarnessProcessHoldsOpen() throws Exception {
        assumeTrue(!System.getProperty("os.name", "").startsWith("Windows"), "no lsof on Windows");
        assumeTrue(Files.isExecutable(Path.of("/usr/sbin/lsof")) || Files.isExecutable(Path.of("/usr/bin/lsof"))
                || Files.isExecutable(Path.of("/bin/lsof")), "lsof installed");
        Path session = Files.createDirectories(dir.resolve("s1")).toRealPath();
        Path transcript = Files.writeString(session.resolve("log.jsonl"), "{}\n");
        Path lock = Files.createFile(session.resolve(".lock"));
        long self = ProcessHandle.current().pid();
        try (RandomAccessFile held = new RandomAccessFile(lock.toFile(), "rw")) {
            OpenFileLocator locator = OpenFileLocator.overLsof(name -> name.equals("java") || name.equals("java.exe"),
                    open -> open.getFileName().toString().equals(".lock") && open.startsWith(session)
                            ? Optional.of(open.resolveSibling("log.jsonl")) : Optional.empty());
            assertEquals(Optional.of(transcript), locator.apply(self));
            OpenFileLocator nobody = OpenFileLocator.overLsof(name -> name.equals("no-such-harness"),
                    open -> Optional.of(open));
            assertEquals(Optional.empty(), nobody.apply(self), "no harness process under the pane");
        }
        assertEquals(List.of(), OpenFileLocator.processes(-1, name -> true));
    }
}
