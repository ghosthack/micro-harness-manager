package io.github.ghosthack.microhm.app.state;

import java.time.Instant;
import java.util.List;

/**
 * One capture of a session's rendered text, plus its foreground process name when the
 * daemon could report it. {@code paneTitle} is the title the program in the session
 * set via OSC (e.g. Claude Code's /rename), empty when never set or the daemon couldn't
 * report it. {@code paneProcessId} is the session shell's PID, used to discover provider metadata without changing pane contents.
 */
public record Screen(String text, boolean paneDead, Instant capturedAt, String foregroundCommand,
                     long paneProcessId, String paneTitle) {

    public Screen(String text, boolean paneDead, Instant capturedAt) {
        this(text, paneDead, capturedAt, "", -1, "");
    }

    public Screen(String text, boolean paneDead, Instant capturedAt, String foregroundCommand) {
        this(text, paneDead, capturedAt, foregroundCommand, -1, "");
    }

    public Screen(String text, boolean paneDead, Instant capturedAt, String foregroundCommand,
                  String paneTitle) {
        this(text, paneDead, capturedAt, foregroundCommand, -1, paneTitle);
    }

    /** Last {@code n} non-blank lines, oldest first — the region prompts live in. */
    public List<String> tailLines(int n) {
        List<String> nonBlank = text.lines().filter(l -> !l.isBlank()).toList();
        return nonBlank.subList(Math.max(0, nonBlank.size() - n), nonBlank.size());
    }
}
