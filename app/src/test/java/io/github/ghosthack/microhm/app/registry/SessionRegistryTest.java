package io.github.ghosthack.microhm.app.registry;

import io.github.ghosthack.microhm.app.harness.HarnessType;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.time.Instant;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assumptions.assumeFalse;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

final class SessionRegistryTest {

    @Test
    void missingFileLoadsEmpty(@TempDir Path dir) {
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        assertTrue(registry.sessions().isEmpty());
    }

    @Test
    void roundTripsThroughDisk(@TempDir Path dir) {
        Path file = dir.resolve("sessions.json");
        SessionEntry claude = new SessionEntry("mhm-foo", "/Users/x/Projects/foo",
                HarnessType.CLAUDE_CODE, "abc-123", Instant.parse("2026-08-01T00:00:00Z"));
        SessionEntry cursor = new SessionEntry("mhm-bar", "/Users/x/Projects/bar",
                HarnessType.CURSOR_AGENT, null, Instant.parse("2026-08-02T00:00:00Z"));

        SessionRegistry written = SessionRegistry.load(file);
        written.put(claude);
        written.put(cursor);

        SessionRegistry reloaded = SessionRegistry.load(file);
        List<SessionEntry> sessions = reloaded.sessions();
        assertEquals(2, sessions.size());
        assertEquals(claude, reloaded.find("mhm-foo").orElseThrow());
        assertEquals(cursor, reloaded.find("mhm-bar").orElseThrow());
        assertTrue(reloaded.find("mhm-bar").orElseThrow().harnessSessionIdOpt().isEmpty());
    }

    @Test
    void renamedDisplayNameRoundTripsAndCanBeCleared(@TempDir Path dir) {
        Path file = dir.resolve("sessions.json");
        SessionRegistry registry = SessionRegistry.load(file);
        SessionEntry entry = new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE,
                null, Instant.EPOCH);

        registry.put(entry.withDisplayName("  My useful name  "));
        assertEquals("My useful name",
                SessionRegistry.load(file).find("mhm-foo").orElseThrow().displayName());

        registry.put(registry.find("mhm-foo").orElseThrow().withDisplayName("  "));
        assertNull(SessionRegistry.load(file).find("mhm-foo").orElseThrow().displayName());
    }

    @Test
    void putOverwritesExistingEntryForSameSession(@TempDir Path dir) {
        SessionRegistry registry = SessionRegistry.load(dir.resolve("sessions.json"));
        registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));
        registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE, "resumed-id", Instant.EPOCH));

        assertEquals(1, registry.sessions().size());
        assertEquals("resumed-id", registry.find("mhm-foo").orElseThrow().harnessSessionId());
    }

    @Test
    void recoveredHarnessSessionIdPersistsWithoutClobberingOtherMetadata(@TempDir Path dir) {
        Path file = dir.resolve("sessions.json");
        SessionRegistry registry = SessionRegistry.load(file);
        registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE,
                null, Instant.EPOCH, "My session"));

        registry.recordHarnessSessionId("mhm-foo", "  fd626959-efe0-414b-a3f5-9261602748ed  ");

        SessionEntry saved = SessionRegistry.load(file).find("mhm-foo").orElseThrow();
        assertEquals("fd626959-efe0-414b-a3f5-9261602748ed", saved.harnessSessionId());
        assertEquals("My session", saved.displayName());
    }

    @Test
    void removeDropsTheEntryAndPersists(@TempDir Path dir) {
        Path file = dir.resolve("sessions.json");
        SessionRegistry registry = SessionRegistry.load(file);
        registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));
        registry.remove("mhm-foo");

        assertTrue(registry.sessions().isEmpty());
        assertTrue(SessionRegistry.load(file).sessions().isEmpty());
    }

    @Test
    void corruptFileIsToleratedAsEmpty(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        Files.writeString(file, "{ this is not valid json ][");

        SessionRegistry registry = SessionRegistry.load(file);
        assertTrue(registry.sessions().isEmpty());

        // and it's still usable — a subsequent mutation overwrites the garbage cleanly
        registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));
        assertEquals(1, SessionRegistry.load(file).sessions().size());
    }

    @Test
    void corruptFileIsBackedUpBeforeItCanBeOverwritten(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        String garbage = "{ this is not valid json ][";
        Files.writeString(file, garbage);

        SessionRegistry.load(file);

        try (var siblings = Files.list(dir)) {
            Path backup = siblings
                    .filter(p -> p.getFileName().toString().startsWith("sessions.json.corrupt-"))
                    .findFirst().orElseThrow();
            assertEquals(garbage, Files.readString(backup));
        }
    }

    @Test
    void unreadableFileThatCannotBeBackedUpIsNeverOverwritten(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        String original = "{\"sessions\": [{\"sessionName\": \"mhm-keep\"}]}";
        Files.writeString(file, original);
        assumeTrue(file.getFileSystem().supportedFileAttributeViews().contains("posix"));
        Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("---------"));
        try {
            assumeFalse(Files.isReadable(file), "permissions aren't enforced (running as root?)");

            SessionRegistry registry = SessionRegistry.load(file);
            assertTrue(registry.sessions().isEmpty());
            registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));
            assertEquals(1, registry.sessions().size(), "the run still works in memory");
        } finally {
            Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("rw-------"));
        }
        assertEquals(original, Files.readString(file));
    }

    @Test
    void missingOrNullSessionsListLoadsEmpty(@TempDir Path dir) throws Exception {
        Path emptyObject = dir.resolve("empty-object.json");
        Files.writeString(emptyObject, "{}");
        assertTrue(SessionRegistry.load(emptyObject).sessions().isEmpty());

        Path nullSessions = dir.resolve("null-sessions.json");
        Files.writeString(nullSessions, "{\"sessions\": null}");
        assertTrue(SessionRegistry.load(nullSessions).sessions().isEmpty());
    }

    @Test
    void nullEntryIsSkipped(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        Files.writeString(file, "{\"sessions\": [null]}");

        SessionRegistry registry = SessionRegistry.load(file);
        assertTrue(registry.sessions().isEmpty());

        // and it's still usable afterwards
        registry.put(new SessionEntry("mhm-foo", "/a", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));
        assertEquals(1, SessionRegistry.load(file).sessions().size());
    }

    @Test
    void unknownHarnessTypeEntryIsPreservedAcrossMutations(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        Files.writeString(file, """
                {"sessions": [
                  {"sessionName": "mhm-foo", "projectPath": "/a", "harnessType": "claude-code",
                   "harnessSessionId": "resume-foo", "createdAt": "2026-08-01T00:00:00Z"},
                  {"sessionName": "mhm-future", "projectPath": "/b", "harnessType": "gemini-cli",
                   "harnessSessionId": "resume-future", "createdAt": "2026-08-02T00:00:00Z"},
                  {"sessionName": "mhm-bar", "projectPath": "/c", "harnessType": "cursor-agent",
                   "harnessSessionId": null, "createdAt": "2026-08-03T00:00:00Z"}
                ]}
                """);

        SessionRegistry registry = SessionRegistry.load(file);
        assertEquals(2, registry.sessions().size());
        assertEquals("resume-foo", registry.find("mhm-foo").orElseThrow().harnessSessionId());
        assertTrue(registry.find("mhm-bar").isPresent());

        // a routine mutation must not destroy the entry this build can't read
        registry.put(new SessionEntry("mhm-new", "/d", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));

        String saved = Files.readString(file);
        assertTrue(saved.contains("gemini-cli"));
        assertTrue(saved.contains("resume-future"));
        assertEquals(3, SessionRegistry.load(file).sessions().size());
    }

    @Test
    void putUnderAPreservedUnknownEntrysKeySupersedesIt(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        Files.writeString(file, """
                {"sessions": [
                  {"sessionName": "mhm-x", "projectPath": "/old", "harnessType": "gemini-cli",
                   "harnessSessionId": "stale-id", "createdAt": "2026-08-01T00:00:00Z"}
                ]}
                """);

        SessionRegistry registry = SessionRegistry.load(file);
        assertTrue(registry.sessions().isEmpty()); // unknown type — preserved, not bound

        // the user re-creates the session under this build's harness types: their
        // explicit action wins — the file must not carry two entries for mhm-x
        registry.put(new SessionEntry("mhm-x", "/new", HarnessType.CLAUDE_CODE, "fresh-id",
                Instant.EPOCH));

        String saved = Files.readString(file);
        assertTrue(!saved.contains("gemini-cli"));
        assertTrue(!saved.contains("stale-id"));
        assertEquals(1, SessionRegistry.load(file).sessions().size());
        assertEquals("fresh-id", SessionRegistry.load(file).find("mhm-x").orElseThrow().harnessSessionId());
    }

    @Test
    void newerBuildFieldsOnABindableEntrySurviveASave(@TempDir Path dir) throws Exception {
        Path file = dir.resolve("sessions.json");
        Files.writeString(file, """
                {"sessions": [
                  {"sessionName": "mhm-foo", "projectPath": "/a", "harnessType": "claude-code",
                   "harnessSessionId": "resume-foo", "createdAt": "2026-08-01T00:00:00Z",
                   "newerBuildField": "must-survive"}
                ]}
                """);

        SessionRegistry registry = SessionRegistry.load(file);
        assertEquals(1, registry.sessions().size()); // binds fine — the extra field is just dropped in memory

        // an unrelated mutation rewrites the file; the field this build doesn't know must ride along
        registry.put(new SessionEntry("mhm-new", "/d", HarnessType.CLAUDE_CODE, null, Instant.EPOCH));

        String saved = Files.readString(file);
        assertTrue(saved.contains("must-survive"));
        assertEquals("resume-foo", SessionRegistry.load(file).find("mhm-foo").orElseThrow().harnessSessionId());
    }
}
