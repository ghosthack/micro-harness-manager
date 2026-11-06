package io.github.ghosthack.microhm.vt;

/**
 * Callbacks from a {@link TerminalEmulator}, made on the thread that called {@code apply},
 * {@code feed} or {@code resize}, <em>after</em> the emulator lock has been released (so a
 * listener may take the lock, or hand off to a UI thread that will, without deadlocking).
 * All methods default to no-ops.
 */
public interface TerminalListener {

    /** Something observable changed (cells, cursor, modes, title, size); see
     * {@link TerminalEmulator#changeCount()}. Called at most once per batch. */
    default void contentChanged() {
    }

    /** BEL was received ({@code count} times in the batch). */
    default void bell(int count) {
    }

    /** The window title (OSC 0/1/2, or a title-stack pop) changed. */
    default void titleChanged(String title) {
    }
}
