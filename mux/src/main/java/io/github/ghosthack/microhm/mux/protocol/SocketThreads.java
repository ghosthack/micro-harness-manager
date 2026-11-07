package io.github.ghosthack.microhm.mux.protocol;

/**
 * Threads that block on the daemon's Unix-domain sockets. Virtual everywhere but Windows:
 * there, a virtual thread parks in the JDK's WEPoll poller, which can miss the readiness of
 * an AF_UNIX socket. Under a burst the daemon's writer and the client's reader then both
 * wait for ever, with data still to send, and the session's output freezes. A platform
 * thread blocks in the socket call itself, so it never reaches that poller.
 */
public final class SocketThreads {

    private static final boolean WINDOWS = System.getProperty("os.name", "").startsWith("Windows");

    private SocketThreads() {
    }

    /** A builder for a named thread that will block on a socket. Always a daemon thread. */
    public static Thread.Builder named(String name) {
        return WINDOWS ? Thread.ofPlatform().daemon().name(name) : Thread.ofVirtual().name(name);
    }
}
