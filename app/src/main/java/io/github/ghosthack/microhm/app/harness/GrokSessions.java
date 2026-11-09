package io.github.ghosthack.microhm.app.harness;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;
import java.util.stream.Stream;

/**
 * Where Grok keeps its conversations: {@code <home>/sessions/<URL-encoded cwd>/<session
 * id>/}, whose {@code chat_history.jsonl} is the conversation (JSONL rows of
 * {@code "type"} {@code system}, {@code user}, {@code assistant} and {@code tool_result}).
 * A running Grok registers itself in {@code <home>/active_sessions.json} — its pid, its
 * start time in microseconds ({@code pid_start}), its cwd and its session id — which is
 * how a pane's session is found without guessing. The home is {@code $GROK_HOME}, else
 * {@code ~/.grok}.
 */
public final class GrokSessions {

    /** The conversation in a session directory. */
    public static final String TRANSCRIPT = "chat_history.jsonl";

    /** How far a registered start time may be from the process's own and still be it. */
    static final long START_TOLERANCE_MILLIS = 2_000;

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String SESSION_ID = "[A-Za-z0-9-]+";

    private GrokSessions() {
    }

    /** {@code $GROK_HOME}, else {@code ~/.grok}. */
    public static Path home() {
        String home = System.getenv("GROK_HOME");
        return home != null && !home.isBlank()
                ? Path.of(home)
                : Path.of(System.getProperty("user.home"), ".grok");
    }

    /** Whether an executable's file name is Grok's ({@code grok}, or the versioned
     * {@code grok-<version>-<platform>} it links to). */
    public static boolean isExecutable(String fileName) {
        return fileName.equals("grok") || fileName.startsWith("grok-");
    }

    /**
     * The transcript of the Grok process {@code pid} (started at {@code startMillis}, 0 =
     * unknown), when it is registered in {@code active_sessions.json} and its
     * {@code chat_history.jsonl} exists. A registration with the same pid but another
     * start time is a process that held the pid before, not this one.
     */
    public static Optional<Path> transcript(Path home, long pid, long startMillis) {
        Path registry = home.resolve("active_sessions.json");
        JsonNode sessions;
        try {
            sessions = MAPPER.readTree(registry.toFile());
        } catch (IOException | RuntimeException e) {
            return Optional.empty();
        }
        if (sessions == null || !sessions.isArray()) {
            return Optional.empty();
        }
        for (JsonNode session : sessions) {
            if (session.path("pid").asLong(-1) != pid) {
                continue;
            }
            long registeredMillis = session.path("pid_start").asLong(0) / 1000;
            if (startMillis > 0 && registeredMillis > 0
                    && Math.abs(registeredMillis - startMillis) > START_TOLERANCE_MILLIS) {
                continue;
            }
            String id = session.path("session_id").asText("");
            if (id.matches(SESSION_ID)) {
                Optional<Path> found = sessionTranscript(home.resolve("sessions"), id);
                if (found.isPresent()) {
                    return found;
                }
            }
        }
        return Optional.empty();
    }

    /** {@code <sessions>/<any cwd folder>/<id>/chat_history.jsonl}: the id is unique, so
     * the cwd folder's encoding never has to be reproduced. */
    private static Optional<Path> sessionTranscript(Path sessions, String id) {
        try (Stream<Path> folders = Files.list(sessions)) {
            return folders
                    .map(folder -> folder.resolve(id).resolve(TRANSCRIPT))
                    .filter(Files::isRegularFile)
                    .findFirst();
        } catch (IOException | RuntimeException e) {
            return Optional.empty();
        }
    }
}
