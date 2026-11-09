package io.github.ghosthack.microhm.app.harness;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Muse's session layout, over a temporary sessions root shaped like the real one. */
final class MuseSessionsTest {

    @TempDir
    Path root;

    @Test
    void anOpenFileInADatedSessionDirectoryLeadsToItsSessionLog() throws Exception {
        Path session = Files.createDirectories(root.resolve("2026/11/08/01a1be9d-d2f1-7f23-9d66-e54fc58ac046"));
        Path log = Files.writeString(session.resolve("session.jsonl"), "{}\n");
        Path lock = Files.createFile(session.resolve(".session.lock"));
        Path subagent = Files.createDirectories(session.resolve("subagent/x")).resolve("y.jsonl");

        assertEquals(Optional.of(log), MuseSessions.transcriptOf(root, lock), "the lock a running Muse holds");
        assertEquals(Optional.of(log), MuseSessions.transcriptOf(root, log));
        assertEquals(Optional.of(log), MuseSessions.transcriptOf(root, subagent), "a sub-agent's file: its session");
        assertEquals(Optional.of(log), MuseSessions.transcriptOf(root, root.resolve("2026/11/../11/08/"
                + "01a1be9d-d2f1-7f23-9d66-e54fc58ac046/.session.lock")), "normalized");
    }

    @Test
    void filesOutsideADatedSessionDirectoryLeadNowhere() throws Exception {
        Path view = Files.createDirectories(root.resolve(".msp-view-g6/01a1/x"));
        Files.writeString(view.getParent().resolve("session.jsonl"), "{}\n");
        Path noLogYet = Files.createDirectories(root.resolve("2026/11/09/01a2"));

        assertEquals(Optional.empty(), MuseSessions.transcriptOf(root, view.resolve("index-00000000.bin")));
        assertEquals(Optional.empty(), MuseSessions.transcriptOf(root, root.resolve("../session-index.db")));
        assertEquals(Optional.empty(), MuseSessions.transcriptOf(root, noLogYet.resolve(".session.lock")),
                "no session.jsonl written yet");
        assertEquals(Optional.empty(), MuseSessions.transcriptOf(root, root.resolve("2026/11/09")));
        assertEquals(Optional.empty(), MuseSessions.transcriptOf(root, Path.of("/elsewhere/2026/11/08/a/b")));
    }

    @Test
    void itsExecutablesAndRoot() {
        assertTrue(MuseSessions.isExecutable("muse"));
        assertTrue(MuseSessions.isExecutable("muse-bin-1.4.14-R7309.1"));
        assertFalse(MuseSessions.isExecutable("museum"));
        assertFalse(MuseSessions.isExecutable("bash"));
        assertTrue(MuseSessions.root().endsWith(Path.of("muse", "sessions")));
    }
}
