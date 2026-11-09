package io.github.ghosthack.microhm.app.harness;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;

/**
 * Where Muse keeps its conversations: one directory per session,
 * {@code <root>/YYYY/MM/DD/<session id>/}, holding the session's event log
 * {@code session.jsonl} (JSONL; the assistant's replies are its
 * {@code assistant_message_committed} events) next to locks, databases and sub-agent
 * folders. The root is {@code $XDG_DATA_HOME/muse/sessions}, else
 * {@code ~/.local/share/muse/sessions}. A running Muse holds its session directory's
 * {@code .session.lock} open, which is how a pane's session is told from the others.
 */
public final class MuseSessions {

    /** The event log in a session directory. */
    public static final String TRANSCRIPT = "session.jsonl";

    private static final String SESSION_ID = "[A-Za-z0-9-]+";

    private MuseSessions() {
    }

    /** {@code $XDG_DATA_HOME/muse/sessions}, else {@code ~/.local/share/muse/sessions}. */
    public static Path root() {
        String data = System.getenv("XDG_DATA_HOME");
        Path base = data != null && !data.isBlank()
                ? Path.of(data)
                : Path.of(System.getProperty("user.home"), ".local", "share");
        return base.resolve("muse").resolve("sessions");
    }

    /** Whether an executable's file name is Muse's ({@code muse}, or the versioned
     * {@code muse-bin-<version>} its launcher runs). */
    public static boolean isExecutable(String fileName) {
        return fileName.equals("muse") || fileName.startsWith("muse-");
    }

    /**
     * The {@code session.jsonl} of the session directory {@code open} is in (its lock, its
     * log or anything below it), when that log exists; empty for any file outside a dated
     * session directory under {@code root} (the index database, the view caches, …).
     */
    public static Optional<Path> transcriptOf(Path root, Path open) {
        Path base = root.toAbsolutePath().normalize();
        Path file = open.toAbsolutePath().normalize();
        if (!file.startsWith(base)) {
            return Optional.empty();
        }
        Path relative = base.relativize(file);
        // YYYY / MM / DD / <id> / <something in it>
        if (relative.getNameCount() < 5
                || !relative.getName(0).toString().matches("\\d{4}")
                || !relative.getName(1).toString().matches("\\d{2}")
                || !relative.getName(2).toString().matches("\\d{2}")
                || !relative.getName(3).toString().matches(SESSION_ID)) {
            return Optional.empty();
        }
        Path transcript = base.resolve(relative.subpath(0, 4)).resolve(TRANSCRIPT);
        return Files.isRegularFile(transcript) ? Optional.of(transcript) : Optional.empty();
    }
}
