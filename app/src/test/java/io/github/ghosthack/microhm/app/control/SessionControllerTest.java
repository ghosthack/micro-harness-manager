package io.github.ghosthack.microhm.app.control;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.mcp.ToolDef;
import io.github.ghosthack.microhm.app.mcp.ToolResult;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.testutil.MutableClock;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CopyOnWriteArrayList;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The controller's tools against a fake daemon, a fake spawner and a mutable clock; the
 * monitor is driven by calling {@code tick()} directly, deliveries run inline.
 */
final class SessionControllerTest {

    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String NOTICE_TAIL = ". Use the read tool to see it.";

    @TempDir
    Path dir;

    /** A path inside a hand-written JSON string: backslashes (Windows) escaped. */
    private static String json(Path path) {
        return path.toString().replace("\\", "\\\\");
    }

    private FakeDaemon daemon;
    private SessionRegistry registry;
    private MutableClock clock;
    private FakeSpawner spawner;
    private final List<Duration> sleeps = new CopyOnWriteArrayList<>();
    private SessionController controller;

    @BeforeEach
    void setUp() {
        daemon = new FakeDaemon();
        registry = SessionRegistry.load(dir.resolve("sessions.json"));
        clock = new MutableClock();
        spawner = new FakeSpawner();
        controller = controller(SessionController.Timings.DEFAULT);
    }

    private SessionController controller(SessionController.Timings timings) {
        return controller(timings, Runnable::run);
    }

    private SessionController controller(SessionController.Timings timings, java.util.concurrent.Executor deliveries) {
        return new SessionController(daemon, registry, spawner, clock,
                (harness, project, id, pid) -> switch (harness) {
                    case CODEX -> Optional.of(Path.of("/codex/rollout-x.jsonl"));
                    case CLAUDE_CODE -> Optional.of(Path.of("/claude" + project, id.orElse("newest") + ".jsonl"));
                    case MUSE -> Optional.of(Path.of("/muse/sessions/2026/11/08/m1/session.jsonl"));
                    default -> Optional.empty();
                },
                sleeps::add, deliveries, timings);
    }

    // ------------------------------------------------------------------ helpers

    private ToolResult call(String caller, String tool, String json) {
        try {
            return controller.call(caller, tool, JSON.readTree(json));
        } catch (Exception e) {
            throw new AssertionError(e);
        }
    }

    private String ok(String caller, String tool, String json) {
        ToolResult result = call(caller, tool, json);
        assertFalse(result.isError(), () -> "expected success, got: " + result.text());
        return result.text();
    }

    private String error(String caller, String tool, String json) {
        ToolResult result = call(caller, tool, json);
        assertTrue(result.isError(), () -> "expected an error, got: " + result.text());
        return result.text();
    }

    private FakeDaemon.FakeSession shell(String name) {
        FakeDaemon.FakeSession s = daemon.add(name);
        s.labels.put("harness", "shell");
        return s;
    }

    /** A claude-code session showing {@code screen}, claude in the foreground. */
    private FakeDaemon.FakeSession agent(String name, String screen) {
        FakeDaemon.FakeSession s = daemon.add(name);
        s.labels.put("harness", "claude-code");
        s.foreground = "claude";
        return s.show(screen);
    }

    /** Claude Code idle at its prompt. */
    private static final String CLAUDE_IDLE = "Done.\n❯ \n? for shortcuts\n";
    /** Claude Code asking for a permission. */
    private static final String CLAUDE_APPROVAL = "Bash: rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n"
            + "  2. No, and tell Claude what to do differently (esc)\n";

    /** Lets {@code seconds} pass, one monitor tick a second. */
    private void ticks(int seconds) {
        for (int i = 0; i < seconds; i++) {
            clock.advance(Duration.ofSeconds(1));
            controller.tick();
        }
    }

    private void register(String name, HarnessType harness, String display) {
        SessionEntry entry = SessionEntry.newlyCreated(name, "/proj/" + name, harness, null);
        registry.put(display != null ? entry.withDisplayName(display) : entry);
    }

    private static String lines(int from, int to) {
        StringBuilder sb = new StringBuilder();
        for (int i = from; i <= to; i++) {
            sb.append("line ").append(i).append('\n');
        }
        return sb.toString();
    }

    private List<FakeDaemon.Input> inputsTo(String session) {
        return daemon.inputs.stream().filter(i -> i.session().equals(session)).toList();
    }

    // ------------------------------------------------------------------ tools/list

    @Test
    void offersTheSevenToolsWithDescribedSchemas() {
        List<String> names = controller.tools().stream().map(ToolDef::name).toList();
        assertEquals(List.of("list", "read", "send", "keys", "notify", "spawn", "kill"), names);
        for (ToolDef def : controller.tools()) {
            assertEquals("object", def.inputSchema().path("type").asText());
            def.inputSchema().path("properties").forEach(p ->
                    assertFalse(p.path("description").asText().isBlank(), def.name()));
        }
        assertTrue(controller.tools().get(0).description().contains("claude-code, codex, muse, grok"));
        assertTrue(controller.tools().get(1).description().contains("earlier output is in the transcript"));
        ToolDef keys = controller.tools().get(3);
        assertTrue(keys.description().contains("C-c"));
        assertTrue(keys.description().contains("PageDown"));
        JsonNode harnesses = controller.tools().get(5).inputSchema().path("properties").path("harness").path("enum");
        assertEquals(HarnessType.values().length, harnesses.size());
    }

    @Test
    void unknownToolIsAnError() {
        assertTrue(error(null, "explode", "{}").contains("unknown tool"));
    }

    // ------------------------------------------------------------------ resolution

    @Test
    void resolvesByNameRegistryDisplayNameAndDisplayLabel() {
        shell("mhm-a").show("alpha");
        daemon.add("mhm-b").show("beta");
        register("mhm-b", HarnessType.SHELL, "Backend");
        FakeDaemon.FakeSession c = shell("mhm-c").show("gamma");
        c.labels.put("display", "Docs");

        assertTrue(ok(null, "read", "{\"session\":\"mhm-a\"}").startsWith("mhm-a · shell"));
        assertTrue(ok(null, "read", "{\"session\":\"backend\"}").startsWith("mhm-b · shell"));
        assertTrue(ok(null, "read", "{\"session\":\"DOCS\"}").startsWith("mhm-c · shell"));
        assertTrue(error(null, "read", "{\"session\":\"nope\"}").contains("no such session: nope"));
    }

    @Test
    void aRegisteredSessionThatIsNotRunningIsReportedAsSuch() {
        registry.put(SessionEntry.newlyCreated("mhm-t", "/p", HarnessType.CODEX, null)
                .withDisplayName("Gone"));
        assertTrue(error(null, "read", "{\"session\":\"mhm-t\"}").contains("mhm-t is not running"));
        assertTrue(error(null, "send", "{\"session\":\"gone\",\"text\":\"hi\"}").contains("mhm-t is not running"));
    }

    @Test
    void ambiguousDisplayNameIsAnError() {
        shell("mhm-a").labels.put("display", "Twin");
        shell("mhm-b").labels.put("display", "twin");
        assertTrue(error(null, "read", "{\"session\":\"Twin\"}").contains("ambiguous"));
    }

    // ------------------------------------------------------------------ list

    @Test
    void listsOneLinePerSessionWithStateProjectTranscriptAndTheCallersMark() {
        daemon.quietProbe = true; // both long idle: primed straight to a quiescent state
        daemon.add("mhm-api").show("› ready").foreground = "codex";
        register("mhm-api", HarnessType.CODEX, "API");
        shell("mhm-sh").show("$ ").workdir = Path.of("/tmp/sh");

        String list = ok("mhm-sh", "list", "{}");
        String[] rows = list.split("\n");
        assertEquals(2, rows.length);
        assertTrue(rows[0].startsWith("mhm-api · API · codex · "), rows[0]);
        assertTrue(rows[0].endsWith(" · /proj/mhm-api · transcript: " + Path.of("/codex/rollout-x.jsonl")
                + " · log: -"), "the caller's folder doesn't exist: " + rows[0]);
        assertEquals("mhm-sh · - · shell · IDLE · " + Path.of("/tmp/sh") + " · transcript: - · log: - (you)", rows[1]);
    }

    @Test
    void aClaudeTranscriptIsNeverGuessedWhenAnotherClaudeSessionSharesTheProject() {
        daemon.quietProbe = true;
        for (String name : List.of("mhm-one", "mhm-two", "mhm-solo")) {
            daemon.add(name).show("> ").foreground = "claude";
        }
        registry.put(SessionEntry.newlyCreated("mhm-one", "/shared", HarnessType.CLAUDE_CODE, "id-1"));
        registry.put(SessionEntry.newlyCreated("mhm-two", "/shared", HarnessType.CLAUDE_CODE, null));
        registry.put(SessionEntry.newlyCreated("mhm-solo", "/alone", HarnessType.CLAUDE_CODE, null));

        String[] rows = ok(null, "list", "{}").split("\n");
        assertTrue(rows[0].endsWith("transcript: " + Path.of("/claude/shared/id-1.jsonl") + " · log: -"),
                "its own file: " + rows[0]);
        assertTrue(rows[1].contains("transcript: " + Path.of("/claude/shared") + java.io.File.separator + " (id unknown"),
                "the folder, not a guess: " + rows[1]);
        assertTrue(rows[2].endsWith("transcript: " + Path.of("/claude/alone/newest.jsonl") + " · log: -"),
                "alone in its project: " + rows[2]);
    }

    @Test
    void listWithoutSessionsSaysSo() {
        assertTrue(ok(null, "list", "{}").startsWith("no sessions"));
    }

    // ------------------------------------------------------------------ read

    @Test
    void readIsWholeThenUnchangedThenIncrementalThenFullOnRequest() {
        FakeDaemon.FakeSession s = shell("mhm-a").show(lines(1, 10) + "$ ▮\n\n\n");
        String first = ok("mhm-me", "read", "{\"session\":\"mhm-a\"}");
        String[] firstLines = first.split("\n");
        assertTrue(firstLines[0].startsWith("mhm-a · shell · WORKING ("), firstLines[0]);
        assertEquals(12, firstLines.length, "header + 11 lines, trailing blanks trimmed");

        String again = ok("mhm-me", "read", "{\"session\":\"mhm-a\"}");
        assertTrue(again.endsWith(" · unchanged"), again);
        assertEquals(1, again.split("\n").length);

        // scrolled by three lines: only the new ones and the prompt come back
        s.show(lines(4, 13) + "$ ▮\n");
        String incremental = ok("mhm-me", "read", "{\"session\":\"mhm-a\"}");
        List<String> rows = incremental.lines().toList();
        assertTrue(rows.get(1).startsWith("… (7 lines above already seen"), rows.get(1));
        assertEquals(List.of("line 11", "line 12", "line 13", "$ ▮"), rows.subList(2, rows.size()));

        String full = ok("mhm-me", "read", "{\"session\":\"mhm-a\",\"full\":true}");
        assertEquals(12, full.split("\n").length);
        assertTrue(full.contains("line 4\n"));

        // seen-tracking is per caller: another reader starts with the whole screen
        assertEquals(12, ok("mhm-other", "read", "{\"session\":\"mhm-a\"}").split("\n").length);
    }

    @Test
    void wholeScreenReadsEndWithWhereTheTranscriptIs() {
        FakeDaemon.FakeSession s = daemon.add("mhm-m");
        s.labels.put("harness", "muse");
        s.show(lines(1, 5));
        String note = "… (earlier output is in the transcript, "
                + Path.of("/muse/sessions/2026/11/08/m1/session.jsonl") + ": grep or tail it)";
        String first = ok("mhm-me", "read", "{\"session\":\"mhm-m\"}");
        assertTrue(first.endsWith("\nline 5\n" + note), first);
        assertTrue(ok("mhm-me", "read", "{\"session\":\"mhm-m\"}").endsWith(" · unchanged"), "no note");
        s.show(lines(3, 8));
        assertFalse(ok("mhm-me", "read", "{\"session\":\"mhm-m\"}").contains("transcript"),
                "an incremental read has no note");
        assertTrue(ok("mhm-me", "read", "{\"session\":\"mhm-m\",\"full\":true}").endsWith(note));

        shell("mhm-sh").show(lines(1, 3));
        assertFalse(ok(null, "read", "{\"session\":\"mhm-sh\"}").contains("transcript"),
                "no transcript, no note");
    }

    // ------------------------------------------------------------------ screen logs

    /** A shell session working in a fresh folder of {@link #dir}: the caller whose logs go there. */
    private Path callerIn(String name) throws Exception {
        Path project = java.nio.file.Files.createDirectories(dir.resolve("project-" + name));
        shell(name).show("$ ").workdir = project;
        return project;
    }

    private static String read(Path file) throws Exception {
        return java.nio.file.Files.readString(file);
    }

    @Test
    void theCallersProjectGetsAPlainLogOfEachSessionsScrollbackEachLineOnce() throws Exception {
        Path project = callerIn("mhm-me");
        FakeDaemon.FakeSession s = daemon.add("mhm-m");
        s.labels.put("harness", "muse");
        s.show(lines(10, 12));
        s.history = List.of("line 1", "line 2");

        Path log = project.resolve(".microhm-sessions").resolve("mhm-m.log");
        String list = ok("mhm-me", "list", "{}");
        assertTrue(list.contains("mhm-m · - · muse · ") && list.contains(" · log: " + log), list);
        assertTrue(list.contains(project + " · transcript: - · log: - (you)"),
                "none of your own session: " + list);
        assertEquals("line 1\nline 2\n", read(log), "the scrollback the session holds, at once");
        assertEquals("*\n", read(project.resolve(".microhm-sessions/.gitignore")), "kept out of git");

        s.history = List.of("line 1", "line 2", "line 3", "line 4");
        controller.tick();
        controller.tick();
        assertEquals("line 1\nline 2\nline 3\nline 4\n", read(log), "kept up on the monitor's tick, each line once");

        s.historyDropped = 10; // 10 more scrolled off; only the last 4 are still held
        s.history = List.of("line 11", "line 12", "line 13", "line 14");
        controller.tick();
        assertTrue(read(log).endsWith("line 4\n--- microhm · " + clock.instant().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)
                + " · 6 lines scrolled past before they could be copied ---\nline 11\nline 12\nline 13\nline 14\n"),
                read(log));

        String full = ok("mhm-me", "read", "{\"session\":\"mhm-m\",\"full\":true}");
        assertTrue(full.endsWith("… (earlier output is in the transcript, " + Path.of("/muse/sessions/2026/11/08/m1/session.jsonl")
                + ", and in the screen log, " + log + ": grep or tail them)"), full);

        // a new session under the same name counts its scrollback afresh
        s.processId = 5151;
        s.historyDropped = 0;
        s.history = List.of("fresh 1");
        controller.tick();
        assertTrue(read(log).endsWith("line 14\n--- microhm · " + clock.instant().truncatedTo(java.time.temporal.ChronoUnit.SECONDS)
                + " · a new session (pid 5151) ---\nfresh 1\n"), read(log));

        // the session ends: its last lines, then no more
        s.history = List.of("fresh 1", "bye");
        s.alive = false;
        controller.tick();
        s.history = List.of("fresh 1", "bye", "never");
        controller.tick();
        assertTrue(read(log).endsWith("fresh 1\nbye\n"), read(log));
    }

    @Test
    void aFullScreenProgramsLogGetsEachNewLineOfItsScreenOnceWithoutItsChrome() throws Exception {
        Path project = callerIn("mhm-me");
        FakeDaemon.FakeSession s = daemon.add("mhm-g");
        s.labels.put("harness", "grok");
        s.alternateScreen = true;
        s.show("Grok\n   ⠙ Responding… 1.0s        1s ⇣1.0k [stop]\n\n");
        Path log = project.resolve(".microhm-sessions").resolve("mhm-g.log");
        ok("mhm-me", "read", "{\"session\":\"mhm-g\"}");
        String stamp = clock.instant().truncatedTo(java.time.temporal.ChronoUnit.SECONDS).toString();
        s.show("Grok\nThe answer\n   ⠴ Responding… 2.0s        2s ⇣1.0k [stop]\n");
        controller.tick();
        s.show("Grok\nThe answer\nis 42.\n\n");
        controller.tick();
        controller.tick();
        assertEquals("--- microhm · " + stamp + " · screen ---\nGrok\nThe answer\nis 42.\n", read(log),
                "each line once, no status row");
    }

    @Test
    void aDaemonWithoutScrollbackReadsKeepsNoLog() throws Exception {
        Path project = callerIn("mhm-me");
        daemon.noHistory = true;
        shell("mhm-sh").show("$ make\nok\n");
        assertTrue(ok("mhm-me", "list", "{}").contains("mhm-sh · - · shell · "), "list still works");
        assertTrue(ok("mhm-me", "list", "{}").lines().filter(l -> l.startsWith("mhm-sh")).findFirst().orElseThrow()
                .endsWith(" · log: -"));
        controller.tick();
        assertFalse(java.nio.file.Files.exists(project.resolve(".microhm-sessions").resolve("mhm-sh.log")));
    }

    @Test
    void logsOfACallerThatEndedStop() throws Exception {
        Path project = callerIn("mhm-me");
        FakeDaemon.FakeSession s = shell("mhm-sh").show("$ ");
        s.history = List.of("one");
        ok("mhm-me", "list", "{}");
        Path log = project.resolve(".microhm-sessions").resolve("mhm-sh.log");
        assertEquals("one\n", read(log));
        daemon.sessions.remove("mhm-me");
        s.history = List.of("one", "two");
        controller.tick();
        assertEquals("one\n", read(log), "its caller is gone: no longer kept");
    }

    @Test
    void chromeOnlyChangesReadAsOnlyStatusLinesChangedWithJustThoseLines() {
        FakeDaemon.FakeSession s = agent("mhm-c", "Answer: 42\n❯ \n? for shortcuts\n");
        ok(null, "read", "{\"session\":\"mhm-c\"}");
        s.show("Answer: 42\n❯ typing▮\n? for shortcuts    auto mode on\n");
        String read = ok(null, "read", "{\"session\":\"mhm-c\"}");
        List<String> rows = read.lines().toList();
        assertTrue(rows.getFirst().endsWith(" · only status lines changed"), read);
        assertEquals(List.of("❯ typing▮", "? for shortcuts    auto mode on"), rows.subList(1, rows.size()));
    }

    @Test
    void sameTextWithMovedMarkersOrSameOutputCountIsUnchanged() {
        FakeDaemon.FakeSession s = shell("mhm-a").show("$ ls\n▶ a\nb\n$ ▮\n");
        ok(null, "read", "{\"session\":\"mhm-a\"}");
        s.show("$ ls\na\n▶ b\n$▮ \n"); // only the highlight and the cursor moved
        assertTrue(ok(null, "read", "{\"session\":\"mhm-a\"}").endsWith(" · unchanged"));
        s.text = "$ ls\na\nb\n$ x▮\n"; // no output counted (a repaint the daemon did not count)
        assertTrue(ok(null, "read", "{\"session\":\"mhm-a\"}").endsWith(" · unchanged"));
    }

    @Test
    void redrawnScreenComesBackWhole() {
        FakeDaemon.FakeSession s = shell("mhm-a").show(lines(1, 10));
        ok(null, "read", "{\"session\":\"mhm-a\"}");
        s.show(lines(50, 59));
        assertEquals(11, ok(null, "read", "{\"session\":\"mhm-a\"}").split("\n").length);
    }

    @Test
    void longScreensAreCappedKeepingTheTail() {
        String wide = "x".repeat(200);
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 60; i++) {
            sb.append(i).append(' ').append(wide).append('\n');
        }
        shell("mhm-a").show(sb.toString());
        String read = ok(null, "read", "{\"session\":\"mhm-a\"}");
        String body = read.substring(read.indexOf('\n') + 1);
        assertTrue(body.length() <= SessionController.MAX_BODY_CHARS, "" + body.length());
        assertTrue(body.startsWith("… ("), body.substring(0, 30));
        assertTrue(body.contains("earlier lines omitted"));
        assertTrue(body.endsWith("59 " + wide));
    }

    // ------------------------------------------------------------------ send / keys

    @Test
    void sendPastesThenPressesEnterAfterTheDelay() {
        shell("mhm-a").show("$ ");
        assertEquals("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"echo hi\\nworld\"}"));
        assertEquals(List.of(new FakeDaemon.Input("mhm-a", "echo hi\nworld", true, null),
                new FakeDaemon.Input("mhm-a", null, false, List.of("Enter"))), inputsTo("mhm-a"));
        assertEquals(List.of(Duration.ofMillis(400)), sleeps);

        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"draft\",\"enter\":false}");
        assertEquals(new FakeDaemon.Input("mhm-a", "draft", true, null), inputsTo("mhm-a").getLast());
    }

    @Test
    void sendAndKillRefuseTheCallersOwnSession() {
        shell("mhm-me").show("$ ");
        assertTrue(error("mhm-me", "send", "{\"session\":\"mhm-me\",\"text\":\"x\"}").contains("your own session"));
        assertTrue(error("mhm-me", "kill", "{\"session\":\"mhm-me\"}").contains("your own session"));
        assertTrue(daemon.inputs.isEmpty());
        assertTrue(spawner.killed.isEmpty());
    }

    @Test
    void keysPressesWaitsForQuietSinceTheInputAndReturnsTheWholeScreen() {
        FakeDaemon.FakeSession s = shell("mhm-a").show("Pick one\n▶ 1. Yes\n  2. No\n");
        long before = s.outputBytes;
        ok("mhm-me", "read", "{\"session\":\"mhm-a\"}");
        String screen = ok("mhm-me", "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Down\",\"Enter\"]}");
        assertEquals(List.of(new FakeDaemon.Input("mhm-a", null, false, List.of("Down", "Enter"))), inputsTo("mhm-a"));
        assertEquals(List.of(new FakeDaemon.Wait("mhm-a", before, 300, 3000)), daemon.waits);
        assertTrue(screen.contains("▶ 1. Yes"), "whole screen even though nothing changed: " + screen);
        // and it counts as seen
        assertTrue(ok("mhm-me", "read", "{\"session\":\"mhm-a\"}").endsWith("unchanged"));
    }

    @Test
    void keysReportsBadKeyNames() {
        shell("mhm-a").show("$ ");
        assertTrue(error(null, "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Bogus\"]}").contains("unknown key: Bogus"));
        assertTrue(error(null, "keys", "{\"session\":\"mhm-a\",\"keys\":[]}").contains("keys is required"));
    }

    // ------------------------------------------------------------------ notify

    @Test
    void notifyNeedsACaller() {
        shell("mhm-a").show("$ ");
        assertTrue(error(null, "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}")
                .contains("only works from a session"));
    }

    @Test
    void finishedOnASessionThatIsNotWorkingRegistersNothing() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("$ ");
        String reply = ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}");
        assertEquals("mhm-a is already IDLE (not working); nothing registered", reply);
        assertFalse(controller.hasPending());
    }

    @Test
    void finishedIsHeldWhileTheCallerWorksThenTypedIntoIt() {
        FakeDaemon.FakeSession me = agent("mhm-me", "thinking 0");
        FakeDaemon.FakeSession target = shell("mhm-a").show("building 0");
        assertEquals("will notify mhm-me when mhm-a finished",
                ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}"));

        // the target goes quiet and turns IDLE while the caller is still busy
        for (int i = 1; i <= 7; i++) {
            clock.advance(Duration.ofSeconds(1));
            me.show("thinking " + i);
            controller.tick();
        }
        assertTrue(inputsTo("mhm-me").isEmpty(), "held while the caller works");
        assertTrue(controller.hasPending());

        // the caller ends its turn: once it is quiet at its prompt the notice is typed in
        me.show(CLAUDE_IDLE);
        for (int i = 0; i < 7; i++) {
            clock.advance(Duration.ofSeconds(1));
            controller.tick();
        }
        assertEquals(List.of(
                new FakeDaemon.Input("mhm-me", "[micro-harness-manager] mhm-a finished (IDLE)" + NOTICE_TAIL, true, null),
                new FakeDaemon.Input("mhm-me", null, false, List.of("Enter"))), inputsTo("mhm-me"));
        assertTrue(inputsTo("mhm-a").isEmpty(), "nothing is ever typed into the target");
        assertFalse(controller.hasPending(), "one-shot");
        assertEquals("building 0", target.text);
    }

    @Test
    void exitedAndAnyChangeFire() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("$ ");
        FakeDaemon.FakeSession b = shell("mhm-b").show("$ ");
        String reply = ok("mhm-me", "notify", "{\"sessions\":[\"mhm-a\"],\"on\":\"exited\"}");
        assertEquals("will notify mhm-me when mhm-a exited", reply);
        ok("mhm-me", "notify", "{\"session\":\"mhm-b\",\"on\":\"any-change\"}");

        controller.tick();
        assertTrue(inputsTo("mhm-me").isEmpty());

        daemon.kill("mhm-a");
        b.show("$ make\nok");
        controller.tick();
        assertEquals("[micro-harness-manager] mhm-a exited (EXITED)" + NOTICE_TAIL + "\n"
                        + "[micro-harness-manager] mhm-b changed (WORKING)" + NOTICE_TAIL,
                inputsTo("mhm-me").getFirst().text(), "fired notices for one caller go in one paste");
        assertFalse(controller.hasPending());
    }

    @Test
    void undeliverableNotificationsAreDroppedAfterThirtyMinutes() {
        FakeDaemon.FakeSession me = agent("mhm-me", "busy 0");
        shell("mhm-a").show("$ ");
        daemon.quietProbe = false;
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        daemon.kill("mhm-a");
        for (int i = 1; i <= 32; i++) {
            clock.advance(Duration.ofMinutes(1));
            me.show("busy " + i);
            controller.tick();
        }
        assertTrue(inputsTo("mhm-me").isEmpty());
        assertFalse(controller.hasPending());
    }

    @Test
    void notificationsForAGoneCallerAreDropped() {
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"finished\"}");
        daemon.kill("mhm-me");
        controller.tick();
        assertFalse(controller.hasPending());
    }

    // ------------------------------------------------------------------ spawn / kill

    @Test
    void spawnLaunchesThroughTheSpawnerAndTypesThePromptOnceReady() {
        shell("mhm-me").show("$ ");
        String reply = ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\","
                + "\"name\":\"Helper\",\"prompt\":\"ls -la\"}");
        assertEquals("mhm-new-1 started (shell in " + dir + "); the prompt will be typed in once it is ready at its prompt",
                reply);
        SessionSpawner.SpawnRequest request = spawner.requests.getFirst();
        assertEquals(HarnessType.SHELL, request.harness());
        assertEquals(dir, request.project());
        assertEquals(Optional.of("Helper"), request.displayName());
        assertEquals("mhm-me", request.labels().get(SessionController.LABEL_SPAWNED_BY));

        controller.tick(); // first look: output still changing
        assertTrue(inputsTo("mhm-new-1").isEmpty());
        clock.advance(Duration.ofSeconds(6));
        controller.tick();
        assertEquals(List.of(new FakeDaemon.Input("mhm-new-1", "ls -la", true, null),
                new FakeDaemon.Input("mhm-new-1", null, false, List.of("Enter"))), inputsTo("mhm-new-1"));
        assertFalse(controller.hasPending());
    }

    @Test
    void aSpawnThatNeverGetsReadyTellsTheRequesterInsteadOfTyping() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        spawner.harnessLabel = "claude-code"; // its shell stays in front: claude never started
        ok("mhm-me", "spawn", "{\"harness\":\"claude-code\",\"project\":\"~\",\"prompt\":\"hi\"}");
        for (int i = 0; i < 13; i++) {
            clock.advance(Duration.ofSeconds(10));
            controller.tick();
        }
        assertTrue(inputsTo("mhm-new-1").isEmpty());
        assertTrue(inputsTo("mhm-me").getFirst().text()
                .startsWith("[micro-harness-manager] mhm-new-1 did not reach its prompt within 120 s"));
    }

    @Test
    void spawnValidatesHarnessAndProject() {
        assertTrue(error(null, "spawn", "{\"harness\":\"emacs\",\"project\":\"/\"}").contains("unknown harness"));
        assertTrue(error(null, "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir.resolve("missing")) + "\"}")
                .contains("not an existing directory"));
        assertTrue(error(null, "spawn", "{\"harness\":\"shell\",\"project\":\"rel/path\"}").contains("absolute"));
        assertTrue(spawner.requests.isEmpty());
    }

    @Test
    void killEndsAnotherSession() {
        shell("mhm-a").show("$ ");
        assertEquals("killed mhm-a", ok("mhm-me", "kill", "{\"session\":\"mhm-a\"}"));
        assertEquals(List.of("mhm-a"), spawner.killed);
    }

    // ------------------------------------------------------------------ old daemon

    @Test
    void anOldDaemonIsReadAsPlainTextAndAnUnknownCounterNeverMeansUnchanged() {
        daemon.old = true;
        FakeDaemon.FakeSession s = shell("mhm-a").show("line 1\n▶ choice\n$ ▮\n");
        String first = ok(null, "read", "{\"session\":\"mhm-a\"}");
        assertTrue(first.lines().findFirst().orElseThrow().endsWith(" " + SessionController.OLD_DAEMON_NOTE), first);
        assertFalse(first.contains("▮"), first);
        assertFalse(first.contains("▶"), first);
        int refused = daemon.unsupportedCalls.get(); // annotated capture and the quiet probe, once each
        assertEquals(2, refused);

        s.show("line 1\nchoice\n$ ls▮\n"); // the old daemon reports outputBytes -1 both times
        String second = ok(null, "read", "{\"session\":\"mhm-a\"}");
        assertFalse(second.endsWith("unchanged"), second);
        assertTrue(second.endsWith("$ ls"), second);
        assertTrue(ok(null, "read", "{\"session\":\"mhm-a\"}").endsWith(" · unchanged"), "same text");
        assertEquals(refused, daemon.unsupportedCalls.get(), "remembered: never asked again");
    }

    @Test
    void sendOnAnOldDaemonFallsBackToSendKeysAndRefusesMultiLineText() {
        daemon.old = true;
        shell("mhm-a").show("$ ");
        assertEquals("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"echo hi\"}"));
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"draft\",\"enter\":false}");
        assertEquals(List.of(new FakeDaemon.SendKeys("mhm-a", "echo hi", true), new FakeDaemon.SendKeys("mhm-a", "draft", false)),
                daemon.sentKeys);
        assertTrue(sleeps.isEmpty(), "the server pauses before Enter itself");

        String refused = error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\\ntwo\"}");
        assertTrue(refused.contains("predates pasting") && refused.contains("one line at a time"), refused);
        assertTrue(refused.contains("(pid 100)"), refused);
        assertEquals(2, daemon.sentKeys.size(), "nothing typed");
        assertTrue(daemon.inputs.isEmpty());
    }

    @Test
    void keysOnAnOldDaemonExplainsWhyAndWhenItGoesAway() {
        daemon.old = true;
        daemon.pid = 91806;
        shell("mhm-a").show("$ ");
        String expected = "keys needs a newer daemon; the running one (pid 91806) predates it. It is replaced "
                + "automatically once every session has ended and a new one starts.";
        assertEquals(expected, error(null, "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Enter\"]}"));
        assertEquals(expected, error(null, "keys", "{\"session\":\"mhm-a\",\"keys\":[\"Enter\"]}"));
        assertTrue(daemon.sentKeys.isEmpty());
    }

    @Test
    void aNewDaemonIsUsedFullyOnceThePidChanges() {
        daemon.old = true;
        shell("mhm-a").show("$ ");
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"x\"}");
        assertEquals(1, daemon.sentKeys.size());

        daemon.old = false;
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"x\"}");
        assertEquals(2, daemon.sentKeys.size(), "same pid: still taken for the old daemon");

        daemon.pid = 200;
        ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"x\"}");
        assertEquals(2, daemon.sentKeys.size());
        assertEquals(List.of(new FakeDaemon.Input("mhm-a", "x", true, null),
                new FakeDaemon.Input("mhm-a", null, false, List.of("Enter"))), inputsTo("mhm-a"));
        assertFalse(ok(null, "read", "{\"session\":\"mhm-a\"}").contains(SessionController.OLD_DAEMON_NOTE));
    }

    @Test
    void anOldDaemonGetsSpawnPromptsAndNotificationsThroughSendKeys() {
        daemon.old = true; // no labels either: the registry names the caller's harness
        agent("mhm-me", CLAUDE_IDLE);
        register("mhm-me", HarnessType.CLAUDE_CODE, null);
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"make\"}");
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"one\\ntwo\"}");
        ticks(14); // no quiet probe on an old daemon: the caller needs its own 5 s look
        assertEquals(List.of(new FakeDaemon.SendKeys("mhm-new-1", "make", true)),
                daemon.sentKeys.stream().filter(k -> k.session().equals("mhm-new-1")).toList());
        assertTrue(daemon.sentKeys.stream().noneMatch(k -> k.session().equals("mhm-new-2")));
        List<FakeDaemon.SendKeys> toMe = daemon.sentKeys.stream().filter(k -> k.session().equals("mhm-me")).toList();
        assertEquals(1, toMe.size(), "the multi-line prompt is refused and its requester told: " + toMe);
        assertTrue(toMe.getFirst().text().startsWith("[micro-harness-manager] mhm-new-2 could not be given its prompt: "
                + "the running daemon"), toMe.getFirst().text());
        assertTrue(toMe.getFirst().enter());
        assertFalse(controller.hasPending());
        assertTrue(daemon.inputs.isEmpty());
    }

    @Test
    void theMonitorStopsAskingAnOldDaemonForAWatchAndResumesWithANewOne() throws Exception {
        daemon.old = true;
        controller = controller(new SessionController.Timings(Duration.ofMillis(10), Duration.ZERO,
                Duration.ofSeconds(5), Duration.ofSeconds(20), Duration.ofMinutes(30), Duration.ofSeconds(120),
                300, 3000, 500, Duration.ofMillis(5), Duration.ofMillis(20)));
        McpService service = new McpService(controller, "test");
        service.start(0, "token");
        try {
            awaitTrue(() -> daemon.pings.get() >= 5); // ticking along, checking the daemon
            assertEquals(1, daemon.watchAttempts.get(), "asked once per daemon");
            assertTrue(daemon.watches.isEmpty());

            daemon.old = false;
            daemon.pid = 200;
            awaitTrue(() -> !daemon.watches.isEmpty());
        } finally {
            service.stop();
        }
    }

    // ------------------------------------------------------------------ delivery safety

    @Test
    void notifyRefusesAPlainShellCaller() {
        shell("mhm-me").show("$ ");
        shell("mhm-a").show("building");
        String refused = error("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        assertTrue(refused.contains("plain shell session") && refused.contains("run as a command"), refused);
        assertFalse(controller.hasPending());
    }

    @Test
    void aNotificationIsHeldWhileTheCallerWaitsForAnAnswerOrSitsAtAShell() {
        FakeDaemon.FakeSession me = agent("mhm-me", CLAUDE_APPROVAL);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        daemon.kill("mhm-a");
        ticks(10);
        assertTrue(inputsTo("mhm-me").isEmpty(), "never typed (and Enter pressed) into a permission dialog");

        me.foreground = "zsh"; // claude exited: a shell prompt would run the line
        me.show("$ ");
        ticks(10);
        assertTrue(inputsTo("mhm-me").isEmpty(), "never typed into a bare shell");

        me.foreground = "claude";
        me.show(CLAUDE_IDLE);
        ticks(7);
        assertEquals("[micro-harness-manager] mhm-a exited (EXITED)" + NOTICE_TAIL, inputsTo("mhm-me").getFirst().text());
    }

    @Test
    void finishedAfterASpawnPromptWaitsUntilThePromptWasTypedAndWorkedOn() {
        agent("mhm-me", CLAUDE_IDLE);
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"make\"}");
        assertEquals("will notify mhm-me when mhm-new-1 finished",
                ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}"),
                "a session about to be given its prompt counts as working");
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"needs-input\"}");

        ticks(7); // the shell settles at its prompt: the prompt goes in
        assertEquals(2, inputsTo("mhm-new-1").size());
        ticks(10); // typed, but nothing started yet
        assertTrue(inputsTo("mhm-me").isEmpty(), "not finished before it even started");

        daemon.session("mhm-new-1").show("$ make\nbuilding…").foreground = "make";
        ticks(1);
        assertTrue(inputsTo("mhm-me").isEmpty());
        daemon.session("mhm-new-1").show("$ make\nbuilt\n$ ").foreground = "zsh";
        ticks(14); // the caller is first looked at once there is something to deliver
        assertEquals("[micro-harness-manager] mhm-new-1 finished (IDLE)" + NOTICE_TAIL, inputsTo("mhm-me").getFirst().text());
        assertTrue(controller.hasPending(), "needs-input is still armed");
    }

    @Test
    void aTransientCaptureErrorIsNotTakenForAnExit() {
        daemon.quietProbe = true; // the caller is long idle
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"ls\"}");
        daemon.captureFailures.put("mhm-a", 3);
        daemon.captureFailures.put("mhm-new-1", 3);
        ticks(3);
        assertTrue(inputsTo("mhm-me").isEmpty(), "no spurious 'exited', no 'exited before its prompt'");
        ticks(7);
        assertEquals(2, inputsTo("mhm-new-1").size(), "the prompt still goes in");
        assertTrue(inputsTo("mhm-me").isEmpty());

        daemon.kill("mhm-a");
        daemon.captureFailures.put("mhm-me", 2);
        ticks(2);
        assertTrue(inputsTo("mhm-me").isEmpty(), "held, not dropped, while the caller cannot be captured");
        ticks(1);
        assertEquals("[micro-harness-manager] mhm-a exited (EXITED)" + NOTICE_TAIL, inputsTo("mhm-me").getFirst().text());
    }

    @Test
    void notifyRegistersNothingWhenAnySessionIsBadAndRepeatingIsIdempotent() {
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        assertTrue(error("mhm-me", "notify", "{\"sessions\":[\"mhm-a\",\"mhm-typo\"],\"on\":\"exited\"}")
                .contains("no such session: mhm-typo"));
        assertTrue(error("mhm-me", "notify", "{\"sessions\":[\"mhm-a\",\"mhm-me\"],\"on\":\"exited\"}")
                .contains("not your own"));
        assertFalse(controller.hasPending(), "nothing registered by the failed calls");

        assertEquals("will notify mhm-me when mhm-a exited",
                ok("mhm-me", "notify", "{\"sessions\":[\"mhm-a\",\"mhm-a\"],\"on\":\"exited\"}"));
        assertEquals("already registered: will notify mhm-me when mhm-a exited",
                ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}"));
        daemon.kill("mhm-a");
        ticks(7);
        assertEquals("[micro-harness-manager] mhm-a exited (EXITED)" + NOTICE_TAIL, inputsTo("mhm-me").getFirst().text(),
                "one notice, not two");
    }

    @Test
    void aFailedEnterIsRetriedAloneWithoutPastingAgain() {
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        daemon.kill("mhm-a");
        java.util.concurrent.atomic.AtomicInteger enterFailures = new java.util.concurrent.atomic.AtomicInteger(1);
        daemon.failInput = i -> i.keys() != null && enterFailures.getAndDecrement() > 0;
        ticks(7);
        assertEquals(List.of(new FakeDaemon.Input("mhm-me", "[micro-harness-manager] mhm-a exited (EXITED)" + NOTICE_TAIL, true,
                        null), new FakeDaemon.Input("mhm-me", null, false, List.of("Enter"))), inputsTo("mhm-me"),
                "pasted once, Enter retried");
        assertFalse(controller.hasPending());
    }

    @Test
    void aSpawnPromptsFailedEnterIsRetriedAlone() {
        agent("mhm-me", CLAUDE_IDLE);
        java.util.concurrent.atomic.AtomicInteger enterFailures = new java.util.concurrent.atomic.AtomicInteger(1);
        daemon.failInput = i -> i.keys() != null && enterFailures.getAndDecrement() > 0;
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"ls\"}");
        ticks(15);
        assertEquals(List.of(new FakeDaemon.Input("mhm-new-1", "ls", true, null),
                new FakeDaemon.Input("mhm-new-1", null, false, List.of("Enter"))), inputsTo("mhm-new-1"));
        assertFalse(controller.hasPending());
    }

    @Test
    void aDeliveryInFlightIsNotStartedTwice() {
        List<Runnable> queued = new CopyOnWriteArrayList<>();
        controller = controller(SessionController.Timings.DEFAULT, queued::add);
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"ls\"}");
        daemon.kill("mhm-a");
        ticks(10);
        assertEquals(2, queued.size(), "one notification delivery and one prompt delivery: " + queued.size());
        queued.forEach(Runnable::run);
        assertEquals(2, inputsTo("mhm-me").size());
        assertEquals(2, inputsTo("mhm-new-1").size());
        assertFalse(controller.hasPending());
    }

    @Test
    void spawnRefusesADisplayNameAlreadyInUse() {
        shell("mhm-a").labels.put("display", "Helper");
        daemon.add("mhm-b").show("x");
        register("mhm-b", HarnessType.SHELL, "Backend");
        assertEquals("name already in use by mhm-a; choose another",
                error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"helper\"}"));
        assertEquals("name already in use by mhm-b; choose another",
                error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"Backend\"}"));
        assertTrue(spawner.requests.isEmpty());
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"Fresh\"}");
    }

    @Test
    void aNamedSpawnStartsTheFirstSessionWhenNoDaemonIsRunningYet() {
        daemon.down = true;
        daemon.pid = -1;
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"First\"}");
        assertEquals(1, spawner.requests.size(), "the spawner is what starts the daemon");
    }

    @Test
    void anyChangeIgnoresTheComposerButReadShowsIt() {
        agent("mhm-me", CLAUDE_IDLE);
        FakeDaemon.FakeSession c = agent("mhm-c", "Answer: 42\n❯ \n? for shortcuts\n");
        ok("mhm-me", "notify", "{\"session\":\"mhm-c\",\"on\":\"any-change\"}");
        c.show("Answer: 42\n❯ half-typed\n? for shortcuts\n");
        ticks(7);
        assertTrue(inputsTo("mhm-me").isEmpty(), "composer-only changes do not fire any-change");
        assertTrue(controller.hasPending());
    }

    // ------------------------------------------------------------------ unreachable daemon

    @Test
    void anUnreachableDaemonIsNeitherAnExitNorAMissedPrompt() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"ls\"}");

        daemon.down = true; // list comes back empty, ping fails
        for (int i = 0; i < 5; i++) {
            clock.advance(Duration.ofMinutes(1)); // past the prompt deadline even
            controller.tick();
        }
        daemon.down = false;
        assertTrue(inputsTo("mhm-me").isEmpty(), "no 'exited', no 'did not reach its prompt'");
        assertTrue(controller.hasPending());
        assertEquals(SessionController.DAEMON_UNREACHABLE.substring(0, 20),
                errorWhileDown("read", "{\"session\":\"mhm-a\"}").substring(0, 20));

        // the daemon dies between the list and the captures: still unknown, not gone
        daemon.afterList = () -> daemon.down = true;
        controller.tick();
        daemon.afterList = () -> { };
        daemon.down = false;
        assertTrue(inputsTo("mhm-me").isEmpty());

        // once it answers again, a real exit still fires
        daemon.kill("mhm-a");
        ticks(7);
        assertTrue(inputsTo("mhm-me").getFirst().text().startsWith("[micro-harness-manager] mhm-a exited (EXITED)"),
                inputsTo("mhm-me").toString());
    }

    private String errorWhileDown(String tool, String json) {
        daemon.down = true;
        try {
            return error("mhm-me", tool, json);
        } finally {
            daemon.down = false;
        }
    }

    // ------------------------------------------------------------------ spawn prompt and notify

    /** Spawns a claude-code session with {@code prompt} and has it reach its idle prompt. */
    private FakeDaemon.FakeSession spawnClaudeWithPrompt(String prompt) {
        spawner.harnessLabel = "claude-code";
        ok("mhm-me", "spawn", "{\"harness\":\"claude-code\",\"project\":\"" + json(dir) + "\",\"prompt\":"
                + JSON.valueToTree(prompt) + "}");
        FakeDaemon.FakeSession s = daemon.session("mhm-new-1");
        s.foreground = "claude";
        s.show(CLAUDE_IDLE);
        return s;
    }

    @Test
    void finishedAndNeedsInputAfterASpawnPromptFireWhenTheSessionAsksAQuestion() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        FakeDaemon.FakeSession s = spawnClaudeWithPrompt("do it");
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}");
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"needs-input\"}");
        ticks(7);
        assertEquals(2, inputsTo("mhm-new-1").size(), "the prompt went in");

        daemon.quietProbe = false;
        s.show(CLAUDE_APPROVAL);
        ticks(30);
        String delivered = inputsTo("mhm-me").getFirst().text();
        assertTrue(delivered.contains("mhm-new-1 finished (WAITING_FOR_INPUT)"), delivered);
        assertTrue(delivered.contains("mhm-new-1 needs input (WAITING_FOR_INPUT)"), delivered);
        assertFalse(controller.hasPending());
    }

    @Test
    void finishedAfterASpawnPromptFiresWhenTheHarnessFallsBackToAShell() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        FakeDaemon.FakeSession s = spawnClaudeWithPrompt("do it");
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}");
        ticks(7);
        assertEquals(2, inputsTo("mhm-new-1").size());

        s.foreground = "zsh"; // claude quit straight away
        s.text = "$ ";
        ticks(10);
        assertTrue(inputsTo("mhm-me").getFirst().text().startsWith("[micro-harness-manager] mhm-new-1 finished ("),
                inputsTo("mhm-me").toString());
        assertFalse(controller.hasPending());
    }

    @Test
    void aRegistrationWaitingForASpawnPromptIsDroppedAfterThirtyMinutes() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        spawnClaudeWithPrompt("do it");
        ok("mhm-me", "notify", "{\"session\":\"mhm-new-1\",\"on\":\"finished\"}");
        ticks(7);
        assertEquals(2, inputsTo("mhm-new-1").size());
        // it never reacts: idle at its prompt, screen unchanged
        for (int i = 0; i < 29; i++) {
            clock.advance(Duration.ofMinutes(1));
            controller.tick();
        }
        assertTrue(controller.hasPending(), "still armed before the TTL");
        clock.advance(Duration.ofMinutes(2));
        controller.tick();
        assertFalse(controller.hasPending());
        assertTrue(inputsTo("mhm-me").isEmpty());
    }

    @Test
    void spawnStripsTheDisplayNameAndChecksItStripped() {
        shell("mhm-a").labels.put("display", "Helper");
        assertEquals("name already in use by mhm-a; choose another",
                error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"  helper \"}"));
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"  Fresh  \"}");
        assertEquals(Optional.of("Fresh"), spawner.requests.getFirst().displayName());
    }

    @Test
    void concurrentSpawnsCannotTakeTheSameDisplayName() throws Exception {
        java.util.concurrent.CountDownLatch inSpawn = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
        spawner.onSpawn = () -> {
            inSpawn.countDown();
            try {
                release.await(10, java.util.concurrent.TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        };
        java.util.concurrent.ExecutorService pool = java.util.concurrent.Executors.newSingleThreadExecutor();
        try {
            java.util.concurrent.Future<ToolResult> first = pool.submit(() -> call("mhm-me", "spawn",
                    "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"Twin\"}"));
            assertTrue(inSpawn.await(10, java.util.concurrent.TimeUnit.SECONDS));
            spawner.onSpawn = () -> { };
            String refused = error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir)
                    + "\",\"name\":\" twin\"}");
            assertTrue(refused.contains("already in use"), refused);
            ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"Other\"}");
            release.countDown();
            assertFalse(first.get(10, java.util.concurrent.TimeUnit.SECONDS).isError());
            assertEquals(2, spawner.requests.size());
            // released once created: the name is now taken by the live session's label
            daemon.session("mhm-new-1").labels.put("display", "Twin");
            daemon.session("mhm-new-2").labels.put("display", "Other");
            String taken = error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir)
                    + "\",\"name\":\"twin\"}");
            assertTrue(taken.startsWith("name already in use by mhm-"), taken);
        } finally {
            release.countDown();
            pool.shutdownNow();
        }
    }

    @Test
    void aFailedSpawnReleasesItsDisplayName() {
        spawner.onSpawn = () -> {
            throw new IllegalStateException("boom");
        };
        assertTrue(error("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"X\"}")
                .contains("boom"));
        spawner.onSpawn = () -> { };
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"name\":\"X\"}");
    }

    // ------------------------------------------------------------------ an owed Enter

    @Test
    void aPastedSpawnPromptsEnterIsRetriedPastTheDeadlineAndWhateverTheSessionLooksLike() {
        agent("mhm-me", CLAUDE_IDLE);
        java.util.concurrent.atomic.AtomicInteger enterFailures = new java.util.concurrent.atomic.AtomicInteger(3);
        daemon.failInput = i -> i.session().equals("mhm-new-1") && i.keys() != null
                && enterFailures.getAndDecrement() > 0;
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"ls\"}");
        ticks(7);
        assertEquals(List.of(new FakeDaemon.Input("mhm-new-1", "ls", true, null)), inputsTo("mhm-new-1"));
        // now busy (not ready), and the 120 s deadline passes: the Enter is still owed
        daemon.session("mhm-new-1").show("busy").foreground = "make";
        clock.advance(Duration.ofSeconds(200));
        controller.tick();
        controller.tick();
        controller.tick();
        assertEquals(List.of(new FakeDaemon.Input("mhm-new-1", "ls", true, null),
                new FakeDaemon.Input("mhm-new-1", null, false, List.of("Enter"))), inputsTo("mhm-new-1"));
        assertFalse(controller.hasPending(), "no 'not sent' notice either");
    }

    @Test
    void anEnterThatKeepsFailingIsReportedAsPastedButNotSubmitted() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        daemon.failInput = i -> i.session().equals("mhm-new-1") && i.keys() != null;
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"ls\"}");
        ticks(7 + SessionController.MAX_ENTER_ATTEMPTS + 7);
        assertEquals(List.of(new FakeDaemon.Input("mhm-new-1", "ls", true, null)), inputsTo("mhm-new-1"));
        String notice = inputsTo("mhm-me").getFirst().text();
        assertTrue(notice.startsWith("[micro-harness-manager] mhm-new-1 had its prompt pasted but not submitted"), notice);
    }

    @Test
    void aPastedNotificationsEnterGoesInEvenOnceTheCallerIsBusyAndPastTheTtl() {
        FakeDaemon.FakeSession me = agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        daemon.kill("mhm-a");
        java.util.concurrent.atomic.AtomicBoolean enterFails = new java.util.concurrent.atomic.AtomicBoolean(true);
        daemon.failInput = i -> i.keys() != null && enterFails.get();
        ticks(7);
        assertEquals(1, inputsTo("mhm-me").size(), "pasted, Enter failed");

        me.show(CLAUDE_APPROVAL); // the caller is now asking something
        clock.advance(Duration.ofMinutes(40));
        enterFails.set(false);
        controller.tick();
        assertEquals(new FakeDaemon.Input("mhm-me", null, false, List.of("Enter")), inputsTo("mhm-me").getLast());
        assertFalse(controller.hasPending());
    }

    @Test
    void aNotificationWhoseEnterKeepsFailingIsDroppedEventually() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        shell("mhm-a").show("building");
        ok("mhm-me", "notify", "{\"session\":\"mhm-a\",\"on\":\"exited\"}");
        daemon.kill("mhm-a");
        daemon.failInput = i -> i.keys() != null;
        ticks(SessionController.MAX_ENTER_ATTEMPTS + 2);
        assertFalse(controller.hasPending());
        assertEquals(1, inputsTo("mhm-me").size(), "pasted once, never pasted again");
    }

    // ------------------------------------------------------------------ multi-line pastes

    @Test
    void multiLineSendNeedsBracketedPasteAndSaysSoWhenTheSessionLacksIt() {
        FakeDaemon.FakeSession s = shell("mhm-a").show("$ ");
        s.bracketedPaste = false;
        assertEquals(SessionController.MULTI_LINE_REFUSED,
                error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\\ntwo\"}"));
        assertTrue(inputsTo("mhm-a").isEmpty(), "nothing written, Enter not pressed");
        assertEquals(1, daemon.bracketedRequired.size());

        assertEquals("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\"}"));
        assertEquals(1, daemon.bracketedRequired.size(), "a single line needs no bracketed paste");
        assertEquals(2, inputsTo("mhm-a").size());

        s.bracketedPaste = true;
        assertEquals("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"one\\ntwo\"}"));
        assertEquals(new FakeDaemon.Input("mhm-a", "one\ntwo", true, null), inputsTo("mhm-a").get(2));
    }

    @Test
    void controlCharactersOnOneLineAlsoNeedBracketedPaste() {
        FakeDaemon.FakeSession s = shell("mhm-a").show("$ ");
        s.bracketedPaste = false;
        assertEquals(SessionController.MULTI_LINE_REFUSED,
                error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"see \\u001b[31merror\"}"));
        assertEquals(SessionController.MULTI_LINE_REFUSED,
                error("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"stop\\u0003\"}"));
        assertTrue(inputsTo("mhm-a").isEmpty(), "nothing written");
        assertEquals("sent to mhm-a", ok("mhm-me", "send", "{\"session\":\"mhm-a\",\"text\":\"a\\tb\"}"));
        assertEquals(2, daemon.bracketedRequired.size(), "a tab is text, not a key");
    }

    @Test
    void aMultiLineSpawnPromptTheHarnessCannotTakeIsNotTypedAndTheRequesterIsTold() {
        daemon.quietProbe = true;
        agent("mhm-me", CLAUDE_IDLE);
        spawner.onSpawn = () -> { };
        ok("mhm-me", "spawn", "{\"harness\":\"shell\",\"project\":\"" + json(dir) + "\",\"prompt\":\"one\\ntwo\"}");
        daemon.session("mhm-new-1").bracketedPaste = false;
        ticks(14);
        assertTrue(inputsTo("mhm-new-1").isEmpty());
        String notice = inputsTo("mhm-me").getFirst().text();
        assertTrue(notice.startsWith("[micro-harness-manager] mhm-new-1 could not be given its prompt: "
                + SessionController.MULTI_LINE_REFUSED), notice);
        assertFalse(controller.hasPending());
    }

    // ------------------------------------------------------------------ monitor

    @Test
    void monitorReconnectsTheWatchWithBackoffAndStopsWithTheMcpService() throws Exception {
        daemon.watchFailures = 2;
        controller = controller(new SessionController.Timings(Duration.ofMillis(10), Duration.ZERO,
                Duration.ofSeconds(5), Duration.ofSeconds(20), Duration.ofMinutes(30), Duration.ofSeconds(120),
                300, 3000, 500, Duration.ofMillis(5), Duration.ofMillis(20)));
        McpService service = new McpService(controller, "test");
        service.start(0, "token");
        try {
            assertTrue(controller.monitorRunning());
            awaitTrue(() -> !daemon.watches.isEmpty());
            assertEquals(3, daemon.watchAttempts.get());

            // the daemon restarts: the stream ends and is opened again
            daemon.watches.getFirst().close();
            awaitTrue(() -> daemon.watches.size() == 2);
        } finally {
            service.stop();
        }
        assertFalse(controller.monitorRunning());
        assertFalse(daemon.watches.getLast().isOpen(), "stopping closes the stream");
    }

    private static void awaitTrue(java.util.function.BooleanSupplier condition) throws InterruptedException {
        long deadline = System.nanoTime() + Duration.ofSeconds(5).toNanos();
        while (!condition.getAsBoolean()) {
            if (System.nanoTime() > deadline) {
                throw new AssertionError("condition not met in time");
            }
            Thread.sleep(5);
        }
    }

    // ------------------------------------------------------------------ fakes

    private final class FakeSpawner implements SessionSpawner {
        final List<SpawnRequest> requests = new CopyOnWriteArrayList<>();
        final List<String> killed = new CopyOnWriteArrayList<>();
        String harnessLabel;
        /** Runs at the start of every spawn, e.g. to hold one in flight. */
        volatile Runnable onSpawn = () -> { };

        @Override
        public String spawn(SpawnRequest request) {
            onSpawn.run();
            requests.add(request);
            String name = "mhm-new-" + requests.size();
            FakeDaemon.FakeSession s = daemon.add(name);
            s.labels.put("harness", harnessLabel != null ? harnessLabel : request.harness().id());
            s.show("$ ");
            return name;
        }

        @Override
        public void kill(String session) {
            killed.add(session);
            daemon.kill(session);
        }
    }
}
