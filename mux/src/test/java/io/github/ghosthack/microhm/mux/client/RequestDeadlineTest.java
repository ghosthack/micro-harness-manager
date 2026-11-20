package io.github.ghosthack.microhm.mux.client;

import io.github.ghosthack.microhm.mux.protocol.Json;
import io.github.ghosthack.microhm.mux.protocol.Protocol;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.channels.ServerSocketChannel;
import java.nio.channels.SocketChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** A daemon that accepts the socket but never answers must not block its caller for good
 * (the app's quit asks the daemon for its sessions). */
final class RequestDeadlineTest {

    @Test
    void aRequestToAServerThatNeverAnswersFailsAtItsDeadline() throws Exception {
        // short: a Unix socket path must stay under ~104 bytes
        Path socket = Files.createTempDirectory(Path.of("/tmp"), "mhd").resolve("s");
        try (ServerSocketChannel wedged = ServerSocketChannel.open(StandardProtocolFamily.UNIX)) {
            wedged.bind(UnixDomainSocketAddress.of(socket));
            ServerConnection connection = ServerConnection.open(socket).orElseThrow();
            try (SocketChannel accepted = wedged.accept()) {
                long start = System.nanoTime();
                IOException e = assertThrows(IOException.class,
                        () -> connection.request(Protocol.OP_LIST, null, Duration.ofMillis(300)));
                long elapsedMs = (System.nanoTime() - start) / 1_000_000;
                assertTrue(e.getMessage().contains("did not answer"), e.getMessage());
                assertFalse(e instanceof ServerConnection.NoServerException, "a wedged server is not a missing one");
                assertTrue(elapsedMs >= 250 && elapsedMs < 5_000, "failed after " + elapsedMs + " ms");
            } finally {
                connection.close();
            }
        } finally {
            Files.deleteIfExists(socket);
            Files.deleteIfExists(socket.getParent());
        }
    }

    @Test
    void waitGetsItsOwnTimeoutOnTopOfTheOrdinaryOne() {
        assertEquals(ServerConnection.REQUEST_TIMEOUT,
                SessionServerClient.timeoutFor(Protocol.OP_LIST, null));
        assertEquals(ServerConnection.REQUEST_TIMEOUT.plusMillis(30_000),
                SessionServerClient.timeoutFor(Protocol.OP_WAIT, Json.object().put(Protocol.F_TIMEOUT_MS, 30_000)));
    }
}
