package io.github.ghosthack.microhm.app.registry;

import io.github.ghosthack.microhm.app.harness.HarnessType;

import java.time.Instant;
import java.util.Optional;

/**
 * One managed session: the daemon session that hosts it, the harness running inside
 * it, and enough to resume that harness conversation later. Conceptually the mapping is
 * harness-session -> daemon session; in practice they are 1-1, so
 * {@link #sessionName()} (always {@value Reconciler#SESSION_PREFIX}-prefixed) is the
 * registry's key. Rows are only ever rebuilt through the with-ers or
 * {@link #newlyCreated}, so no flow can silently drop a field on the way through.
 */
public record SessionEntry(
        String sessionName,
        String projectPath,
        HarnessType harnessType,
        String harnessSessionId,
        Instant createdAt,
        String displayName) {

    /** Entry without a user-assigned sidebar name. */
    public SessionEntry(String sessionName, String projectPath, HarnessType harnessType,
                        String harnessSessionId, Instant createdAt) {
        this(sessionName, projectPath, harnessType, harnessSessionId, createdAt, null);
    }

    /** Returns a copy with a persisted sidebar name. Blank means use the live pane title
     * (when present), then fall back to the session name. */
    public SessionEntry withDisplayName(String displayName) {
        String normalized = displayName == null || displayName.isBlank() ? null : displayName.strip();
        return new SessionEntry(sessionName, projectPath, harnessType, harnessSessionId,
                createdAt, normalized);
    }

    /** Returns a copy associated with the provider conversation recovered at exit. */
    public SessionEntry withHarnessSessionId(String harnessSessionId) {
        String normalized = harnessSessionId == null || harnessSessionId.isBlank()
                ? null : harnessSessionId.strip();
        return new SessionEntry(sessionName, projectPath, harnessType, normalized,
                createdAt, displayName);
    }

    /** {@code harnessSessionId} is optional (blank/null means "no resume id recorded yet"). */
    public Optional<String> harnessSessionIdOpt() {
        return harnessSessionId == null || harnessSessionId.isBlank()
                ? Optional.empty() : Optional.of(harnessSessionId);
    }

    /** New entry for a session created just now. */
    public static SessionEntry newlyCreated(String sessionName, String projectPath,
                                              HarnessType harnessType, String harnessSessionId) {
        return new SessionEntry(sessionName, projectPath, harnessType, harnessSessionId, Instant.now(), null);
    }
}
