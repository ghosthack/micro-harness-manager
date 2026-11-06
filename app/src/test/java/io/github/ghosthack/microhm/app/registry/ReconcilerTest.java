package io.github.ghosthack.microhm.app.registry;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class ReconcilerTest {

    private static SessionEntry entry(String sessionName) {
        return new SessionEntry(sessionName, "/Users/x/Projects/foo", HarnessType.CLAUDE_CODE,
                null, Instant.EPOCH);
    }

    @Test
    void managedAndLiveIsReportedAsLiveManaged() {
        SessionEntry alive = entry("mhm-foo");
        ReconciliationResult result = Reconciler.reconcile(List.of(alive), List.of("mhm-foo"));

        assertEquals(List.of(alive), result.liveManaged());
        assertTrue(result.deadRegistered().isEmpty());
    }

    @Test
    void registeredButNotLiveIsDeadRegistered() {
        SessionEntry dead = entry("mhm-gone");
        ReconciliationResult result = Reconciler.reconcile(List.of(dead), List.of());

        assertTrue(result.liveManaged().isEmpty());
        assertEquals(List.of(dead), result.deadRegistered());
    }

    @Test
    void liveSessionsWithNoRegistryEntryAreIgnored() {
        ReconciliationResult result = Reconciler.reconcile(List.of(), List.of("mhm-orphan", "work"));

        assertTrue(result.liveManaged().isEmpty());
        assertTrue(result.deadRegistered().isEmpty());
    }

    @Test
    void mixedLiveAndDeadKeepRegistryOrder() {
        SessionEntry alive = entry("mhm-alive");
        SessionEntry dead = entry("mhm-dead");
        SessionEntry alsoAlive = entry("mhm-also");
        ReconciliationResult result = Reconciler.reconcile(
                List.of(alive, dead, alsoAlive),
                List.of("mhm-also", "mhm-alive", "unrelated"));

        assertEquals(List.of(alive, alsoAlive), result.liveManaged());
        assertEquals(List.of(dead), result.deadRegistered());
    }
}
