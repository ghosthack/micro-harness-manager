package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.state.SessionState;


/**
 * One row in the sidebar: a registered {@link SessionEntry}, live or dead.
 */
final class SidebarEntry {

    enum Status { LIVE, DEAD }

    private final Status status;
    private final SessionEntry sessionEntry;
    private final String sessionName;
    private boolean attached;

    /** Latest status-poll result. Null until the first poll tick lands (or always, for
     * DEAD entries — those are never polled). */
    private SessionState state;
    private String stateReason;

    /** Latest pane title the harness set via OSC (e.g. Claude Code's /rename); empty
     * until a poll reports one. Kept even when a later poll reports none — a harness
     * mid-redraw must not make the name flicker off. */
    private String paneTitle = "";

    /** The live status mark the harness leads its title with ({@code ✳}, a braille or
     * half-circle spinner frame, …), exactly as last written; empty when it writes none.
     * Shown before the name but never part of it, so a new frame repaints the row
     * without renaming it or moving it in a name sort. */
    private String titleMark = "";

    /** Whether a title has arrived from the live stream: from then on the stream owns
     * the mark, and the poll (a sample a few seconds old) only keeps the name fresh. */
    private boolean liveTitleSeen;

    private SidebarEntry(Status status, SessionEntry sessionEntry, String sessionName) {
        this.status = status;
        this.sessionEntry = sessionEntry;
        this.sessionName = sessionName;
    }

    static SidebarEntry live(SessionEntry entry) {
        return new SidebarEntry(Status.LIVE, entry, entry.sessionName());
    }

    static SidebarEntry dead(SessionEntry entry) {
        return new SidebarEntry(Status.DEAD, entry, entry.sessionName());
    }

    Status status() {
        return status;
    }

    String sessionName() {
        return sessionName;
    }

    SessionEntry sessionEntry() {
        return sessionEntry;
    }

    HarnessType harnessType() {
        return sessionEntry.harnessType();
    }

    boolean isAttached() {
        return attached;
    }

    void setAttached(boolean attached) {
        this.attached = attached;
    }

    /** Null until the first status-poll result lands for this (live) session. */
    SessionState state() {
        return state;
    }

    /** Reason paired with {@link #state()}; null exactly when the state is. */
    String stateReason() {
        return stateReason;
    }

    void setState(SessionState state, String reason) {
        this.state = state;
        this.stateReason = reason;
    }

    String paneTitle() {
        return paneTitle;
    }

    String titleMark() {
        return titleMark;
    }

    /** A title the status poll sampled. Updates the name; updates the mark only until
     * the live stream has delivered one, since its frames are newer than any sample. */
    void setPaneTitle(String polledTitle) {
        if (polledTitle == null || polledTitle.isBlank()) {
            return;
        }
        TitleParts parts = TitleParts.of(polledTitle);
        if (!parts.name().isBlank()) {
            this.paneTitle = parts.name();
        }
        if (!liveTitleSeen) {
            this.titleMark = parts.mark();
        }
    }

    /**
     * A title as the harness just wrote it (the live stream). The mark follows it frame
     * for frame, cleared when the harness stops writing one. The name follows too,
     * except for Codex, whose name is its saved chat name (the poll resolves it) rather
     * than its title. A title with no name in it keeps the previous name.
     */
    void setLiveTitle(String title) {
        liveTitleSeen = true;
        TitleParts parts = TitleParts.of(title == null ? "" : title);
        this.titleMark = parts.mark();
        if (!parts.name().isBlank() && harnessType() != HarnessType.CODEX) {
            this.paneTitle = parts.name();
        }
    }

    /** Takes over {@code previous}'s title state when the sidebar is rebuilt. */
    void carryTitleFrom(SidebarEntry previous) {
        this.paneTitle = previous.paneTitle;
        this.titleMark = previous.titleMark;
        this.liveTitleSeen = previous.liveTitleSeen;
    }

    /**
     * A harness title split into its leading status mark and the name after it. The
     * mark is a run of non-ASCII symbols (Unicode {@code So}/{@code Sm}, plus {@code ·}
     * and {@code •}, which Claude Code cycles through) ending at a space or the end of
     * the title; joiners and variation selectors may sit inside it so an emoji stays
     * whole. Whatever the harness's spinner glyphs are, they need no listing here.
     * Anything else (no mark, or symbols glued to a word) is all name.
     */
    record TitleParts(String mark, String name) {

        static TitleParts of(String title) {
            String t = title.strip();
            int i = 0;
            int marks = 0;
            while (i < t.length()) {
                int cp = t.codePointAt(i);
                if (isMarkSymbol(cp)) {
                    marks++;
                } else if (marks == 0 || !isMarkJoiner(cp)) {
                    break;
                }
                i += Character.charCount(cp);
            }
            if (marks == 0 || (i < t.length() && !Character.isWhitespace(t.codePointAt(i)))) {
                return new TitleParts("", t);
            }
            return new TitleParts(t.substring(0, i), t.substring(i).strip());
        }

        private static boolean isMarkSymbol(int cp) {
            if (cp == 0x00B7 || cp == 0x2022) {
                return true;
            }
            int type = Character.getType(cp);
            return cp > 0x7F && (type == Character.OTHER_SYMBOL || type == Character.MATH_SYMBOL);
        }

        private static boolean isMarkJoiner(int cp) {
            int type = Character.getType(cp);
            return cp == 0x200D || type == Character.NON_SPACING_MARK || type == Character.ENCLOSING_MARK;
        }
    }

    /** The session's name as shown to the user: an explicit persisted rename, then the
     * harness-set OSC title (e.g. Claude Code's /rename), then the session name. */
    String displayName() {
        if (sessionEntry.displayName() != null && !sessionEntry.displayName().isBlank()) {
            return sessionEntry.displayName();
        }
        return detectedName();
    }

    /** Best name supplied by the harness/provider, before any persisted sidebar override. */
    String detectedName() {
        return paneTitle.isEmpty() ? sessionName : paneTitle;
    }

    /** Project path with the home directory abbreviated to {@code ~}. */
    String abbreviatedPath() {
        String path = sessionEntry.projectPath();
        String home = System.getProperty("user.home");
        if (home != null && !home.isBlank() && path.startsWith(home)) {
            return "~" + path.substring(home.length());
        }
        return path;
    }

    /**
     * The row's top line: the harness's live status mark, if any, then the session's
     * name (a persisted rename, then the harness-set OSC title, then the session
     * name). The harness isn't named
     * here — the renderer badges the row with {@link #harnessType()}'s glyph instead.
     */
    String nameText() {
        return markedName();
    }

    /** {@link #displayName()} led by the harness's current status mark, if any: the name
     * as every title-showing surface presents it. */
    String markedName() {
        return titleMark.isEmpty() ? displayName() : titleMark + " " + displayName();
    }

    /** The row's muted second line: the project dir. The renderer clips this from the
     * left ("…tail"), so the path's most telling segment — the project folder at its
     * end — survives a narrow sidebar. No state is spelled out in text: the
     * {@code Reticule} screen door says not-attached, the faded avatar and its cross badge say dead. */
    String detailText() {
        return abbreviatedPath();
    }

    private static String escapeHtml(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    /** For the sidebar's per-row tooltip; combines the session name with the harness
     * the row's glyph stands for and the latest status reason, if any. */
    String tooltipText() {
        String fullDisplayName = displayName();
        StringBuilder html = new StringBuilder("<html><b>")
                .append(escapeHtml(markedName())).append("</b>");
        if (!fullDisplayName.equals(sessionName)) {
            html.append("<br>").append(escapeHtml(sessionName));
        }
        html.append("<br>").append(sessionEntry.harnessType().id());
        if (status == Status.LIVE && state != null) {
            html.append("<br>").append(state).append(" — ").append(stateReason);
        } else if (status == Status.LIVE) {
            html.append("<br>status pending first poll…");
        } else if (status == Status.DEAD) {
            // the cross badge's fine print: dead isn't gone — Resume… brings it back
            html.append("<br>dead — right-click to resume");
        }
        html.append("</html>");
        return html.toString();
    }

    @Override
    public boolean equals(Object o) {
        return o instanceof SidebarEntry other && sessionName.equals(other.sessionName);
    }

    @Override
    public int hashCode() {
        return sessionName.hashCode();
    }
}
