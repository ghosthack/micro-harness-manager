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

    void setPaneTitle(String paneTitle) {
        if (paneTitle != null && !paneTitle.isBlank()) {
            this.paneTitle = paneTitle;
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
     * The row's top line: the session's name (a persisted rename, then the harness-set
     * OSC title, then the session name). The harness isn't named
     * here — the renderer badges the row with {@link #harnessType()}'s glyph instead.
     */
    String nameText() {
        return displayName();
    }

    /** The row's muted second line: the project dir. The renderer clips this from the
     * left ("…tail"), so the path's most telling segment — the project folder at its
     * end — survives a narrow sidebar. No state is spelled out in text: the
     * {@code Reticule} screen door says not-attached, the skull icon says dead. */
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
                .append(escapeHtml(fullDisplayName)).append("</b>");
        if (!fullDisplayName.equals(sessionName)) {
            html.append("<br>").append(escapeHtml(sessionName));
        }
        html.append("<br>").append(sessionEntry.harnessType().id());
        if (status == Status.LIVE && state != null) {
            html.append("<br>").append(state).append(" — ").append(stateReason);
        } else if (status == Status.LIVE) {
            html.append("<br>status pending first poll…");
        } else if (status == Status.DEAD) {
            // the skull's fine print: dead isn't gone — Resume… brings it back
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
