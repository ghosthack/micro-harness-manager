package io.github.ghosthack.microhm.app.phone;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.ghosthack.microhm.app.control.SessionController.HistoryView;
import io.github.ghosthack.microhm.app.control.SessionController.ScreenView;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.mcp.ToolResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * The phone page: a small web server for Safari (or any browser) on a phone on the same
 * network, or reaching it over a VPN. It serves the page's files and a JSON API over the
 * same session controller the MCP tools use.
 *
 * <p>Pages: {@code /} and the files beside it, from the jar's {@code /web/} folder, or
 * from a folder on disk named by {@code MICROHM_WEB_DIR} (or the {@code microhm.web.dir}
 * property), read on every request, so editing the page needs no rebuild or restart.
 *
 * <p>API, all JSON, all behind the secret:
 * <ul>
 *   <li>{@code POST /api/login {"token"}} sets the cookie that carries the secret from then on;</li>
 *   <li>{@code GET /api/sessions}, {@code GET /api/harnesses};</li>
 *   <li>{@code GET /api/screen?session=}, and {@code GET /api/stream?session=&cols=&rows=},
 *       Server-Sent Events with the screen each time it changes and {@code exited} when it
 *       ends. With {@code cols} and {@code rows} the session runs at the phone's size while
 *       any phone watches it, and gets its earlier size back when the last one leaves;</li>
 *   <li>{@code POST /api/send {session,text,enter}}, {@code POST /api/keys {session,keys}},
 *       {@code POST /api/spawn {harness,project,name,prompt}}, {@code POST /api/resume {session}};</li>
 *   <li>{@code GET /api/close-check?session=} says whether a session can be closed now and
 *       why not; {@code POST /api/close {session}} closes it politely or refuses (409);</li>
 *   <li>{@code GET /api/sessions} also lists the saved sessions that are not running, as
 *       {@code ended}, to resume.</li>
 * </ul>
 *
 * <p>A home tool, not a public service: one shared secret, plain HTTP, every interface.
 * Requests from another site's page are refused (the {@code Origin} must match the
 * {@code Host}), and the cookie is {@code SameSite=Strict}.
 */
public final class PhoneServer implements AutoCloseable {

    private static final Logger LOG = LoggerFactory.getLogger(PhoneServer.class);

    static final String COOKIE = "mhm_phone";
    static final String WEB_DIR_ENV = "MICROHM_WEB_DIR";
    static final String WEB_DIR_PROPERTY = "microhm.web.dir";
    static final int MAX_BODY = 64 * 1024;
    private static final Pattern FILE_NAME = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._-]*");
    private static final Set<String> TOOLS = Set.of("send", "keys", "spawn");
    static final int MIN_COLUMNS = 20;
    static final int MAX_COLUMNS = 400;
    static final int MIN_ROWS = 5;
    static final int MAX_ROWS = 200;
    /** How often an idle stream writes a comment line: a phone that has gone is noticed on
     * a write, and its session's size given back. */
    static final Duration KEEPALIVE = Duration.ofSeconds(5);
    /** Scrollback a stream starts with, at most: enough to read back, light enough for a phone. */
    static final int MAX_HISTORY_LINES = 2000;
    /** The size of each piece the first scrollback is sent in, so the page can show progress. */
    static final int HISTORY_CHUNK = 64 * 1024;
    /**
     * How long a session keeps the phone's size after the last phone leaves. A resize makes
     * an agent like Claude Code redraw its whole conversation, which takes seconds on a long
     * one and adds a copy to its scrollback; going back to the list and into the session
     * again within this time costs no resize at all.
     */
    static final Duration GIVE_BACK_AFTER = Duration.ofMinutes(1);
    private static final Map<String, String> TYPES = Map.of(
            "html", "text/html; charset=utf-8",
            "js", "text/javascript; charset=utf-8",
            "css", "text/css; charset=utf-8",
            "json", "application/json",
            "webmanifest", "application/manifest+json",
            "svg", "image/svg+xml",
            "png", "image/png");

    private final int requestedPort;
    private final byte[] token;
    private final PhoneBackend backend;
    private final Path webDir;
    private final Duration poll;
    private final Duration keepalive;
    private final Duration giveBackAfter;
    private final java.util.concurrent.ScheduledExecutorService giveBacks =
            Executors.newSingleThreadScheduledExecutor(Thread.ofPlatform().daemon().name("mhm-phone-size").factory());
    private final ObjectMapper json = new ObjectMapper();

    /** Sessions held at a phone's size, by session name; guarded by itself. */
    private final java.util.HashMap<String, Hold> holds = new java.util.HashMap<>();

    /** One lock per session name, held across a hold's or a size-back's daemon calls so the
     * two never interleave on one session (a phone arriving while the size-back is in flight
     * would otherwise take the phone size for the original, or be resized back under it).
     * Separate from {@link #holds}: a slow daemon stalls only that session's streams. */
    private final java.util.concurrent.ConcurrentHashMap<String, Object> sizeLocks =
            new java.util.concurrent.ConcurrentHashMap<>();

    private Object sizeLock(String name) {
        return sizeLocks.computeIfAbsent(name, n -> new Object());
    }

    /** A session some phones are watching: its size before the first one came, how many
     * watch, the size the last one asked for, and the size-back waiting to run once the
     * last one has left. */
    private static final class Hold {
        final int columns;
        final int rows;
        int viewers;
        int phoneColumns;
        int phoneRows;
        java.util.concurrent.ScheduledFuture<?> giveBack;

        Hold(int columns, int rows) {
            this.columns = columns;
            this.rows = rows;
        }
    }

    /** Draws screens in colour for streams that ask ({@code styled=1}); null: plain text only. */
    private volatile StyledScreen colours;

    private volatile boolean running;
    private HttpServer server;
    private ExecutorService executor;

    /**
     * @param port    TCP port on every interface; 0 picks a free one (tests)
     * @param token   the secret every API request must carry
     * @param webDir  where the page's files are read from, or null for the jar
     * @param poll    how often a stream looks at its session's screen
     */
    public PhoneServer(int port, String token, PhoneBackend backend, Path webDir, Duration poll) {
        this(port, token, backend, webDir, poll, KEEPALIVE, GIVE_BACK_AFTER);
    }

    PhoneServer(int port, String token, PhoneBackend backend, Path webDir, Duration poll, Duration keepalive,
                Duration giveBackAfter) {
        this.keepalive = Objects.requireNonNull(keepalive, "keepalive");
        this.giveBackAfter = Objects.requireNonNull(giveBackAfter, "giveBackAfter");
        if (token == null || token.isEmpty()) {
            throw new IllegalArgumentException("empty token");
        }
        this.requestedPort = port;
        this.token = token.getBytes(StandardCharsets.UTF_8);
        this.backend = Objects.requireNonNull(backend, "backend");
        this.webDir = webDir;
        this.poll = Objects.requireNonNull(poll, "poll");
    }

    /** Where files sent from the page are kept; beside the registry unless a test says. */
    private volatile Path uploadDir;

    void uploadDir(Path dir) {
        this.uploadDir = dir;
    }

    private Path uploadDir() {
        Path dir = uploadDir;
        return dir != null ? dir
                : io.github.ghosthack.microhm.app.registry.RegistryPaths.resolve().toAbsolutePath()
                        .resolveSibling("uploads");
    }

    /** The folder {@code MICROHM_WEB_DIR} or {@code -Dmicrohm.web.dir} names, if any. */
    public static Path webDirOverride() {
        String dir = System.getProperty(WEB_DIR_PROPERTY);
        if (dir == null || dir.isBlank()) {
            dir = System.getenv(WEB_DIR_ENV);
        }
        return dir == null || dir.isBlank() ? null : Path.of(dir);
    }

    public synchronized void start() throws IOException {
        if (server != null) {
            throw new IllegalStateException("already started");
        }
        HttpServer s = HttpServer.create(new InetSocketAddress(requestedPort), 0);
        executor = Executors.newThreadPerTaskExecutor(Thread.ofVirtual().name("mhm-phone-", 0).factory());
        s.setExecutor(executor);
        s.createContext("/", this::handle);
        running = true;
        s.start();
        server = s;
    }

    /** Lets streams that ask for it ({@code styled=1}) get the screen with its colours. */
    public void useColours(StyledScreen colours) {
        this.colours = colours;
    }

    public synchronized int port() {
        return server == null ? -1 : server.getAddress().getPort();
    }

    @Override
    /** Stops serving. Sessions still at a phone's size get their own back now: the streams
     * end (giving back at once, as the server is no longer running), then every size-back
     * still waiting runs. */
    public synchronized void close() {
        running = false;
        if (server != null) {
            server.stop(0);
            server = null;
        }
        if (executor != null) {
            executor.shutdownNow();
            try {
                executor.awaitTermination(1, java.util.concurrent.TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            executor = null;
        }
        List<String> waiting;
        synchronized (holds) {
            waiting = holds.entrySet().stream().filter(e -> e.getValue().viewers == 0)
                    .map(java.util.Map.Entry::getKey).toList();
        }
        waiting.forEach(this::giveBack);
        giveBacks.shutdownNow();
    }

    // ------------------------------------------------------------------ dispatch

    private void handle(HttpExchange ex) throws IOException {
        // the exchange closes after the error is sent: a try-with-resources would close it first
        try (ex) {
            route(ex);
        }
    }

    private void route(HttpExchange ex) throws IOException {
        try {
            String path = ex.getRequestURI().getPath();
            String method = ex.getRequestMethod();
            if (!path.startsWith("/api/")) {
                if (!method.equals("GET") && !method.equals("HEAD")) {
                    send(ex, 405, "text/plain", "method not allowed");
                    return;
                }
                serveFile(ex, path);
                return;
            }
            if (method.equals("POST") && !sameOrigin(ex)) {
                sendError(ex, 403, "request from another site refused");
                return;
            }
            if (path.equals("/api/login") && method.equals("POST")) {
                login(ex);
                return;
            }
            if (!authorized(ex)) {
                sendError(ex, 401, "open the phone link from Microhm's Settings on this phone");
                return;
            }
            switch (method + " " + path) {
                case "GET /api/sessions" -> sendJson(ex, 200, sessions());
                case "GET /api/harnesses" -> sendJson(ex, 200, harnesses());
                case "GET /api/screen" -> screen(ex);
                case "GET /api/stream" -> stream(ex);
                case "POST /api/send", "POST /api/keys", "POST /api/spawn" -> tool(ex, path.substring(5));
                case "POST /api/resume" -> resume(ex);
                case "GET /api/close-check" -> closeCheck(ex);
                case "POST /api/close" -> close(ex);
                case "POST /api/upload" -> upload(ex);
                default -> sendError(ex, 404, "no such endpoint");
            }
        } catch (RuntimeException e) {
            LOG.debug("phone request failed", e);
            try {
                sendError(ex, 500, message(e));
            } catch (IOException | RuntimeException ignored) {
                // headers already sent (a stream): nothing more to say
            }
        }
    }

    // ------------------------------------------------------------------ auth

    private void login(HttpExchange ex) throws IOException {
        JsonNode body = readJson(ex);
        String given = body == null ? "" : body.path("token").asText("");
        if (!matches(given)) {
            // a guess costs a second
            sleepQuietly(Duration.ofSeconds(1));
            sendError(ex, 401, "that link's secret is not the current one");
            return;
        }
        ex.getResponseHeaders().add("Set-Cookie", COOKIE + "=" + given
                + "; Path=/; HttpOnly; SameSite=Strict; Max-Age=31536000");
        sendJson(ex, 200, json.createObjectNode().put("ok", true));
    }

    private boolean authorized(HttpExchange ex) {
        String auth = ex.getRequestHeaders().getFirst("Authorization");
        if (auth != null && auth.regionMatches(true, 0, "Bearer ", 0, 7) && matches(auth.substring(7).trim())) {
            return true;
        }
        for (String header : ex.getRequestHeaders().getOrDefault("Cookie", java.util.List.of())) {
            for (String part : header.split(";")) {
                String p = part.trim();
                if (p.startsWith(COOKIE + "=") && matches(p.substring(COOKIE.length() + 1))) {
                    return true;
                }
            }
        }
        return false;
    }

    private boolean matches(String given) {
        return MessageDigest.isEqual(token, given.getBytes(StandardCharsets.UTF_8));
    }

    /** A POST without an Origin (not from a browser page) or from a page on this server. */
    static boolean sameOrigin(HttpExchange ex) {
        String origin = ex.getRequestHeaders().getFirst("Origin");
        if (origin == null) {
            return true;
        }
        String host = ex.getRequestHeaders().getFirst("Host");
        try {
            URI uri = URI.create(origin);
            String authority = uri.getRawAuthority();
            return host != null && authority != null && authority.equalsIgnoreCase(host);
        } catch (IllegalArgumentException e) {
            return false;
        }
    }

    // ------------------------------------------------------------------ API

    private ObjectNode sessions() {
        ObjectNode out = json.createObjectNode();
        out.set("sessions", json.valueToTree(backend.sessions()));
        ArrayNode ended = out.putArray("ended");
        for (var e : backend.ended()) {
            ended.addObject().put("name", e.name()).put("display", e.display()).put("harness", e.harness())
                    .put("project", e.project()).put("conversation", e.conversation())
                    .put("created", e.created() == null ? null : e.created().toString());
        }
        return out;
    }

    /** Whether the session can be closed now: {@code closable}, or the {@code reason} not. */
    private void closeCheck(HttpExchange ex) throws IOException {
        String session = query(ex, "session");
        if (session == null) {
            sendError(ex, 400, "session is required");
            return;
        }
        Optional<String> blocker;
        try {
            blocker = backend.closeBlocker(session);
        } catch (RuntimeException e) {
            sendError(ex, 404, message(e));
            return;
        }
        ObjectNode out = json.createObjectNode().put("ok", true).put("closable", blocker.isEmpty());
        blocker.ifPresent(reason -> out.put("reason", reason));
        sendJson(ex, 200, out);
    }

    private void close(HttpExchange ex) throws IOException {
        JsonNode args = readJson(ex);
        String session = args == null ? "" : args.path("session").asText("");
        if (session.isBlank()) {
            sendError(ex, 400, "session is required");
            return;
        }
        try {
            PhoneCloser.Outcome outcome = backend.close(session);
            sendJson(ex, outcome.closed() ? 200 : 409, json.createObjectNode().put("ok", outcome.closed())
                    .put("closed", outcome.closed()).put("error", outcome.closed() ? null : outcome.message()));
        } catch (RuntimeException e) {
            sendError(ex, 404, message(e));
        }
    }

    private void resume(HttpExchange ex) throws IOException {
        JsonNode args = readJson(ex);
        String session = args == null ? "" : args.path("session").asText("");
        if (session.isBlank()) {
            sendError(ex, 400, "session is required");
            return;
        }
        try {
            String name = backend.resume(session);
            sendJson(ex, 200, json.createObjectNode().put("ok", true).put("name", name));
        } catch (RuntimeException e) {
            sendError(ex, 400, message(e));
        }
    }

    private ObjectNode harnesses() {
        ObjectNode out = json.createObjectNode();
        ArrayNode ids = out.putArray("harnesses");
        for (HarnessType type : HarnessType.values()) {
            ids.add(type.id());
        }
        return out;
    }

    private void screen(HttpExchange ex) throws IOException {
        String session = query(ex, "session");
        if (session == null) {
            sendError(ex, 400, "session is required");
            return;
        }
        Optional<ScreenView> view;
        try {
            view = backend.screen(session);
        } catch (RuntimeException e) {
            sendError(ex, 404, message(e));
            return;
        }
        if (view.isEmpty()) {
            sendError(ex, 410, session + " has exited");
            return;
        }
        sendJson(ex, 200, json.valueToTree(view.get()));
    }

    /** Server-Sent Events: the screen now, then again each time it changes; a comment line
     * every 15 s keeps proxies and Safari from timing out; {@code exited} ends it. */
    private void stream(HttpExchange ex) throws IOException {
        String session = query(ex, "session");
        if (session == null) {
            sendError(ex, 400, "session is required");
            return;
        }
        ex.getResponseHeaders().set("Content-Type", "text/event-stream; charset=utf-8");
        ex.getResponseHeaders().set("Cache-Control", "no-cache");
        ex.sendResponseHeaders(200, 0);
        String held = hold(session, intQuery(ex, "cols"), intQuery(ex, "rows"));
        boolean styled = "1".equals(query(ex, "styled"));
        try {
            streamScreens(ex.getResponseBody(), session, styled);
        } finally {
            if (held != null) {
                release(held);
            }
        }
    }

    /**
     * The stream's loop. The screen goes first, so a phone sees something at once; the
     * scrollback follows, the first time in pieces of {@link #HISTORY_CHUNK} bytes that
     * each say how much of the total has been sent ({@code loaded}, {@code total},
     * {@code done}), so the page can show its progress; afterwards only new lines.
     */
    private void streamScreens(OutputStream out, String session, boolean styled) throws IOException {
        String last = null;
        long lastWrite = System.nanoTime();
        long historyAdded = -1; // nothing sent yet: the first history is everything held
        while (running) {
            boolean wrote = false;
            try {
                Optional<ScreenView> view = backend.screen(session);
                // gone, or its program ended while the daemon still lists it
                if (view.isEmpty() || !view.get().alive()) {
                    write(out, "event: exited\ndata: {}\n\n");
                    return;
                }
                ObjectNode screen = json.valueToTree(view.get());
                StyledScreen drawer = colours;
                if (styled && drawer != null) {
                    // the same screen with its colours: rows of styled runs (see StyledScreen)
                    backend.ansi(session).ifPresent(a -> screen.set("styled", drawer.render(a.text(), a.columns(), a.rows())));
                }
                String data = json.writeValueAsString(screen);
                if (!data.equals(last)) {
                    write(out, "data: " + data + "\n\n"); // throws once the phone has gone
                    wrote = true;
                }
                last = data;
                Optional<HistoryView> history = backend.history(session, Math.max(0, historyAdded));
                if (history.isPresent() && (historyAdded < 0 || history.get().added() != historyAdded)) {
                    String text = historyAdded < 0 ? lastLines(history.get().text(), MAX_HISTORY_LINES)
                            : history.get().text();
                    // a count that went down: the session's history was cleared, start over
                    boolean reset = historyAdded < 0 || history.get().added() < historyAdded;
                    writeHistory(out, text, reset);
                    wrote = true;
                    historyAdded = history.get().added();
                }
            } catch (RuntimeException e) {
                write(out, "event: problem\ndata: " + json.writeValueAsString(
                        json.createObjectNode().put("error", message(e))) + "\n\n");
                wrote = true;
                last = null;
            }
            if (!wrote && System.nanoTime() - lastWrite > keepalive.toNanos()) {
                write(out, ": ping\n\n");
                wrote = true;
            }
            if (wrote) {
                lastWrite = System.nanoTime();
            }
            if (!sleepQuietly(poll)) {
                return;
            }
        }
    }

    /** {@code text} as history events of at most {@link #HISTORY_CHUNK} bytes, cut at line
     * ends, each with how many bytes have been sent so far of how many. */
    private void writeHistory(OutputStream out, String text, boolean reset) throws IOException {
        List<String> chunks = chunkLines(text, HISTORY_CHUNK);
        long total = text.getBytes(StandardCharsets.UTF_8).length;
        long loaded = 0;
        for (int i = 0; i < chunks.size(); i++) {
            String chunk = chunks.get(i);
            loaded += chunk.getBytes(StandardCharsets.UTF_8).length + (i < chunks.size() - 1 ? 1 : 0);
            write(out, "event: history\ndata: " + json.writeValueAsString(json.createObjectNode()
                    .put("text", chunk).put("reset", reset && i == 0)
                    .put("loaded", loaded).put("total", total).put("done", i == chunks.size() - 1)) + "\n\n");
        }
    }

    /** {@code text} cut at line ends into pieces of at most about {@code maxBytes} each (a
     * longer line is one piece); joined with line breaks they make {@code text} again. */
    static List<String> chunkLines(String text, int maxBytes) {
        List<String> chunks = new java.util.ArrayList<>();
        StringBuilder chunk = new StringBuilder();
        int bytes = 0;
        for (String line : text.split("\n", -1)) {
            int size = line.getBytes(StandardCharsets.UTF_8).length + 1;
            if (bytes > 0 && bytes + size > maxBytes) {
                chunks.add(chunk.toString());
                chunk.setLength(0);
                bytes = 0;
            }
            if (bytes > 0) {
                chunk.append('\n');
            }
            chunk.append(line);
            bytes += size;
        }
        chunks.add(chunk.toString());
        return chunks;
    }

    /**
     * Runs {@code session} at the phone's size while this stream lasts; the session's name,
     * to {@link #release} afterwards, or null when no (valid) size was asked for or the
     * session cannot be resized.
     */
    private String hold(String session, Integer columns, Integer rows) {
        if (columns == null || rows == null || columns < MIN_COLUMNS || columns > MAX_COLUMNS
                || rows < MIN_ROWS || rows > MAX_ROWS) {
            return null;
        }
        try {
            Optional<ScreenView> view = backend.screen(session);
            if (view.isEmpty()) {
                return null;
            }
            String name = view.get().name();
            synchronized (sizeLock(name)) {
                // read again under the session's lock: a size-back may have just run
                Optional<ScreenView> now = backend.screen(name);
                if (now.isEmpty()) {
                    return null;
                }
                int currentColumns = now.get().columns();
                int currentRows = now.get().rows();
                synchronized (holds) {
                    Hold hold = holds.computeIfAbsent(name, n -> new Hold(currentColumns, currentRows));
                    if (hold.giveBack != null) {
                        hold.giveBack.cancel(false); // back within the grace time: keep the size
                        hold.giveBack = null;
                    }
                    hold.viewers++;
                    hold.phoneColumns = columns;
                    hold.phoneRows = rows;
                }
                // the daemon call stays outside the holds lock: a slow daemon must not stall
                // every other stream's hold and release (and the server's close)
                if (currentColumns != columns || currentRows != rows) {
                    try {
                        backend.resize(name, columns, rows);
                    } catch (RuntimeException e) {
                        // no stream will release this hold: count the viewer out again, or
                        // the session never gets its size back
                        release(name);
                        throw e;
                    }
                }
                return name;
            }
        } catch (RuntimeException e) {
            LOG.debug("could not size {} for the phone", session, e);
            return null;
        }
    }

    /** One phone stopped watching {@code name}. When it was the last, the session gets its
     * size back after {@link #giveBackAfter} (at once when the server is closing), unless a
     * phone comes back first. */
    private void release(String name) {
        synchronized (holds) {
            Hold hold = holds.get(name);
            if (hold == null || --hold.viewers > 0) {
                return;
            }
            if (running && !giveBackAfter.isZero()) {
                hold.giveBack = giveBacks.schedule(() -> giveBack(name), giveBackAfter.toMillis(),
                        java.util.concurrent.TimeUnit.MILLISECONDS);
                return;
            }
        }
        giveBack(name); // at once, and outside the lock (it calls the daemon)
    }

    /** Gives {@code name} its size from before the phones came, unless something else (the
     * app's window) has resized it since, or a phone is watching it again. */
    private void giveBack(String name) {
        synchronized (sizeLock(name)) { // a phone arriving now waits until the size is back
            Hold hold;
            synchronized (holds) {
                hold = holds.get(name);
                if (hold == null || hold.viewers > 0) {
                    return;
                }
                holds.remove(name);
            }
            // the daemon calls stay outside the holds lock (see hold)
            try {
                Optional<ScreenView> view = backend.screen(name);
                if (view.isPresent() && view.get().columns() == hold.phoneColumns
                        && view.get().rows() == hold.phoneRows) {
                    backend.resize(name, hold.columns, hold.rows);
                }
            } catch (RuntimeException e) {
                LOG.debug("could not give {} its size back", name, e);
            }
        }
    }

    private void tool(HttpExchange ex, String tool) throws IOException {
        if (!TOOLS.contains(tool)) {
            sendError(ex, 404, "no such endpoint");
            return;
        }
        JsonNode args = readJson(ex);
        if (args == null || !args.isObject()) {
            sendError(ex, 400, "expected a JSON object");
            return;
        }
        ToolResult result = backend.call(tool, args);
        ObjectNode out = json.createObjectNode().put("ok", !result.isError()).put("text", result.text());
        sendJson(ex, result.isError() ? 400 : 200, out);
    }

    // ------------------------------------------------------------------ files

    private void serveFile(HttpExchange ex, String path) throws IOException {
        String name = path.equals("/") ? "index.html" : path.substring(1);
        if (!FILE_NAME.matcher(name).matches()) {
            send(ex, 404, "text/plain", "not found");
            return;
        }
        byte[] bytes = readPageFile(name);
        if (bytes == null) {
            send(ex, 404, "text/plain", "not found");
            return;
        }
        String ext = name.substring(name.lastIndexOf('.') + 1);
        ex.getResponseHeaders().set("Cache-Control", "no-cache");
        send(ex, 200, TYPES.getOrDefault(ext, "application/octet-stream"), bytes);
    }

    private byte[] readPageFile(String name) throws IOException {
        if (webDir != null) {
            Path file = webDir.resolve(name);
            return Files.isRegularFile(file) ? Files.readAllBytes(file) : null;
        }
        try (InputStream in = PhoneServer.class.getResourceAsStream("/web/" + name)) {
            return in == null ? null : in.readAllBytes();
        }
    }

    // ------------------------------------------------------------------ helpers

    /**
     * Keeps the request body as a file (a screenshot, say) and answers its absolute path, for
     * the page to put in the message. {@code ?name=} is the file's own name, kept for its
     * extension and as a hint in the saved name.
     */
    private void upload(HttpExchange ex) throws IOException {
        String length = ex.getRequestHeaders().getFirst("Content-Length");
        if (length != null) {
            try {
                if (Long.parseLong(length.trim()) > PhoneUploads.MAX_BYTES) {
                    sendError(ex, 413, new PhoneUploads.TooLarge().getMessage());
                    return;
                }
            } catch (NumberFormatException ignored) {
                // read it and count instead
            }
        }
        Path saved;
        try (InputStream body = ex.getRequestBody()) {
            saved = new PhoneUploads(uploadDir(), java.time.Clock.systemDefaultZone())
                    .save(body, query(ex, "name"), ex.getRequestHeaders().getFirst("Content-Type"));
        } catch (PhoneUploads.TooLarge e) {
            sendError(ex, 413, e.getMessage());
            return;
        } catch (IOException e) {
            LOG.debug("could not keep an upload", e);
            sendError(ex, 400, "could not keep that file: " + e.getMessage());
            return;
        }
        LOG.info("kept a file from the phone page at {}", saved);
        sendJson(ex, 200, json.createObjectNode().put("ok", true).put("path", saved.toString()));
    }

    private JsonNode readJson(HttpExchange ex) throws IOException {
        byte[] body = ex.getRequestBody().readNBytes(MAX_BODY + 1);
        if (body.length > MAX_BODY) {
            return null;
        }
        try {
            return json.readTree(body);
        } catch (IOException e) {
            return null;
        }
    }

    private static String query(HttpExchange ex, String key) {
        String raw = ex.getRequestURI().getRawQuery();
        if (raw == null) {
            return null;
        }
        for (String pair : raw.split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && pair.substring(0, eq).equals(key)) {
                String value = URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
                return value.isBlank() ? null : value;
            }
        }
        return null;
    }

    /** The last {@code max} lines of {@code text}. */
    static String lastLines(String text, int max) {
        int at = text.length();
        for (int n = 0; n < max && at > 0; n++) {
            at = text.lastIndexOf('\n', at - 1);
            if (at < 0) {
                return text;
            }
        }
        return at <= 0 ? text : text.substring(at + 1);
    }

    private static Integer intQuery(HttpExchange ex, String key) {
        String value = query(ex, key);
        if (value == null) {
            return null;
        }
        try {
            return Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private void sendJson(HttpExchange ex, int status, JsonNode body) throws IOException {
        send(ex, status, "application/json", json.writeValueAsBytes(body));
    }

    private void sendError(HttpExchange ex, int status, String message) throws IOException {
        sendJson(ex, status, json.createObjectNode().put("ok", false).put("error", message));
    }

    private static void send(HttpExchange ex, int status, String type, String body) throws IOException {
        send(ex, status, type, body.getBytes(StandardCharsets.UTF_8));
    }

    private static void send(HttpExchange ex, int status, String type, byte[] body) throws IOException {
        ex.getResponseHeaders().set("Content-Type", type);
        boolean head = ex.getRequestMethod().equals("HEAD");
        ex.sendResponseHeaders(status, head ? -1 : body.length);
        if (!head) {
            ex.getResponseBody().write(body);
        }
    }

    private static void write(OutputStream out, String text) throws IOException {
        out.write(text.getBytes(StandardCharsets.UTF_8));
        out.flush();
    }

    private static String message(RuntimeException e) {
        return e.getMessage() != null ? e.getMessage() : e.toString();
    }

    /** False when interrupted (the server is closing). */
    private static boolean sleepQuietly(Duration d) {
        try {
            Thread.sleep(d);
            return true;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }
}
