package io.github.ghosthack.microhm.app.status;

import io.github.ghosthack.microhm.app.status.CodexRolloutLocator.CodexProcess;
import org.junit.jupiter.api.Test;

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

final class CodexRolloutLocatorTest {

    private static final Path ROLLOUT =
            Path.of("/codex/sessions/rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl");

    @Test
    void lsofRunsOnceForTheSameCodexProcessAcrossTicks() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicLong clock = new AtomicLong();
        CodexRolloutLocator locator = new CodexRolloutLocator(
                pane -> List.of(new CodexProcess(100, 1)),
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
    void aNewCodexProcessIsLookedUpAgain() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicReference<CodexProcess> current = new AtomicReference<>(new CodexProcess(100, 1));
        CodexRolloutLocator locator = new CodexRolloutLocator(
                pane -> List.of(current.get()),
                process -> {
                    lsofCalls.incrementAndGet();
                    return Optional.of(ROLLOUT);
                },
                process -> true, () -> 0L);

        locator.apply(42);
        locator.apply(42);
        current.set(new CodexProcess(101, 2));
        locator.apply(42);
        locator.apply(42);
        // The same pid reused by a later process is a different process.
        current.set(new CodexProcess(100, 3));
        locator.apply(42);
        assertEquals(3, lsofCalls.get());
    }

    @Test
    void aMissIsRetriedOnlyAfterBackOff() {
        AtomicInteger lsofCalls = new AtomicInteger();
        AtomicLong clock = new AtomicLong();
        CodexRolloutLocator locator = new CodexRolloutLocator(
                pane -> List.of(new CodexProcess(100, 1)),
                process -> lsofCalls.incrementAndGet() < 2 ? Optional.empty() : Optional.of(ROLLOUT),
                process -> true, clock::get);

        assertTrue(locator.apply(42).isEmpty());
        clock.addAndGet(CodexRolloutLocator.MISS_RETRY_NANOS - 1);
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
        CodexRolloutLocator locator = new CodexRolloutLocator(
                pane -> List.of(new CodexProcess(100, 1)),
                process -> {
                    lsofCalls.incrementAndGet();
                    return Optional.of(ROLLOUT);
                },
                process -> true, clock::get);

        locator.apply(42);
        clock.addAndGet(CodexRolloutLocator.HIT_REFRESH_NANOS);
        locator.apply(42);
        assertEquals(2, lsofCalls.get());
    }

    @Test
    void exitedProcessesAreForgotten() {
        AtomicLong clock = new AtomicLong();
        Set<Long> alive = new HashSet<>(Set.of(100L, 101L));
        CodexRolloutLocator locator = new CodexRolloutLocator(
                pane -> List.of(new CodexProcess(pane, 1)),
                process -> Optional.of(ROLLOUT),
                process -> alive.contains(process.pid()), clock::get);

        locator.apply(100);
        locator.apply(101);
        assertEquals(2, locator.cachedProcessCount());
        alive.remove(100L);
        clock.addAndGet(CodexRolloutLocator.PRUNE_INTERVAL_NANOS);
        locator.apply(101);
        assertEquals(1, locator.cachedProcessCount());
    }
}
