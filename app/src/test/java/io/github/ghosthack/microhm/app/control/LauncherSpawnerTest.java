package io.github.ghosthack.microhm.app.control;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import io.github.ghosthack.microhm.app.mcp.McpService;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.session.SessionEvents;
import io.github.ghosthack.microhm.app.session.SessionLabeller;
import io.github.ghosthack.microhm.app.session.SessionLauncher;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The production spawner over a real launcher with a fake host. */
final class LauncherSpawnerTest {

    @TempDir
    Path dir;

    @Test
    void spawnsRegistersAndAnnouncesThenKillsAndAnnounces() throws Exception {
        FakeSessionHost host = new FakeSessionHost();
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        SessionLauncher launcher = SessionLauncher.withoutMcp(registry, host, SessionLabeller.NONE);
        SessionEvents events = new SessionEvents();
        List<String> changed = new ArrayList<>();
        List<String> killed = new ArrayList<>();
        events.addSessionsChangedListener(changed::add);
        events.addSessionKilledListener(killed::add);
        Path project = Files.createDirectories(dir.resolve("api"));

        LauncherSpawner spawner = new LauncherSpawner(launcher, host, events);
        String name = spawner.spawn(new SessionSpawner.SpawnRequest(HarnessType.CODEX, project,
                Optional.of("API"), Map.of("spawned-by", "mhm-boss")));

        assertEquals("mhm-api", name);
        assertEquals(List.of("mhm-api " + project + " 120x32"), host.newSessionCalls);
        SessionEntry entry = registry.find("mhm-api").orElseThrow();
        assertEquals("API", entry.displayName());
        assertEquals(List.of("mhm-api"), changed);

        spawner.kill("mhm-api");
        assertEquals(List.of("mhm-api"), host.killedSessions());
        assertEquals(List.of("mhm-api"), killed);
        assertEquals(2, changed.size());
    }

    @Test
    void killDeletesTheSessionsMcpConfigFile() throws Exception {
        FakeSessionHost host = new FakeSessionHost();
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        Path mcpDir = dir.resolve("mcp");
        SessionLauncher launcher = new SessionLauncher(registry, host,
                session -> new McpService.McpLink("http://127.0.0.1:1/mcp/" + session, "tok"), mcpDir,
                SessionLabeller.NONE, (session, workdir, columns, rows, env) -> {
                    host.newSession(session, workdir, columns, rows);
                    return true;
                });
        LauncherSpawner spawner = new LauncherSpawner(launcher, host, new SessionEvents());
        String name = spawner.spawn(new SessionSpawner.SpawnRequest(HarnessType.CLAUDE_CODE,
                Files.createDirectories(dir.resolve("api")), Optional.empty(), Map.of()));
        assertTrue(Files.exists(mcpDir.resolve(name + ".json")));

        spawner.kill(name);
        assertFalse(Files.exists(mcpDir.resolve(name + ".json")));
    }
}
