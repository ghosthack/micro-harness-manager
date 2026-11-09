package io.github.ghosthack.microhm.app.perf;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PerfStatsTest {

    @Test
    void formats() {
        assertEquals("0.38 s", PerfStats.seconds(380));
        assertEquals("12.3 s", PerfStats.seconds(12_340));
        assertEquals("40 MB", PerfStats.megabytes(40L * 1024 * 1024));
        assertEquals("—", PerfStats.megabytes(-1));
        assertEquals("45 s", PerfStats.duration(Duration.ofSeconds(45)));
        assertEquals("2 min 5 s", PerfStats.duration(Duration.ofSeconds(125)));
        assertEquals("3 h 7 min", PerfStats.duration(Duration.ofMinutes(187)));
    }

    @Test
    void aSnapshotHasTheStartupRowsFirstAndCopiesAsText() {
        List<PerfStats.Row> rows = PerfStats.snapshot();
        assertEquals("Startup", rows.get(0).label());
        assertEquals("Startup cache", rows.get(1).label());
        assertFalse(rows.stream().anyMatch(r -> r.value().isBlank()));
        assertTrue(PerfStats.asText(rows).startsWith("Startup: "));
    }
}
