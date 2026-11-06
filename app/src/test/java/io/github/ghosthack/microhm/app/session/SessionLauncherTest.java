package io.github.ghosthack.microhm.app.session;

import io.github.ghosthack.microhm.app.harness.ClaudeProjects;
import io.github.ghosthack.microhm.app.harness.HarnessPlugin;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import io.github.ghosthack.microhm.app.host.SessionHostException;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The launch sequence against a fake host: naming, the typed command (with and without
 * MCP injection), labels and the registry row — for both a fresh create and a resume.
 */
final class SessionLauncherTest {

    private static final String URL = "http://127.0.0.1:7392/mcp/";
    private static final String TOKEN = "secret-token";

    @TempDir
    Path dir;

    private FakeSessionHost host;
    private SessionRegistry registry;
    private Path project;
    private String mcpUrl;
    private Path mcpDir;
    private Path claudeProjects;
    private final List<String> labelCalls = new ArrayList<>();
    /** Every env-carrying start, as {@code session env}. */
    private final List<String> envStarts = new ArrayList<>();
    /** What the fake daemon acknowledges: false plays one that predates {@code env}. */
    private boolean envAcknowledged = true;

    @BeforeEach
    void setUp() throws Exception {
        host = new FakeSessionHost();
        registry = SessionRegistry.load(dir.resolve("sessions.json"));
        project = Files.createDirectories(dir.resolve("proj"));
        mcpUrl = URL;
        mcpDir = dir.resolve("mcp");
        claudeProjects = dir.resolve("claude-projects");
        System.setProperty(ClaudeProjects.OVERRIDE_PROPERTY, claudeProjects.toString());
    }

    @AfterEach
    void tearDown() {
        System.clearProperty(ClaudeProjects.OVERRIDE_PROPERTY);
    }

    private SessionLauncher launcher() {
        return new SessionLauncher(registry, host,
                session -> mcpUrl == null ? null : new McpService.McpLink(mcpUrl + session, TOKEN), mcpDir,
                (session, labels) -> labelCalls.add(session + " " + labels),
                (session, workdir, columns, rows, env) -> {
                    envStarts.add(session + " " + env);
                    host.newSession(session, workdir, columns, rows);
                    return envAcknowledged;
                });
    }

    @Test
    void createInjectsTheMcpServerLabelsAndRegistersTheDisplayName() throws Exception {
        String name = launcher().create(project, HarnessType.CLAUDE_CODE, Optional.empty(),
                Optional.of("reviewer"), Map.of("spawnedBy", "mhm-boss"));

        assertEquals("mhm-proj", name);
        assertEquals(List.of("mhm-proj " + project + " 120x32"), host.newSessionCalls);
        assertTrue(envStarts.isEmpty(), "claude reads its token from the config file, not the environment");
        Path config = mcpDir.resolve("mhm-proj.json");
        String id = registry.find("mhm-proj").orElseThrow().harnessSessionId();
        assertTrue(id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), id);
        assertEquals(List.of("mhm-proj: claude --mcp-config " + HarnessPlugin.shellArgument(config.toString())
                        + " --session-id " + id),
                host.sentCommands);
        assertEquals("{\"mcpServers\":{\"micro-harness-manager\":{\"type\":\"http\",\"url\":\"" + URL + "mhm-proj\","
                + "\"headers\":{\"Authorization\":\"Bearer " + TOKEN + "\"}}}}\n", Files.readString(config));
        assertEquals(List.of("mhm-proj {spawnedBy=mhm-boss, harness=claude-code, project=" + project
                + ", display=reviewer}"), labelCalls);
        SessionEntry entry = registry.find("mhm-proj").orElseThrow();
        assertEquals("reviewer", entry.displayName());
        assertEquals(HarnessType.CLAUDE_CODE, entry.harnessType());
    }

    @Test
    void onlyAHarnessThatReadsTheTokenFromTheEnvironmentGetsIt() {
        SessionLauncher launcher = launcher();
        launcher.create(project, HarnessType.CODEX, Optional.empty(), Optional.empty(), Map.of());
        launcher.create(project, HarnessType.SHELL, Optional.empty(), Optional.empty(), Map.of());
        launcher.create(project, HarnessType.OPENCODE, Optional.empty(), Optional.empty(), Map.of());
        assertEquals(List.of("mhm-proj {MHM_MCP_TOKEN=" + TOKEN + "}"), envStarts, "codex only");
        assertEquals(3, host.newSessionCalls.size());
    }

    @Test
    void aDaemonThatDropsTheEnvironmentGetsCodexLaunchedWithoutMcp() {
        envAcknowledged = false;
        SessionLauncher launcher = launcher();
        launcher.create(project, HarnessType.CODEX, Optional.empty(), Optional.empty(), Map.of());
        assertEquals(List.of("mhm-proj {MHM_MCP_TOKEN=" + TOKEN + "}"), envStarts);
        assertEquals(List.of("mhm-proj: codex"), host.sentCommands, "no MCP flags its harness could not use");
        assertTrue(registry.find("mhm-proj").isPresent());

        // a harness that reads a config file is unaffected
        launcher.create(project, HarnessType.CLAUDE_CODE, Optional.empty(), Optional.empty(), Map.of());
        assertTrue(host.sentCommands.getLast().startsWith("mhm-proj-2: claude --mcp-config "),
                host.sentCommands.getLast());

        // and a resume on the same old daemon likewise drops MCP
        SessionEntry dead = registry.find("mhm-proj").orElseThrow();
        host.killSession("mhm-proj");
        launcher.resume(dead, () -> {
        });
        assertEquals("mhm-proj: codex", host.sentCommands.getLast());
    }

    @Test
    void createWithoutARunningMcpServiceTypesThePlainCommand() {
        mcpUrl = null;
        launcher().create(project, HarnessType.CODEX, Optional.empty(), Optional.empty(), Map.of());
        assertEquals(List.of("mhm-proj: codex"), host.sentCommands);
        assertTrue(envStarts.isEmpty(), "no MCP, no token in the environment");
        assertEquals(List.of("mhm-proj " + project + " 120x32"), host.newSessionCalls);
        assertNull(registry.find("mhm-proj").orElseThrow().displayName());
    }

    @Test
    void aBlankDisplayNameIsNoOverride() {
        launcher().create(project, HarnessType.SHELL, Optional.empty(), Optional.of("  "), Map.of());
        assertNull(registry.find("mhm-proj").orElseThrow().displayName());
    }

    @Test
    void shellHarnessTypesNothing() {
        launcher().create(project, HarnessType.SHELL, Optional.empty(), Optional.empty(), Map.of());
        assertTrue(host.sentCommands.isEmpty());
        assertTrue(registry.find("mhm-proj").isPresent());
    }

    @Test
    void namesStayUniqueAcrossTheDaemonAndTheRegistry() {
        host.seedLiveSession("mhm-proj");
        SessionLauncher launcher = launcher();
        assertEquals("mhm-proj-2", launcher.create(project, HarnessType.SHELL, Optional.empty(),
                Optional.empty(), Map.of()));
        assertEquals("mhm-proj-3", launcher.create(project, HarnessType.SHELL, Optional.empty(),
                Optional.empty(), Map.of()));
    }

    @Test
    void aResumeIdWithoutSyntaxWarnsThenLaunchesFresh() {
        AtomicInteger warned = new AtomicInteger();
        // the shell harness is the one without resume syntax; its fresh launch is "nothing"
        launcher().create(project, HarnessType.SHELL, Optional.of("x"),
                Optional.empty(), Map.of(), warned::incrementAndGet);
        assertEquals(1, warned.get());
        assertTrue(host.sentCommands.isEmpty());
        assertEquals(List.of("mhm-proj " + project + " 120x32"), host.newSessionCalls);
    }

    @Test
    void aFailingLabellerNeverFailsTheLaunch() {
        SessionLauncher launcher = SessionLauncher.withoutMcp(registry, host, (session, labels) -> {
            throw new SessionHostException("daemon too old");
        });
        assertEquals("mhm-proj", launcher.create(project, HarnessType.CODEX, Optional.empty(),
                Optional.empty(), Map.of()));
        assertEquals(List.of("mhm-proj: codex"), host.sentCommands);
    }

    @Test
    void aFailedCreatePropagatesAndRegistersNothing() {
        host.onSendKeys = command -> {
            throw new SessionHostException("boom");
        };
        assertThrows(SessionHostException.class, () -> launcher().create(project, HarnessType.CODEX,
                Optional.empty(), Optional.empty(), Map.of()));
        assertTrue(registry.find("mhm-proj").isEmpty());
    }

    @Test
    void resumeInjectsAheadOfTheResumeSubcommandAndKeepsTheRow() {
        SessionEntry dead = new SessionEntry("mhm-proj", project.toString(), HarnessType.CODEX,
                "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b", java.time.Instant.EPOCH, "named");
        registry.put(dead);
        launcher().resume(dead, () -> {
            throw new AssertionError("codex has resume syntax");
        });
        assertEquals(List.of("mhm-proj: codex -c 'mcp_servers.micro-harness-manager.url=\"" + URL
                + "mhm-proj\"' -c 'mcp_servers.micro-harness-manager.bearer_token_env_var=\"MHM_MCP_TOKEN\"'"
                + " resume 0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"), host.sentCommands);
        assertEquals(List.of("mhm-proj {MHM_MCP_TOKEN=" + TOKEN + "}"), envStarts);
        assertFalse(Files.exists(mcpDir), "codex needs no config file");
        assertEquals(List.of("mhm-proj {harness=codex, project=" + project + ", display=named}"), labelCalls);
        assertEquals(dead, registry.find("mhm-proj").orElseThrow());
    }

    @Test
    void theConfigFileIsOwnerOnlyRewrittenOnResumeAndDiscardedOnRequest() throws Exception {
        SessionLauncher launcher = launcher();
        launcher.create(project, HarnessType.CLAUDE_CODE, Optional.empty(), Optional.empty(), Map.of());
        Path config = mcpDir.resolve("mhm-proj.json");
        assertTrue(Files.exists(config));
        if (mcpDir.getFileSystem().supportedFileAttributeViews().contains("posix")) {
            assertEquals("rwx------", PosixFilePermissions.toString(Files.getPosixFilePermissions(mcpDir)));
            assertEquals("rw-------", PosixFilePermissions.toString(Files.getPosixFilePermissions(config)));
        }
        try (var leftovers = Files.list(mcpDir)) {
            assertEquals(List.of(config), leftovers.toList(), "no temp file left behind");
        }

        // a resume after a token change overwrites the file with the current token
        mcpUrl = "http://127.0.0.1:9/mcp/";
        host.killSession("mhm-proj");
        launcher.resume(registry.find("mhm-proj").orElseThrow(), () -> {
        });
        assertTrue(Files.readString(config).contains("http://127.0.0.1:9/mcp/mhm-proj"), Files.readString(config));

        // resumed while the service is off: the stale token's file goes
        mcpUrl = null;
        host.killSession("mhm-proj");
        launcher.resume(registry.find("mhm-proj").orElseThrow(), () -> {
        });
        assertFalse(Files.exists(config));
        assertEquals("mhm-proj: claude --session-id " + registry.find("mhm-proj").orElseThrow().harnessSessionId(),
                host.sentCommands.getLast(), "no MCP flag; still no message, so a fresh start under its id");

        Files.writeString(config, "x");
        launcher.discardMcpConfig("mhm-proj");
        assertFalse(Files.exists(config));
        launcher.discardMcpConfig("mhm-proj"); // already gone: no complaint
    }

    @Test
    void anUnwritableConfigDirLaunchesWithoutMcp() throws Exception {
        Files.writeString(dir.resolve("blocker"), "not a directory");
        mcpDir = dir.resolve("blocker").resolve("mcp");
        launcher().create(project, HarnessType.CLAUDE_CODE, Optional.empty(), Optional.empty(), Map.of());
        assertEquals(List.of("mhm-proj: claude --session-id " + registry.find("mhm-proj").orElseThrow().harnessSessionId()),
                host.sentCommands);
    }

    @Test
    void sessionNamesBecomeFileSafeConfigNames() {
        assertEquals(mcpDir.resolve("a_b_.._c.json"), launcher().mcpConfigFile("a/b/../c"));
    }

    @Test
    void aNameThatKeepsGettingTakenGivesUpAfterBoundedRetries() {
        AtomicInteger probes = new AtomicInteger();
        // every candidate is registered by "someone else" right after it probes free
        host.onHasSession = session -> {
            probes.incrementAndGet();
            registry.put(SessionEntry.newlyCreated(session, project.toString(), HarnessType.SHELL, null));
        };
        assertThrows(IllegalStateException.class, () -> launcher().create(project, HarnessType.SHELL,
                Optional.empty(), Optional.empty(), Map.of()));
        assertTrue(probes.get() <= 2 * SessionLauncher.MAX_NAME_ATTEMPTS, "bounded: " + probes.get());
        assertTrue(host.newSessionCalls.isEmpty());
    }

    @Test
    void aSlowHostProbeNeitherBlocksOtherLaunchesNorLetsThemShareAName() throws Exception {
        CountDownLatch probing = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicInteger probes = new AtomicInteger();
        // the first probe of mhm-proj answers "free" and then stalls, like a slow daemon round trip
        host.onHasSession = session -> {
            if (session.equals("mhm-proj") && probes.getAndIncrement() == 0) {
                probing.countDown();
                try {
                    release.await(10, TimeUnit.SECONDS);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        };
        SessionLauncher launcher = launcher();
        ExecutorService pool = Executors.newFixedThreadPool(2);
        try {
            Future<String> slow = pool.submit(() -> launcher.create(project, HarnessType.SHELL, Optional.empty(),
                    Optional.empty(), Map.of()));
            assertTrue(probing.await(10, TimeUnit.SECONDS));
            // the stalled probe holds no lock: a second launch in the same folder completes
            Future<String> quick = pool.submit(() -> launcher.create(project, HarnessType.SHELL, Optional.empty(),
                    Optional.empty(), Map.of()));
            assertEquals("mhm-proj", quick.get(10, TimeUnit.SECONDS));
            release.countDown();
            // the slow launch's "free" answer went stale meanwhile; it re-derives
            assertEquals("mhm-proj-2", slow.get(10, TimeUnit.SECONDS));
        } finally {
            release.countDown();
            pool.shutdownNow();
        }
    }
    @Test
    void aFreshLocalClaudeIsGivenItsSessionIdSoTheRowKnowsItFromTheStart() {
        mcpUrl = null;
        launcher().create(project, HarnessType.CLAUDE_CODE, Optional.empty(),
                Optional.empty(), Map.of());
        String id = registry.find("mhm-proj").orElseThrow().harnessSessionId();
        assertEquals(List.of("mhm-proj: claude --session-id " + id), host.sentCommands);

        // a harness that can't be told its id launches as before, with no id on the row
        launcher().create(project, HarnessType.CODEX, Optional.empty(),
                Optional.empty(), Map.of());
        assertEquals("mhm-proj-2: codex", host.sentCommands.getLast());
        assertNull(registry.find("mhm-proj-2").orElseThrow().harnessSessionId());
    }

    @Test
    void aResumeWhoseConversationNeverGotAMessageStartsFreshUnderTheSameId() throws Exception {
        mcpUrl = null;
        SessionEntry dead = SessionEntry.newlyCreated("mhm-proj", project.toString(), HarnessType.CLAUDE_CODE,
                "1111-2222");
        registry.put(dead);
        launcher().resume(dead, () -> {
        });
        assertEquals("mhm-proj: claude --session-id 1111-2222", host.sentCommands.getLast(),
                "no transcript yet: --resume would fail with \"No conversation found\"");

        Path claudeDir = Files.createDirectories(claudeProjects.resolve(
                project.toAbsolutePath().normalize().toString().replaceAll("[^A-Za-z0-9]", "-")));
        Files.writeString(claudeDir.resolve("1111-2222.jsonl"), "{}\n");
        host.killSession("mhm-proj");
        launcher().resume(dead, () -> {
        });
        assertEquals("mhm-proj: claude --resume 1111-2222", host.sentCommands.getLast());
    }
}
