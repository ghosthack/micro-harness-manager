package io.github.ghosthack.microhm.app.control;

import io.github.ghosthack.microhm.mux.session.Session;
import io.github.ghosthack.microhm.vt.HeadlessTerminal;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.zip.GZIPInputStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The log files themselves: rolling into compressed parts, and progress kept across a restart. */
final class SessionLogsTest {

    @TempDir
    Path project;

    private static final Instant NOW = Instant.parse("2026-11-09T06:00:00Z");

    /** A capture whose scrollback has {@code added} lines in all, ending with {@code text}. */
    private static Session.Capture scrolled(String text, long added) {
        int held = (int) text.chars().filter(c -> c == '\n').count();
        return new Session.Capture("$ \n", true, "zsh", 77, "", 80, 24, 0, true)
                .withHistory(new HeadlessTerminal.History(text, held, added, false));
    }

    private static String numbered(int from, int to) {
        StringBuilder sb = new StringBuilder();
        for (int i = from; i <= to; i++) {
            sb.append("row ").append(i).append('\n');
        }
        return sb.toString();
    }

    private static String gunzip(Path part) throws Exception {
        try (InputStream in = new GZIPInputStream(Files.newInputStream(part))) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    @Test
    void theLiveFileRollsIntoNumberedCompressedPartsAndNothingIsLost() throws Exception {
        SessionLogs logs = new SessionLogs();
        SessionLogs.Log log = logs.open(project, "mhm-x");
        Path folder = project.resolve(SessionLogs.FOLDER);
        assertEquals(folder.resolve("mhm-x.log"), log.file());

        log.record(scrolled(numbered(1, 1500), 1500), NOW);
        for (int from = 1501; from <= 9001; from += 1500) {
            log.record(scrolled(numbered(from, from + 1499), log.since() + 1500), NOW);
        }
        assertEquals(10_500, log.since());
        Path first = folder.resolve("mhm-x.0001.log.gz");
        assertTrue(Files.exists(first));
        assertFalse(Files.exists(folder.resolve("mhm-x.0002.log.gz")));
        assertEquals(numbered(1, 7500), gunzip(first), "rolled before it would pass 8000 lines");
        assertEquals(numbered(7501, 10_500), Files.readString(log.file()));

        // a restarted app picks up where the log left off, parts and all
        SessionLogs.Log again = new SessionLogs().open(project, "mhm-x");
        assertEquals(10_500, again.since());
        assertEquals(77, again.pid());
        again.record(scrolled(numbered(10_501, 16_000), 16_000), NOW);
        assertEquals(numbered(7501, 10_500), gunzip(folder.resolve("mhm-x.0002.log.gz")),
                "it knew how full the live file was");
        assertEquals(numbered(10_501, 16_000), Files.readString(again.file()));
    }

    @Test
    void namesAreKeptToSafeCharacters() {
        assertEquals(project.resolve(SessionLogs.FOLDER).resolve("a_b_c.log"), SessionLogs.file(project, "a/b c"));
    }
}
