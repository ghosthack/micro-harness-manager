package io.github.ghosthack.microhm.app.harness;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Grok's registry and session layout, over a temporary home shaped like the real one. */
final class GrokSessionsTest {

    @TempDir
    Path home;

    /** 2026-11-09T04:57:44.123926Z in microseconds, as Grok writes pid_start. */
    private static final long START_MICROS = 1794200264123926L;
    private static final long START_MILLIS = START_MICROS / 1000;

    private void registry(String json) throws Exception {
        Files.writeString(home.resolve("active_sessions.json"), json);
    }

    private Path session(String cwdFolder, String id) throws Exception {
        Path dir = Files.createDirectories(home.resolve("sessions").resolve(cwdFolder).resolve(id));
        return Files.writeString(dir.resolve("chat_history.jsonl"), "{\"type\":\"system\"}\n");
    }

    @Test
    void theProcessesRegistrationLeadsToItsChatHistory() throws Exception {
        Path empty = session("%2FUsers%2Fme%2FProjects%2Fempty", "01a1beab-6014-7290-ade0-ed6d3190fcb4");
        Path spec = session("%2FUsers%2Fme%2FProjects%2Favc-spec", "01a1bec2-fed8-7691-b2cf-3efa30eb7a30");
        registry("""
                [
                  {"session_id": "01a1beab-6014-7290-ade0-ed6d3190fcb4", "pid": 2918,
                   "pid_start": %d, "cwd": "/Users/me/Projects/empty", "opened_at": "2026-11-09T04:57:45Z"},
                  {"session_id": "01a1bec2-fed8-7691-b2cf-3efa30eb7a30", "pid": 42411,
                   "pid_start": %d, "cwd": "/Users/me/Projects/avc-spec", "opened_at": "2026-11-09T05:23:32Z"}
                ]""".formatted(START_MICROS, START_MICROS + 1_500_000_000L));

        assertEquals(Optional.of(empty), GrokSessions.transcript(home, 2918, START_MILLIS));
        assertEquals(Optional.of(empty), GrokSessions.transcript(home, 2918, START_MILLIS + 1500),
                "start times a little apart are the same process");
        assertEquals(Optional.of(spec), GrokSessions.transcript(home, 42411, START_MILLIS + 1_500_000));
        assertEquals(Optional.of(empty), GrokSessions.transcript(home, 2918, 0), "start time unknown: by pid");
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 2918, START_MILLIS + 60_000),
                "the same pid started later is another process");
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 7, START_MILLIS), "not registered");
    }

    @Test
    void nothingWithoutARegistryAChatHistoryOrASaneId() throws Exception {
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 2918, START_MILLIS), "no registry");
        registry("not json");
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 2918, START_MILLIS));
        registry("{\"pid\": 2918}");
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 2918, START_MILLIS), "not an array");
        registry("[{\"session_id\": \"01a1\", \"pid\": 2918}]");
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 2918, START_MILLIS), "no chat history yet");
        session("x", "01a1");
        assertTrue(GrokSessions.transcript(home, 2918, START_MILLIS).isPresent());
        registry("[{\"session_id\": \"../x/01a1\", \"pid\": 2918}]");
        assertEquals(Optional.empty(), GrokSessions.transcript(home, 2918, START_MILLIS), "no path tricks");
    }

    @Test
    void itsExecutables() {
        assertTrue(GrokSessions.isExecutable("grok"));
        assertTrue(GrokSessions.isExecutable("grok-1.0.77-macos-aarch64"));
        assertFalse(GrokSessions.isExecutable("grokker"));
        assertFalse(GrokSessions.isExecutable("zsh"));
    }
}
