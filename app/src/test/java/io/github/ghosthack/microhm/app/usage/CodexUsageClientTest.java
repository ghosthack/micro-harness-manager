package io.github.ghosthack.microhm.app.usage;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;

final class CodexUsageClientTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** The fake server runs as {@code /bin/sh <file>}: a script file sidesteps quoting a
     * long {@code -c} argument. */
    private static Process startFakeServer(String script) throws IOException {
        Path scriptFile = Files.createTempFile("codex-fake-server", ".sh");
        scriptFile.toFile().deleteOnExit();
        Files.writeString(scriptFile, script, StandardCharsets.UTF_8);
        return new ProcessBuilder("/bin/sh", scriptFile.toString()).start();
    }

    @Test
    void returnsAndStopsAppServerAfterResponsesArrive() throws Exception {
        String fakeServer = """
                while IFS= read -r line; do
                  case "$line" in
                    *'"id":1'*) echo '{"id":1,"result":{"userAgent":"test"}}' ;;
                    *'"id":2'*) echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":23,"windowDurationMins":300}}}}' ;;
                    *'"id":3'*) echo '{"id":3,"result":{"summary":{"lifetimeTokens":42}}}' ;;
                  esac
                done
                """;
        Process process = startFakeServer(fakeServer);

        UsageSnapshot snapshot = assertTimeoutPreemptively(Duration.ofSeconds(3),
                () -> new CodexUsageClient().load(process));

        assertEquals(23, snapshot.limits().getFirst().usedPercent());
        assertTrue(snapshot.statistics().contains(
                new UsageSnapshot.Statistic("Lifetime tokens", "42")));
        assertFalse(process.isAlive());
    }

    @Test
    void parsesAllRateLimitBucketsAndTokenSummary() throws Exception {
        JsonNode rates = MAPPER.readTree("""
                {
                  "rateLimits": {
                    "limitId": "codex",
                    "primary": {"usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1787804546},
                    "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
                    "planType": "pro"
                  },
                  "rateLimitsByLimitId": {
                    "codex": {
                      "limitId": "codex",
                      "primary": {"usedPercent": 18, "windowDurationMins": 10080, "resetsAt": 1787804546}
                    },
                    "spark": {
                      "limitId": "spark",
                      "limitName": "GPT Spark",
                      "primary": {"usedPercent": 2, "windowDurationMins": 300, "resetsAt": 1787453913},
                      "secondary": {"usedPercent": 7, "windowDurationMins": 10080, "resetsAt": 1788040713}
                    }
                  },
                  "rateLimitResetCredits": {"availableCount": 1}
                }
                """);
        JsonNode usage = MAPPER.readTree("""
                {"summary": {
                  "lifetimeTokens": 12345678,
                  "peakDailyTokens": 1234,
                  "longestRunningTurnSec": 3725,
                  "currentStreakDays": 3,
                  "longestStreakDays": 8
                }}
                """);

        UsageSnapshot snapshot = CodexUsageClient.parse(rates, usage);

        assertEquals(3, snapshot.limits().size());
        assertEquals("Codex · 1 week", snapshot.limits().getFirst().label());
        assertEquals(18, snapshot.limits().getFirst().usedPercent());
        assertEquals(Instant.ofEpochSecond(1787804546),
                snapshot.limits().getFirst().resetsAt().orElseThrow());
        assertEquals("GPT Spark · 5 hours", snapshot.limits().get(1).label());
        assertTrue(snapshot.statistics().contains(new UsageSnapshot.Statistic("Plan", "Pro")));
        assertTrue(snapshot.statistics().contains(
                new UsageSnapshot.Statistic("Lifetime tokens", "12,345,678")));
        assertTrue(snapshot.statistics().contains(new UsageSnapshot.Statistic("Longest turn", "1h 2m")));
        assertTrue(snapshot.note().isEmpty());
    }

    @Test
    void keepsLimitsWhenOlderCodexHasNoUsageMethod() throws Exception {
        JsonNode rates = MAPPER.readTree("""
                {"rateLimits": {
                  "primary": {"usedPercent": 51, "windowDurationMins": 300}
                }}
                """);

        UsageSnapshot snapshot = CodexUsageClient.parse(rates, null);

        assertEquals(1, snapshot.limits().size());
        assertEquals("Codex · 5 hours", snapshot.limits().getFirst().label());
        assertTrue(snapshot.note().orElseThrow().contains("not aggregate token usage"));
    }
}
