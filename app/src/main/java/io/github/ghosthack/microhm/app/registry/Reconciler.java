package io.github.ghosthack.microhm.app.registry;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Startup (and on-demand refresh) reconciliation: the daemon's live list diffed against
 * the registry. A pure function of its inputs — the caller reads the registry and the
 * host — so it needs no live daemon to test and this package does not depend on
 * {@code host}.
 */
public final class Reconciler {

    /** Every session this app owns is named with this prefix. */
    public static final String SESSION_PREFIX = "mhm-";

    public static ReconciliationResult reconcile(List<SessionEntry> registered, List<String> liveSessions) {
        Set<String> live = new HashSet<>(liveSessions);
        List<SessionEntry> liveManaged = new ArrayList<>();
        List<SessionEntry> deadRegistered = new ArrayList<>();
        for (SessionEntry entry : registered) {
            if (live.contains(entry.sessionName())) {
                liveManaged.add(entry);
            } else {
                deadRegistered.add(entry);
            }
        }
        return new ReconciliationResult(liveManaged, deadRegistered);
    }

    private Reconciler() {
    }
}
