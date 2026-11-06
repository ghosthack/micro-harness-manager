package io.github.ghosthack.microhm.app;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.formdev.flatlaf.themes.FlatMacDarkLaf;
import com.sun.net.httpserver.HttpServer;

import java.io.InputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * {@code --package-smoke}: proves a packaged app's trimmed Java runtime carries what
 * the app needs, without opening a window — the look and feel, the icon resource,
 * Jackson, and a loopback round trip through the MCP server's HTTP stack. Prints one
 * line per check and exits 0, or throws (exit 1) at the first missing piece. The
 * session daemon and PTYs are smoke-tested through the packaged {@code microhm-mux}
 * launcher instead.
 */
final class PackageSmoke {

    private PackageSmoke() {
    }

    static void run() throws Exception {
        String version = PackageSmoke.class.getPackage().getImplementationVersion();
        System.out.println("version: " + version);
        System.out.println("runtime: " + Runtime.version() + " at " + System.getProperty("java.home"));

        if (new FlatMacDarkLaf().getName() == null) {
            throw new IllegalStateException("FlatLaf has no name");
        }
        System.out.println("look and feel: OK");

        try (InputStream icon = PackageSmoke.class.getResourceAsStream(
                "/io/github/ghosthack/microhm/app/ui/app-icon.png")) {
            if (icon == null || icon.readAllBytes().length == 0) {
                throw new IllegalStateException("app icon resource missing");
            }
        }
        System.out.println("icon: OK");

        ObjectMapper mapper = new ObjectMapper();
        String json = mapper.writeValueAsString(Map.of("ok", true));
        if (!mapper.readTree(json).path("ok").asBoolean()) {
            throw new IllegalStateException("Jackson round trip failed");
        }
        System.out.println("json: OK");

        HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.createContext("/", exchange -> {
            byte[] body = "pong".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
            exchange.close();
        });
        server.start();
        try (HttpClient client = HttpClient.newHttpClient()) {
            String reply = client.send(HttpRequest.newBuilder(
                            java.net.URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/")).build(),
                    HttpResponse.BodyHandlers.ofString()).body();
            if (!"pong".equals(reply)) {
                throw new IllegalStateException("HTTP round trip returned " + reply);
            }
        } finally {
            server.stop(0);
        }
        System.out.println("http: OK");
        System.out.println("package smoke: OK");
    }
}
