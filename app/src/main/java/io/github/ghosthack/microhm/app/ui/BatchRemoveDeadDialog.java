package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.status.SessionStatusPoller;

import java.awt.Window;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ExecutorService;

/**
 * The toolbar's "Remove dead sessions…": lets the user hand-pick which stopped sessions to
 * forget from the registry — grouped by folder, every dead session pre-selected since,
 * unlike {@link BatchCloseDialog}'s idle sessions, there is no "safer" subset to default to.
 * Unlike closing, a removal cannot be refused (there is nothing left running to be busy)
 * and cannot fail in a way worth surfacing to the user: {@link SessionRegistry#remove}
 * already swallows and logs its own disk-write errors, keeping the in-memory registry (and
 * so the sidebar) authoritative either way. Removing forgets a session's resume history for
 * good — that is the whole point, but also why this still goes through a review-then-confirm
 * dialog rather than a single "clear all dead" button.
 */
final class BatchRemoveDeadDialog {

    static void show(Window parent, List<SidebarEntry> candidates, SessionRegistry registry,
                     SessionStatusPoller statusPoller, ExecutorService backgroundExecutor,
                     Runnable onFinished) {
        BatchOperationDialog.show(parent,
                "Remove dead sessions",
                "<html>Removing forgets a session for good — its saved conversation can no "
                        + "longer be resumed. Uncheck any folder or session you want to keep.</html>",
                "Remove selected",
                candidates,
                entry -> true,
                BatchRemoveDeadDialog::harnessLabel,
                new BatchOperationDialog.ActionWords("Removing", "Removed", "remove"),
                backgroundExecutor,
                entry -> {
                    registry.remove(entry.sessionName());
                    statusPoller.forget(entry.sessionName());
                    return Optional.empty();
                },
                entry -> { },
                onFinished);
    }

    private static String harnessLabel(SidebarEntry entry) {
        return entry.harnessType().id();
    }

    private BatchRemoveDeadDialog() {
    }
}
