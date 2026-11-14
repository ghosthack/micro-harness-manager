package io.github.ghosthack.microhm.app.control;

import io.github.ghosthack.microhm.mux.session.Session;
import io.github.ghosthack.microhm.vt.HeadlessTerminal;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.time.Instant;
import java.util.zip.GZIPInputStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

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

        log.record(scrolled(numbered(1, 1500), 1500), s -> s, NOW);
        for (int from = 1501; from <= 9001; from += 1500) {
            log.record(scrolled(numbered(from, from + 1499), log.since() + 1500), s -> s, NOW);
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
        again.record(scrolled(numbered(10_501, 16_000), 16_000), s -> s, NOW);
        assertEquals(numbered(7501, 10_500), gunzip(folder.resolve("mhm-x.0002.log.gz")),
                "it knew how full the live file was");
        assertEquals(numbered(10_501, 16_000), Files.readString(again.file()));
    }

    /** A full-screen capture showing {@code screen}, with no scrollback. */
    private static Session.Capture fullScreen(String screen) {
        return new Session.Capture(screen, true, "grok", 77, "", 80, 24, 0, true)
                .withHistory(new HeadlessTerminal.History("", 0, 0, true));
    }

    @Test
    void aFullScreenProgramsLinesAreWrittenAsTheyAppearEachOnceAndWithoutItsChrome() throws Exception {
        SessionLogs.Log log = new SessionLogs().open(project, "mhm-g");
        java.util.function.UnaryOperator<String> chrome =
                screen -> screen.lines().filter(l -> !l.startsWith("status")).reduce("", (a, l) -> a + l + "\n");
        log.record(fullScreen("Grok\nstatus 1s\n"), chrome, NOW);
        log.record(fullScreen("Grok\n1. one\nstatus 2s\n"), chrome, NOW.plusSeconds(1));
        log.record(fullScreen("Grok\n1. one\n2. two\nstatus 3s\n"), chrome, NOW.plusSeconds(2));
        log.record(fullScreen("Grok\n2. two\n3. thr\nstatus 4s\n"), chrome, NOW.plusSeconds(3)); // scrolled in place
        assertEquals("--- microhm · 2026-11-09T06:00:01Z · screen ---\nGrok\n1. one\n2. two\n",
                Files.readString(log.file()), "the bottom row waits: it may be still being drawn");
        log.record(fullScreen("Grok\n2. two\n3. three\nstatus 5s\n"), chrome, NOW.plusSeconds(4));
        log.record(fullScreen("Grok\n2. two\n3. three\nstatus 6s\n"), chrome, NOW.plusSeconds(5));
        String expected = "--- microhm · 2026-11-09T06:00:01Z · screen ---\nGrok\n1. one\n2. two\n3. three\n";
        assertEquals(expected, Files.readString(log.file()), "until it holds");

        // a restarted app remembers what it wrote lately
        SessionLogs.Log again = new SessionLogs().open(project, "mhm-g");
        again.record(fullScreen("Grok\n3. three\n4. four\n"), chrome, NOW.plusSeconds(9));
        again.record(fullScreen("Grok\n3. three\n4. four\n"), chrome, NOW.plusSeconds(9));
        assertEquals(expected + "--- microhm · 2026-11-09T06:00:09Z · screen ---\n4. four\n", Files.readString(log.file()));
    }

    private static void deleteTree(Path root) throws Exception {
        try (java.util.stream.Stream<Path> walk = Files.walk(root)) {
            for (Path p : walk.sorted(java.util.Comparator.reverseOrder()).toList()) {
                Files.delete(p);
            }
        }
    }

    /** {@code git clean -fdx} in the project takes the folder with it: the log starts
     * again there, without losing the lines it could not write meanwhile. */
    @Test
    void aDeletedFolderIsMadeAgainAndTheLogGoesOn() throws Exception {
        SessionLogs.Log log = new SessionLogs().open(project, "mhm-x");
        Path folder = project.resolve(SessionLogs.FOLDER);
        log.record(scrolled(numbered(1, 3), 3), s -> s, NOW);
        deleteTree(folder);
        log.record(scrolled(numbered(4, 5), 5), s -> s, NOW);
        assertEquals(numbered(4, 5), Files.readString(log.file()));
        assertEquals("*\n", Files.readString(folder.resolve(".gitignore")));
        assertEquals(5, new SessionLogs().open(project, "mhm-x").since());
    }

    @Test
    void aFailedWriteLeavesTheLinesToBeWrittenNextTime() throws Exception {
        SessionLogs.Log log = new SessionLogs().open(project, "mhm-x");
        Path folder = project.resolve(SessionLogs.FOLDER);
        log.record(scrolled(numbered(1, 3), 3), s -> s, NOW);
        deleteTree(folder);
        Files.writeString(folder, "in the way"); // a file where the folder was: nothing can be written
        org.junit.jupiter.api.Assertions.assertThrows(RuntimeException.class,
                () -> log.record(scrolled(numbered(4, 5), 5), s -> s, NOW));
        assertEquals(3, log.since(), "not counted as written");
        Files.delete(folder);
        log.record(scrolled(numbered(4, 5), 5), s -> s, NOW);
        assertEquals(numbered(4, 5), Files.readString(log.file()));
    }

    /** A project is not trusted: a planted link must not send sessions' output elsewhere. */
    @Test
    void linksPlantedInTheProjectAreNotWrittenThrough(@TempDir Path elsewhere) throws Exception {
        org.junit.jupiter.api.Assumptions.assumeFalse(
                System.getProperty("os.name").toLowerCase().contains("win"), "needs symbolic links");
        Path folder = project.resolve(SessionLogs.FOLDER);
        Files.createSymbolicLink(folder, elsewhere);
        org.junit.jupiter.api.Assertions.assertThrows(RuntimeException.class,
                () -> new SessionLogs().open(project, "mhm-x"));
        assertEquals(0, Files.list(elsewhere).count());

        Files.delete(folder);
        Files.createDirectories(folder);
        Path victim = elsewhere.resolve("victim");
        Files.writeString(victim, "mine\n");
        Files.createSymbolicLink(folder.resolve("mhm-x.log"), victim);
        SessionLogs.Log log = new SessionLogs().open(project, "mhm-x");
        org.junit.jupiter.api.Assertions.assertThrows(RuntimeException.class,
                () -> log.record(scrolled(numbered(1, 2), 2), s -> s, NOW));
        assertEquals("mine\n", Files.readString(victim));
    }

    @Test
    void anIdleSessionDoesNotRewriteItsState() throws Exception {
        SessionLogs.Log log = new SessionLogs().open(project, "mhm-x");
        log.record(scrolled(numbered(1, 3), 3), s -> s, NOW);
        Path state = project.resolve(SessionLogs.FOLDER).resolve(".mhm-x.state");
        Files.setLastModifiedTime(state, java.nio.file.attribute.FileTime.fromMillis(1000));
        log.record(scrolled("", 3), s -> s, NOW.plusSeconds(1));
        assertEquals(1000, Files.getLastModifiedTime(state).toMillis());
    }

    private static String permissions(Path file) throws Exception {
        return PosixFilePermissions.toString(Files.getPosixFilePermissions(file, LinkOption.NOFOLLOW_LINKS));
    }

    @Test
    void theFolderAndTheFilesMadeInItAreTheOwnersAlone() throws Exception {
        assumeTrue(project.getFileSystem().supportedFileAttributeViews().contains("posix"));
        Path folder = project.resolve(SessionLogs.FOLDER);
        Files.createDirectory(folder); // left by an earlier version, open to others
        Files.setPosixFilePermissions(folder, PosixFilePermissions.fromString("rwxr-xr-x"));

        SessionLogs.Log log = new SessionLogs().open(project, "mhm-p");
        assertEquals("rwx------", permissions(folder), "an existing folder is closed too");
        log.record(scrolled(numbered(1, 5000), 5000), s -> s, NOW);
        log.record(scrolled(numbered(5001, 10_000), 10_000), s -> s, NOW);
        for (String name : new String[] {"mhm-p.log", ".mhm-p.state", ".gitignore", "mhm-p.0001.log.gz"}) {
            assertEquals("rw-------", permissions(folder.resolve(name)), name);
        }

        // made again after something deleted it: closed again
        try (var files = Files.list(folder)) {
            for (Path file : files.toList()) {
                Files.delete(file);
            }
        }
        Files.delete(folder);
        log.record(scrolled(numbered(10_001, 10_002), 10_002), s -> s, NOW);
        assertEquals("rwx------", permissions(folder));
        assertEquals("rw-------", permissions(log.file()));
    }

    @Test
    void namesAreKeptToSafeCharacters() {
        assertEquals(project.resolve(SessionLogs.FOLDER).resolve("a_b_c.log"), SessionLogs.file(project, "a/b c"));
    }
}
