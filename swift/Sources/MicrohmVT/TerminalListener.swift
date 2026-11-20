/**
 * Callbacks from a `TerminalEmulator`, made on the thread that called `apply`, `feed` or
 * `resize`, *after* the emulator lock has been released (so a listener may take the lock, or
 * hand off to a UI thread that will, without deadlocking). All methods default to no-ops.
 */
public protocol TerminalListener: AnyObject {

    /** Something observable changed (cells, cursor, modes, title, size); see
     * `TerminalEmulator.changeCount()`. Called at most once per batch. */
    func contentChanged()

    /** BEL was received (`count` times in the batch). */
    func bell(_ count: Int)

    /** The window title (OSC 0/1/2, or a title-stack pop) changed. */
    func titleChanged(_ title: String)
}

public extension TerminalListener {
    func contentChanged() {
    }

    func bell(_ count: Int) {
    }

    func titleChanged(_ title: String) {
    }
}
