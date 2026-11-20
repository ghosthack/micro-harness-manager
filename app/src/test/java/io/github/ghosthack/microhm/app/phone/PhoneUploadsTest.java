package io.github.ghosthack.microhm.app.phone;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class PhoneUploadsTest {

    @TempDir
    Path dir;

    private final Clock clock = Clock.fixed(Instant.parse("2026-11-20T15:30:12Z"), ZoneId.of("UTC"));

    private String nameFor(String name, String type) {
        // drop the stamp and the random tag
        return new PhoneUploads(dir, clock).fileName(name, type).replaceFirst("^\\d{8}-\\d{6}-[0-9a-f]{4}-", "");
    }

    @Test
    void namesAreSafeInAPromptOrAShell() {
        assertEquals("Screen_Shot_2026-11-20_at_3.04_PM.png", nameFor("Screen Shot 2026-11-20 at 3.04 PM.png", null));
        assertEquals("passwd", nameFor("../../etc/passwd", null));
        assertEquals("evil.jpg", nameFor("C:\\dir\\evil.jpg", "image/jpeg"));
        assertEquals("x_y_rm_.txt", nameFor("x;y$(rm).txt", null));
        assertEquals("upload.png", nameFor("", "image/png"));
        assertEquals("upload.jpg", nameFor(null, "image/jpeg; q=1"));
        assertEquals("hidden", nameFor(".hidden", null));
        assertEquals("IMG_0001.heic", nameFor("IMG_0001.HEIC", "image/heic"));
    }

    @Test
    void namesCarryTheTime() {
        String name = new PhoneUploads(dir, clock).fileName("a.png", null);
        assertTrue(name.matches("\\d{8}-\\d{6}-[0-9a-f]{4}-a\\.png"), name);
    }

    @Test
    void anEmptyOrOversizedBodyIsNotKept() throws IOException {
        PhoneUploads uploads = new PhoneUploads(dir, clock);
        assertThrows(IOException.class, () -> uploads.save(new ByteArrayInputStream(new byte[0]), "a.png", null));
        assertThrows(PhoneUploads.TooLarge.class, () -> uploads.save(
                new ByteArrayInputStream(new byte[(int) PhoneUploads.MAX_BYTES + 1]), "b.png", null));
        try (var files = Files.list(dir)) {
            assertEquals(0, files.count());
        }
    }

    @Test
    void oldFilesAreRemovedAsNewOnesArrive() throws IOException {
        Path old = Files.writeString(dir.resolve("old.png"), "x");
        Files.setLastModifiedTime(old, FileTime.from(clock.instant().minus(PhoneUploads.KEEP).minus(Duration.ofHours(1))));
        Path recent = Files.writeString(dir.resolve("recent.png"), "x");
        Files.setLastModifiedTime(recent, FileTime.from(clock.instant().minus(Duration.ofDays(1))));
        Path saved = new PhoneUploads(dir, clock).save(new ByteArrayInputStream(new byte[]{1}), "new.png", null);
        assertFalse(Files.exists(old));
        assertTrue(Files.exists(recent));
        assertTrue(Files.exists(saved));
    }
}
