package io.github.ghosthack.microhm.app.registry;

import java.util.List;

/**
 * Result of diffing the registry against what the daemon actually has running.
 *
 * @param liveManaged     registry entries whose session is alive right now
 * @param deadRegistered  registry entries whose session is gone — shown dead/resumable
 */
public record ReconciliationResult(
        List<SessionEntry> liveManaged,
        List<SessionEntry> deadRegistered) {
}
