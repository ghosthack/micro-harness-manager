package io.github.ghosthack.microhm.mux.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.github.ghosthack.microhm.mux.protocol.Frame;
import io.github.ghosthack.microhm.mux.protocol.FrameCodec;
import io.github.ghosthack.microhm.mux.protocol.FrameType;
import io.github.ghosthack.microhm.mux.protocol.Json;
import io.github.ghosthack.microhm.mux.protocol.Protocol;
import io.github.ghosthack.microhm.mux.server.ServerHome;

import java.io.EOFException;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.Channels;
import java.nio.channels.SocketChannel;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Optional;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * One socket to the server with its codec. {@link #open} folds "socket file missing" and
 * "connect refused" into an empty result — both mean no server — and {@link #request}
 * stamps every request with the protocol version and turns EOF-before-response into
 * {@link NoServerException}, so callers see exactly the three no-server cases the design
 * names and nothing else in that shape.
 */
final class ServerConnection implements AutoCloseable {

    /** The connection died before the response: the server is not (or no longer) there. */
    static final class NoServerException extends IOException {
        NoServerException(String message) {
            super(message);
        }
    }

    /** How long an ordinary request waits for its answer. A daemon that accepts the
     * socket but never replies (wedged, or stopped in a debugger) would otherwise block the
     * caller for good — the app's quit among them. */
    static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(10);

    /** Closes a connection whose answer is overdue; that wakes the blocked read. One daemon
     * thread for every connection, idle unless a deadline is pending. */
    private static final ScheduledThreadPoolExecutor DEADLINES = deadlines();

    private static ScheduledThreadPoolExecutor deadlines() {
        ScheduledThreadPoolExecutor executor = new ScheduledThreadPoolExecutor(1, r -> {
            Thread thread = new Thread(r, "microhm-mux-request-deadline");
            thread.setDaemon(true);
            return thread;
        });
        executor.setRemoveOnCancelPolicy(true);
        return executor;
    }

    private final SocketChannel channel;
    private final FrameCodec codec;
    /** Pending deadline state: {@code WAITING} while a reply is due; the reader moves it
     * to {@code ANSWERED} and the deadline to {@code EXPIRED}, whichever comes first — so a
     * deadline firing as the reply lands can never close a connection that is about to
     * become an attach stream. */
    private final java.util.concurrent.atomic.AtomicInteger deadlineState = new java.util.concurrent.atomic.AtomicInteger(IDLE);
    private static final int IDLE = 0;
    private static final int WAITING = 1;
    private static final int EXPIRED = 2;

    private ServerConnection(SocketChannel channel) {
        this.channel = channel;
        this.codec = new FrameCodec(Channels.newInputStream(channel), Channels.newOutputStream(channel));
    }

    static Optional<ServerConnection> open(Path socket) {
        try {
            // Not "no server": whoever owns that directory owns whatever listens in it.
            ServerHome.requireOwned(socket.toAbsolutePath().getParent());
        } catch (IOException e) {
            throw new SessionServerException(e.getMessage(), e);
        }
        SocketChannel channel = null;
        try {
            channel = SocketChannel.open(StandardProtocolFamily.UNIX);
            channel.connect(UnixDomainSocketAddress.of(socket));
            return Optional.of(new ServerConnection(channel));
        } catch (IOException e) {
            if (channel != null) {
                try {
                    channel.close();
                } catch (IOException ignored) {
                    // Never connected; nothing to release.
                }
            }
            return Optional.empty();
        }
    }

    SocketChannel channel() {
        return channel;
    }

    FrameCodec codec() {
        return codec;
    }

    /** Sends {@code op} with {@code args} (plus the protocol stamp) and returns the
     * response body, which may be {@code ok:false}. */
    JsonNode request(String op, ObjectNode args) throws IOException {
        return request(op, args, REQUEST_TIMEOUT);
    }

    /** {@link #request} with its own deadline; past it the connection is closed and the
     * call fails with an {@link IOException} that says the server did not answer. */
    JsonNode request(String op, ObjectNode args, Duration timeout) throws IOException {
        ObjectNode body = args == null ? Json.object() : args;
        body.put(Protocol.F_OP, op).put(Protocol.F_PROTOCOL, Protocol.VERSION);
        deadlineState.set(WAITING);
        ScheduledFuture<?> deadline = DEADLINES.schedule(this::expire, timeout.toMillis(), TimeUnit.MILLISECONDS);
        Frame reply;
        try {
            codec.write(Frame.of(FrameType.REQUEST, Json.bytes(body)));
            reply = codec.read();
            if (!deadlineState.compareAndSet(WAITING, IDLE)) {
                throw new IOException(op + ": the session server did not answer within "
                        + timeout.toSeconds() + " s");
            }
        } catch (IOException e) {
            if (deadlineState.get() == EXPIRED) {
                throw new IOException(op + ": the session server did not answer within "
                        + timeout.toSeconds() + " s", e);
            }
            if (e instanceof EOFException) {
                throw new NoServerException("connection closed before the response");
            }
            throw e;
        } finally {
            deadline.cancel(false);
        }
        if (reply == null) {
            throw new NoServerException("connection closed before the response");
        }
        if (reply.type() != FrameType.RESPONSE) {
            throw new IOException("expected a RESPONSE frame, got " + reply.type());
        }
        JsonNode node = Json.parse(reply.payload());
        if (!node.isObject()) {
            throw new IOException("response is not a JSON object");
        }
        return node;
    }

    private void expire() {
        if (!deadlineState.compareAndSet(WAITING, EXPIRED)) {
            return; // answered in time
        }
        try {
            channel.close();
        } catch (IOException ignored) {
            // closing is the whole point; a failure leaves nothing more to do
        }
    }

    /** Reads until the server closes the socket (what {@code shutdown} waits for), at most
     * {@link #REQUEST_TIMEOUT}. */
    void drainToEof() {
        deadlineState.set(WAITING);
        ScheduledFuture<?> deadline = DEADLINES.schedule(this::expire,
                REQUEST_TIMEOUT.toMillis(), TimeUnit.MILLISECONDS);
        try {
            while (codec.read() != null) {
                // discard
            }
        } catch (IOException ignored) {
            // A reset counts as closed too.
        } finally {
            deadline.cancel(false);
        }
    }

    @Override
    public void close() {
        try {
            channel.close();
        } catch (IOException ignored) {
            // Nothing further to release.
        }
    }
}
