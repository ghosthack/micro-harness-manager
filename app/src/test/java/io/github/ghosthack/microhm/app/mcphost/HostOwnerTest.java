package io.github.ghosthack.microhm.app.mcphost;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class HostOwnerTest {

    @TempDir
    Path dir;

    @Test
    void aRecordRoundTripsThroughItsFile() throws Exception {
        Path registry = dir.resolve("sessions.json");
        HostOwner.Record record = new HostOwner.Record(4242, 1_700_000_000_123L);
        HostOwner.write(registry, record);
        assertEquals(Optional.of(record), HostOwner.read(registry));
        assertEquals(dir.resolve("mcp-host.pid"), HostOwner.file(registry));
    }

    @Test
    void aGarbledOrMissingFileReadsAsNoHost() throws Exception {
        Path registry = dir.resolve("sessions.json");
        assertTrue(HostOwner.read(registry).isEmpty());
        Files.writeString(HostOwner.file(registry), "not a record\n");
        assertTrue(HostOwner.read(registry).isEmpty());
    }

    @Test
    void thisProcessIsLiveUnderItsOwnRecord() {
        HostOwner.Record self = HostOwner.current().orElseThrow();
        assertEquals(ProcessHandle.current().pid(), self.pid());
        assertTrue(HostOwner.live(self).isPresent());
    }

    @Test
    void aReusedPidWithAnotherStartTimeIsNotTheHost() {
        HostOwner.Record self = HostOwner.current().orElseThrow();
        HostOwner.Record reused = new HostOwner.Record(self.pid(), self.startEpochMillis() - 60_000);
        assertFalse(HostOwner.live(reused).isPresent(), "a pid alone must never identify the host");
        assertFalse(HostOwner.live(new HostOwner.Record(self.pid(), self.startEpochMillis()), pid -> Optional.empty())
                .isPresent());
    }

    @Test
    void clearingLeavesANewerHostsRecordAlone() throws Exception {
        Path registry = dir.resolve("sessions.json");
        HostOwner.Record older = new HostOwner.Record(1, 1);
        HostOwner.Record newer = new HostOwner.Record(2, 2);
        HostOwner.write(registry, newer);
        HostOwner.clear(registry, older);
        assertEquals(Optional.of(newer), HostOwner.read(registry));
        HostOwner.clear(registry, newer);
        assertTrue(HostOwner.read(registry).isEmpty());
    }

    @Test
    void stoppingWithNoLiveHostClearsAStaleRecord() throws Exception {
        Path registry = dir.resolve("sessions.json");
        HostOwner.Record self = HostOwner.current().orElseThrow();
        HostOwner.write(registry, new HostOwner.Record(self.pid(), self.startEpochMillis() - 60_000));
        assertTrue(HostOwner.stop(registry, java.time.Duration.ofSeconds(1)));
        assertTrue(HostOwner.read(registry).isEmpty());
    }
}
