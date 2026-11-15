package io.github.ghosthack.microhm.app.phone;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.SocketException;
import java.time.Duration;
import java.util.Collections;
import java.util.Objects;

/**
 * The app's handle on its one {@link PhoneServer}, the way {@code McpService} is for the
 * MCP server: started at launch when {@code phone.server} is on, restarted when Settings
 * changes it, stopped on shutdown. A port that is taken is logged and rethrown for the
 * caller to report; it never takes the app down.
 */
public final class PhoneService {

    private static final Logger LOG = LoggerFactory.getLogger(PhoneService.class);
    static final Duration POLL = Duration.ofMillis(300);

    private final PhoneBackend backend;
    /** Guarded by {@code this}; null while stopped. */
    private PhoneServer server;
    private String token;

    public PhoneService(PhoneBackend backend) {
        this.backend = Objects.requireNonNull(backend, "backend");
    }

    /** Serves on {@code port} with {@code token}; already doing so is a no-op. */
    public synchronized void start(int port, String token) throws IOException {
        if (server != null && server.port() == port && token.equals(this.token)) {
            return;
        }
        stop();
        PhoneServer candidate = new PhoneServer(port, token, backend, PhoneServer.webDirOverride(), POLL);
        // colours as the window draws them: the ANSI palette chosen in Settings → Terminal
        candidate.useColours(new StyledScreen(io.github.ghosthack.microhm.app.terminal.AnsiPalettes.forSetting(
                io.github.ghosthack.microhm.app.settings.AppSettings.terminalPalette())));
        try {
            candidate.start();
        } catch (IOException | RuntimeException e) {
            candidate.close();
            LOG.warn("phone page could not start on port {}: {}", port, e.toString());
            throw e;
        }
        server = candidate;
        this.token = token;
        LOG.info("phone page at {}{}", link(candidate.port(), null),
                PhoneServer.webDirOverride() != null ? " (page files from " + PhoneServer.webDirOverride() + ")" : "");
    }

    public synchronized void stop() {
        if (server != null) {
            server.close();
            server = null;
            token = null;
            LOG.info("phone page stopped");
        }
    }

    public synchronized boolean isRunning() {
        return server != null;
    }

    /**
     * The link to open on a phone: this machine's local network address, and the secret
     * after {@code #}, which the browser never sends to a server; the page trades it for a
     * cookie and then drops it from the address bar. {@code token} null leaves it out.
     */
    public static String link(int port, String token) {
        return "http://" + lanAddress() + ":" + port + "/" + (token == null ? "" : "#k=" + token);
    }

    /** The first private IPv4 address of an interface that is up, else the host name. */
    static String lanAddress() {
        try {
            for (NetworkInterface nic : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nic.isUp() || nic.isLoopback() || nic.isVirtual() || nic.isPointToPoint()) {
                    continue;
                }
                for (InetAddress address : Collections.list(nic.getInetAddresses())) {
                    if (address instanceof Inet4Address && address.isSiteLocalAddress()) {
                        return address.getHostAddress();
                    }
                }
            }
            return InetAddress.getLocalHost().getHostName();
        } catch (SocketException | java.net.UnknownHostException e) {
            return "localhost";
        }
    }
}
