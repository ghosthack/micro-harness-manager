package io.github.ghosthack.microhm.app.phone;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.ghosthack.microhm.app.control.SessionController.HistoryView;
import io.github.ghosthack.microhm.app.control.SessionController.ScreenView;
import io.github.ghosthack.microhm.app.control.SessionController.SessionSummary;
import io.github.ghosthack.microhm.app.mcp.ToolResult;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PhoneServerTest {

    private static final String TOKEN = "phone-secret_123";
    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** One session, "hm-a", whose screen text the test sets; null text means it exited. */
    private static final class FakeBackend implements PhoneBackend {
        final AtomicReference<String> text = new AtomicReference<>("hello");
        final List<String> calls = Collections.synchronizedList(new ArrayList<>());
        volatile boolean alive = true;
        volatile int columns = 120;
        volatile int rows = 40;
        final List<String> resizes = Collections.synchronizedList(new ArrayList<>());
        /** The scrollback, one entry per line ever added. */
        final List<String> history = Collections.synchronizedList(new ArrayList<>());

        @Override
        public Optional<HistoryView> history(String session, long since) {
            synchronized (history) {
                int from = (int) Math.min(since, history.size());
                return Optional.of(new HistoryView(String.join("\n", history.subList(from, history.size())),
                        history.size(), false));
            }
        }

        @Override
        public void resize(String session, int c, int r) {
            if (failResizes.getAndUpdate(n -> Math.max(0, n - 1)) > 0) {
                throw new IllegalStateException("daemon restarting");
            }
            resizes.add(session + " " + c + "x" + r);
            columns = c;
            rows = r;
        }

        volatile boolean failSessions;
        /** How many coming resizes fail. */
        final java.util.concurrent.atomic.AtomicInteger failResizes = new java.util.concurrent.atomic.AtomicInteger();
        final List<String> closed = Collections.synchronizedList(new ArrayList<>());

        @Override
        public Optional<String> closeBlocker(String session) {
            return session.equals("busy") ? Optional.of("It's still working.") : Optional.empty();
        }

        @Override
        public PhoneCloser.Outcome close(String session) {
            if (session.equals("busy")) {
                return new PhoneCloser.Outcome(false, "It's still working.");
            }
            closed.add(session);
            return new PhoneCloser.Outcome(true, "Closed");
        }
        final List<String> resumed = Collections.synchronizedList(new ArrayList<>());

        @Override
        public List<io.github.ghosthack.microhm.app.control.SessionController.EndedSession> ended() {
            return List.of(new io.github.ghosthack.microhm.app.control.SessionController.EndedSession(
                    "hm-b", "beta", "codex", "/p/b", true, java.time.Instant.parse("2026-11-01T00:00:00Z")));
        }

        @Override
        public String resume(String session) {
            if (!session.equals("hm-b")) {
                throw new IllegalArgumentException("no saved session named " + session);
            }
            resumed.add(session);
            return "hm-b";
        }

        @Override
        public List<SessionSummary> sessions() {
            if (failSessions) {
                throw new IllegalStateException("daemon down");
            }
            return List.of(new SessionSummary("hm-a", "alpha", "claude-code", "WAITING_FOR_INPUT", "/p/a"));
        }

        @Override
        public Optional<ScreenView> screen(String session) {
            if (!session.equals("hm-a") && !session.equals("alpha")) {
                throw new IllegalArgumentException("no session named " + session);
            }
            String t = text.get();
            return t == null ? Optional.empty() : Optional.of(new ScreenView("hm-a", "alpha", "claude-code",
                    "WAITING_FOR_INPUT", "menu", "title", t, columns, rows, t.length(), alive));
        }

        @Override
        public ToolResult call(String tool, JsonNode arguments) {
            calls.add(tool + " " + arguments);
            return arguments.path("session").asText().equals("hm-a")
                    ? ToolResult.ok("done") : ToolResult.error("no such session");
        }
    }

    @TempDir
    Path web;

    private final FakeBackend backend = new FakeBackend();
    private final HttpClient http = HttpClient.newHttpClient();
    private PhoneServer server;

    @BeforeEach
    void start() throws IOException {
        Files.writeString(web.resolve("index.html"), "<p>page v1</p>");
        server = new PhoneServer(0, TOKEN, backend, web, Duration.ofMillis(20), Duration.ofMillis(50),
                Duration.ofMillis(300));
        server.start();
    }

    @AfterEach
    void stop() {
        server.close();
    }

    private URI uri(String path) {
        return URI.create("http://localhost:" + server.port() + path);
    }

    private HttpResponse<String> get(String path, String cookie) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(uri(path));
        if (cookie != null) {
            b.header("Cookie", cookie);
        }
        return http.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    private HttpResponse<String> post(String path, String json, String cookie, String origin) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(uri(path))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(json));
        if (cookie != null) {
            b.header("Cookie", cookie);
        }
        if (origin != null) {
            b.header("Origin", origin);
        }
        return http.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    private static final String COOKIE = PhoneServer.COOKIE + "=" + TOKEN;

    @Test
    void servesThePageFromDiskOnEveryRequest() throws Exception {
        assertEquals("<p>page v1</p>", get("/", null).body());
        Files.writeString(web.resolve("index.html"), "<p>page v2</p>");
        HttpResponse<String> again = get("/", null);
        assertEquals("<p>page v2</p>", again.body());
        assertTrue(again.headers().firstValue("Content-Type").orElse("").startsWith("text/html"));
        assertEquals(404, get("/missing.js", null).statusCode());
        assertEquals(404, get("/..%2Fsecret", null).statusCode());
    }

    @Test
    void servesThePageFromTheJarWithoutAnOverride() throws Exception {
        server.close();
        server = new PhoneServer(0, TOKEN, backend, null, Duration.ofMillis(20));
        server.start();
        HttpResponse<String> page = get("/", null);
        assertEquals(200, page.statusCode());
        assertTrue(page.body().contains("app.js"));
        assertEquals(200, get("/app.js", null).statusCode());
    }

    @Test
    void theApiNeedsTheSecret() throws Exception {
        assertEquals(401, get("/api/sessions", null).statusCode());
        assertEquals(401, get("/api/sessions", PhoneServer.COOKIE + "=wrong").statusCode());
        HttpResponse<String> ok = get("/api/sessions", COOKIE);
        assertEquals(200, ok.statusCode());
        JsonNode first = MAPPER.readTree(ok.body()).path("sessions").path(0);
        assertEquals("hm-a", first.path("name").asText());
        assertEquals("WAITING_FOR_INPUT", first.path("state").asText());
        HttpRequest bearer = HttpRequest.newBuilder(uri("/api/sessions"))
                .header("Authorization", "Bearer " + TOKEN).build();
        assertEquals(200, http.send(bearer, HttpResponse.BodyHandlers.ofString()).statusCode());
    }

    @Test
    void loginTradesTheSecretForACookie() throws Exception {
        assertEquals(401, post("/api/login", "{\"token\":\"nope\"}", null, null).statusCode());
        HttpResponse<String> ok = post("/api/login", "{\"token\":\"" + TOKEN + "\"}", null, null);
        assertEquals(200, ok.statusCode());
        String cookie = ok.headers().firstValue("Set-Cookie").orElseThrow();
        assertTrue(cookie.startsWith(COOKIE + ";"), cookie);
        assertTrue(cookie.contains("HttpOnly") && cookie.contains("SameSite=Strict"), cookie);
    }

    @Test
    void refusesPostsFromAnotherSite() throws Exception {
        String body = "{\"session\":\"hm-a\",\"text\":\"hi\"}";
        assertEquals(403, post("/api/send", body, COOKIE, "http://evil.example").statusCode());
        assertEquals(200, post("/api/send", body, COOKIE, "http://localhost:" + server.port()).statusCode());
    }

    @Test
    void sendKeysAndSpawnGoToTheBackend() throws Exception {
        HttpResponse<String> sent = post("/api/send", "{\"session\":\"hm-a\",\"text\":\"hi\",\"enter\":true}",
                COOKIE, null);
        assertEquals(200, sent.statusCode());
        assertEquals("done", MAPPER.readTree(sent.body()).path("text").asText());
        HttpResponse<String> failed = post("/api/keys", "{\"session\":\"hm-x\",\"keys\":[\"Esc\"]}", COOKIE, null);
        assertEquals(400, failed.statusCode());
        assertEquals("no such session", MAPPER.readTree(failed.body()).path("text").asText());
        post("/api/spawn", "{\"harness\":\"shell\",\"project\":\"/p\"}", COOKIE, null);
        assertEquals(3, backend.calls.size());
        assertTrue(backend.calls.get(0).startsWith("send "));
        assertTrue(backend.calls.get(1).startsWith("keys "));
        assertTrue(backend.calls.get(2).startsWith("spawn "));
        assertEquals(404, post("/api/kill", "{\"session\":\"hm-a\"}", COOKIE, null).statusCode());
    }

    @Test
    void screenAnswersForAKnownSessionOnly() throws Exception {
        HttpResponse<String> screen = get("/api/screen?session=alpha", COOKIE);
        assertEquals(200, screen.statusCode());
        assertEquals("hello", MAPPER.readTree(screen.body()).path("text").asText());
        assertEquals(404, get("/api/screen?session=zzz", COOKIE).statusCode());
        backend.text.set(null);
        assertEquals(410, get("/api/screen?session=hm-a", COOKIE).statusCode());
    }

    @Test
    void streamSendsEachChangeThenExited() throws Exception {
        HttpRequest request = HttpRequest.newBuilder(uri("/api/stream?session=hm-a")).header("Cookie", COOKIE).build();
        HttpResponse<java.io.InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
        assertEquals(200, response.statusCode());
        assertTrue(response.headers().firstValue("Content-Type").orElse("").startsWith("text/event-stream"));
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
            assertEquals("hello", MAPPER.readTree(nextData(reader)).path("text").asText());
            backend.text.set("hello again");
            assertEquals("hello again", MAPPER.readTree(nextData(reader)).path("text").asText());
            backend.text.set(null);
            String line;
            while ((line = reader.readLine()) != null && !line.equals("event: exited")) {
                // skip to the end
            }
            assertEquals("event: exited", line);
        }
    }

    @Test
    void aWatchingPhoneSetsTheSizeAndTheLastOneToLeaveGivesItBack() throws Exception {
        HttpRequest first = HttpRequest.newBuilder(uri("/api/stream?session=alpha&cols=45&rows=30"))
                .header("Cookie", COOKIE).build();
        HttpRequest second = HttpRequest.newBuilder(uri("/api/stream?session=hm-a&cols=50&rows=28"))
                .header("Cookie", COOKIE).build();
        java.util.concurrent.CompletableFuture<HttpResponse<java.io.InputStream>> a =
                http.sendAsync(first, HttpResponse.BodyHandlers.ofInputStream());
        BufferedReader ra = new BufferedReader(new InputStreamReader(a.get().body(), StandardCharsets.UTF_8));
        assertEquals(45, MAPPER.readTree(nextData(ra)).path("columns").asInt());
        assertEquals(List.of("hm-a 45x30"), backend.resizes);

        HttpResponse<java.io.InputStream> b = http.send(second, HttpResponse.BodyHandlers.ofInputStream());
        BufferedReader rb = new BufferedReader(new InputStreamReader(b.body(), StandardCharsets.UTF_8));
        assertEquals(50, MAPPER.readTree(nextData(rb)).path("columns").asInt());
        b.body().close(); // the second phone leaves: the first still watches, nothing is given back
        Thread.sleep(300);
        assertEquals(List.of("hm-a 45x30", "hm-a 50x28"), backend.resizes);

        a.get().body().close(); // the last phone leaves: its size is given back after the grace time
        long deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        while (backend.resizes.size() < 3 && System.nanoTime() < deadline) {
            Thread.sleep(20);
        }
        assertEquals(List.of("hm-a 45x30", "hm-a 50x28", "hm-a 120x40"), backend.resizes);
    }

    /** A phone whose resize fails is counted out again; otherwise the session would keep a
     * phantom viewer and never get its size back after the next phone leaves. */
    @Test
    void aFailedResizeDoesNotLeaveAPhantomViewer() throws Exception {
        backend.failResizes.set(1);
        HttpResponse<java.io.InputStream> failed = http.send(HttpRequest.newBuilder(
                uri("/api/stream?session=hm-a&cols=45&rows=30")).header("Cookie", COOKIE).build(),
                HttpResponse.BodyHandlers.ofInputStream());
        nextData(new BufferedReader(new InputStreamReader(failed.body(), StandardCharsets.UTF_8)));
        assertEquals(List.of(), backend.resizes);

        HttpResponse<java.io.InputStream> next = http.send(HttpRequest.newBuilder(
                uri("/api/stream?session=hm-a&cols=50&rows=28")).header("Cookie", COOKIE).build(),
                HttpResponse.BodyHandlers.ofInputStream());
        nextData(new BufferedReader(new InputStreamReader(next.body(), StandardCharsets.UTF_8)));
        next.body().close();
        failed.body().close();
        long deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        while (backend.resizes.size() < 2 && System.nanoTime() < deadline) {
            Thread.sleep(20);
        }
        assertEquals(List.of("hm-a 50x28", "hm-a 120x40"), backend.resizes);
    }

    @Test
    void comingBackWithinTheGraceTimeCostsNoResize() throws Exception {
        String path = "/api/stream?session=hm-a&cols=45&rows=30";
        HttpResponse<java.io.InputStream> first = http.send(HttpRequest.newBuilder(uri(path)).header("Cookie", COOKIE)
                .build(), HttpResponse.BodyHandlers.ofInputStream());
        nextData(new BufferedReader(new InputStreamReader(first.body(), StandardCharsets.UTF_8)));
        first.body().close();
        Thread.sleep(120); // noticed as gone (keepalive 50 ms), well inside the 300 ms grace

        HttpResponse<java.io.InputStream> again = http.send(HttpRequest.newBuilder(uri(path)).header("Cookie", COOKIE)
                .build(), HttpResponse.BodyHandlers.ofInputStream());
        nextData(new BufferedReader(new InputStreamReader(again.body(), StandardCharsets.UTF_8)));
        Thread.sleep(500); // past the first grace time: the cancelled size-back must not run
        assertEquals(List.of("hm-a 45x30"), backend.resizes);
        again.body().close();
    }

    @Test
    void closingTheServerGivesSizesBackAtOnce() throws Exception {
        server.close();
        server = new PhoneServer(0, TOKEN, backend, web, Duration.ofMillis(20), Duration.ofMillis(50),
                Duration.ofMinutes(10));
        server.start();
        HttpResponse<java.io.InputStream> watching = http.send(HttpRequest.newBuilder(
                uri("/api/stream?session=hm-a&cols=45&rows=30")).header("Cookie", COOKIE).build(),
                HttpResponse.BodyHandlers.ofInputStream());
        nextData(new BufferedReader(new InputStreamReader(watching.body(), StandardCharsets.UTF_8)));
        server.close();
        assertEquals(List.of("hm-a 45x30", "hm-a 120x40"), backend.resizes);
    }

    @Test
    void aStreamWithoutASizeLeavesTheSizeAlone() throws Exception {
        HttpRequest request = HttpRequest.newBuilder(uri("/api/stream?session=hm-a&cols=3&rows=30"))
                .header("Cookie", COOKIE).build();
        HttpResponse<java.io.InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
        nextData(new BufferedReader(new InputStreamReader(response.body(), StandardCharsets.UTF_8)));
        response.body().close();
        assertTrue(backend.resizes.isEmpty(), backend.resizes.toString());
    }

    @Test
    void streamSendsTheScrollbackThenEachNewLine() throws Exception {
        backend.history.addAll(List.of("one", "two"));
        HttpRequest request = HttpRequest.newBuilder(uri("/api/stream?session=hm-a")).header("Cookie", COOKIE).build();
        HttpResponse<java.io.InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
            JsonNode first = MAPPER.readTree(nextEvent(reader, "history"));
            assertEquals("one\ntwo", first.path("text").asText());
            assertTrue(first.path("reset").asBoolean());
            backend.history.add("three");
            JsonNode next = MAPPER.readTree(nextEvent(reader, "history"));
            assertEquals("three", next.path("text").asText());
            assertTrue(!next.path("reset").asBoolean());
        }
    }

    @Test
    void aFailingRequestStillGetsItsErrorMessage() throws Exception {
        backend.failSessions = true;
        HttpResponse<String> failed = get("/api/sessions", COOKIE);
        assertEquals(500, failed.statusCode());
        assertEquals("daemon down", MAPPER.readTree(failed.body()).path("error").asText());
    }

    @Test
    void listsEndedSessionsAndResumesOne() throws Exception {
        JsonNode ended = MAPPER.readTree(get("/api/sessions", COOKIE).body()).path("ended").path(0);
        assertEquals("hm-b", ended.path("name").asText());
        assertTrue(ended.path("conversation").asBoolean());
        assertEquals("2026-11-01T00:00:00Z", ended.path("created").asText());

        HttpResponse<String> ok = post("/api/resume", "{\"session\":\"hm-b\"}", COOKIE, null);
        assertEquals(200, ok.statusCode());
        assertEquals("hm-b", MAPPER.readTree(ok.body()).path("name").asText());
        assertEquals(List.of("hm-b"), backend.resumed);

        HttpResponse<String> missing = post("/api/resume", "{\"session\":\"zz\"}", COOKIE, null);
        assertEquals(400, missing.statusCode());
        assertEquals("no saved session named zz", MAPPER.readTree(missing.body()).path("error").asText());
        assertEquals(401, post("/api/resume", "{\"session\":\"hm-b\"}", null, null).statusCode());
    }

    @Test
    void closeChecksFirstAndRefusesABusySession() throws Exception {
        JsonNode ok = MAPPER.readTree(get("/api/close-check?session=hm-a", COOKIE).body());
        assertTrue(ok.path("closable").asBoolean());
        JsonNode busy = MAPPER.readTree(get("/api/close-check?session=busy", COOKIE).body());
        assertTrue(!busy.path("closable").asBoolean());
        assertEquals("It's still working.", busy.path("reason").asText());

        assertEquals(200, post("/api/close", "{\"session\":\"hm-a\"}", COOKIE, null).statusCode());
        assertEquals(List.of("hm-a"), backend.closed);
        HttpResponse<String> refused = post("/api/close", "{\"session\":\"busy\"}", COOKIE, null);
        assertEquals(409, refused.statusCode());
        assertEquals("It's still working.", MAPPER.readTree(refused.body()).path("error").asText());
        assertEquals(403, post("/api/close", "{\"session\":\"hm-a\"}", COOKIE, "http://evil.example").statusCode());
    }

    @Test
    void aSessionWhoseProgramEndedEndsTheStream() throws Exception {
        HttpRequest request = HttpRequest.newBuilder(uri("/api/stream?session=hm-a")).header("Cookie", COOKIE).build();
        HttpResponse<java.io.InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
            nextData(reader);
            backend.alive = false; // still listed by the daemon, but its program is gone
            String line;
            while ((line = reader.readLine()) != null && !line.equals("event: exited")) {
                // skip to the end
            }
            assertEquals("event: exited", line);
        }
    }

    @Test
    void theFirstScrollbackComesAfterTheScreenInPiecesThatCountUp() throws Exception {
        String line = "x".repeat(1000);
        for (int i = 0; i < 150; i++) {
            backend.history.add(i + line); // about 150 KB: three pieces
        }
        HttpRequest request = HttpRequest.newBuilder(uri("/api/stream?session=hm-a")).header("Cookie", COOKIE).build();
        HttpResponse<java.io.InputStream> response = http.send(request, HttpResponse.BodyHandlers.ofInputStream());
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(response.body(), StandardCharsets.UTF_8))) {
            String first;
            while ((first = reader.readLine()) != null && first.isEmpty()) {
                // skip blank lines
            }
            assertTrue(first.startsWith("data: "), "the screen comes first: " + first);
            StringBuilder joined = new StringBuilder();
            long lastLoaded = 0;
            int pieces = 0;
            JsonNode piece;
            do {
                piece = MAPPER.readTree(nextEvent(reader, "history"));
                assertEquals(pieces == 0, piece.path("reset").asBoolean());
                assertTrue(piece.path("loaded").asLong() > lastLoaded);
                lastLoaded = piece.path("loaded").asLong();
                if (pieces++ > 0) {
                    joined.append('\n');
                }
                joined.append(piece.path("text").asText());
            } while (!piece.path("done").asBoolean());
            assertEquals(3, pieces);
            assertEquals(String.join("\n", backend.history), joined.toString());
            assertEquals(piece.path("total").asLong(), lastLoaded);
        }
    }

    @Test
    void chunkLinesCutsAtLineEndsAndJoinsBack() {
        assertEquals(List.of("aa\nbb", "cc"), PhoneServer.chunkLines("aa\nbb\ncc", 6));
        assertEquals(List.of("toolongline", "x"), PhoneServer.chunkLines("toolongline\nx", 4));
        assertEquals(List.of(""), PhoneServer.chunkLines("", 10));
    }

    @Test
    void lastLinesKeepsTheNewest() {
        assertEquals("2\n3", PhoneServer.lastLines("1\n2\n3", 2));
        assertEquals("1\n2\n3", PhoneServer.lastLines("1\n2\n3", 5));
        assertEquals("", PhoneServer.lastLines("", 5));
    }

    /** The data of the next event named {@code name}. */
    private static String nextEvent(BufferedReader reader, String name) throws IOException {
        String line;
        boolean named = false;
        while ((line = reader.readLine()) != null) {
            if (line.equals("event: " + name)) {
                named = true;
            } else if (line.isEmpty()) {
                named = false;
            } else if (named && line.startsWith("data: ")) {
                return line.substring(6);
            }
        }
        throw new AssertionError("stream ended");
    }

    /** The data of the next screen: an event without a name. */
    private static String nextData(BufferedReader reader) throws IOException {
        String line;
        boolean named = false;
        while ((line = reader.readLine()) != null) {
            if (line.startsWith("event: ")) {
                named = true;
            } else if (line.isEmpty()) {
                named = false;
            } else if (!named && line.startsWith("data: ")) {
                return line.substring(6);
            }
        }
        throw new AssertionError("stream ended");
    }
}
