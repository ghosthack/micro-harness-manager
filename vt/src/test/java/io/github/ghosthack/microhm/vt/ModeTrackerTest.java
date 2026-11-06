package io.github.ghosthack.microhm.vt;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The daemon-side mode tracking ({@link ModeTracker}), including the scroll region across a
 * resize. */
class ModeTrackerTest {

    /** Feeds a raw ModeTracker every token of {@code s} (SGR-normalised, as the pump does). */
    private static void observe(ModeTracker tracker, String s) {
        VtTokenizer.Batch batch = new VtTokenizer().feed(s.getBytes(StandardCharsets.UTF_8));
        for (VtToken t : batch.tokens()) {
            tracker.observe(SgrNormalizer.normalize(t));
        }
    }

    private static HeadlessTerminal.Modes track(String s) {
        ModeTracker tracker = new ModeTracker(24);
        observe(tracker, s);
        return tracker.snapshot();
    }

    @Test
    void bracketedPaste() {
        assertTrue(track("[?2004h").bracketedPaste());
        assertFalse(track("[?2004h[?2004l").bracketedPaste());
    }

    @Test
    void applicationCursorKeysAndKeypad() {
        assertTrue(track("[?1h").applicationCursorKeys());
        assertTrue(track("=").applicationKeypad());
        assertFalse(track("=>").applicationKeypad());
    }

    @Test
    void autoWrapDefaultsOnAndTracksReset() {
        assertTrue(track("").autoWrap());
        assertFalse(track("[?7l").autoWrap());
    }

    @Test
    void cursorVisibleDefaultsOn() {
        assertTrue(track("").cursorVisible());
        assertFalse(track("[?25l").cursorVisible());
    }

    @Test
    void originMode() {
        assertTrue(track("[?6h").originMode());
    }

    @Test
    void mouseTrackingAndSgrFormat() {
        assertEquals(1000, track("[?1000h").mouseTrackingMode());
        assertEquals(1002, track("[?1002h").mouseTrackingMode());
        assertEquals(1003, track("[?1003h").mouseTrackingMode());
        assertEquals(0, track("[?1000h[?1000l").mouseTrackingMode());
        assertTrue(track("[?1006h").mouseSgr());
    }

    @Test
    void focusReporting() {
        assertTrue(track("[?1004h").focusReporting());
    }

    @Test
    void alternateScreen() {
        assertTrue(track("[?1049h").alternateScreen());
        assertFalse(track("[?1049h[?1049l").alternateScreen());
        assertTrue(track("[?47h").alternateScreen());
    }

    @Test
    void cursorShapeFromDecscusr() {
        assertEquals(4, track("[4 q").cursorShape());
        assertEquals(1, track("[0 q").cursorShape()); // 0 normalises to a blinking block
    }

    @Test
    void title() {
        assertEquals("hello", track("]0;hello").title());
        assertEquals("win", track("]2;win\\").title());
    }

    @Test
    void reportedCwdFromOsc7() {
        ModeTracker tracker = new ModeTracker(24);
        observe(tracker, "]7;file://myhost/home/me%20dir");
        assertEquals("/home/me dir", tracker.reportedCwd());
    }

    @Test
    void reportedCwdFromOsc9() {
        ModeTracker tracker = new ModeTracker(24);
        observe(tracker, "]9;9;/tmp/work");
        assertEquals("/tmp/work", tracker.reportedCwd());
        assertNull(new ModeTracker(24).reportedCwd());
    }

    @Test
    void risResetsEverything() {
        ModeTracker tracker = new ModeTracker(24);
        observe(tracker, "[?7l[?25l[?2004h[?1000h[4 q=[3;20r");
        observe(tracker, "c"); // RIS
        HeadlessTerminal.Modes m = tracker.snapshot();
        assertTrue(m.autoWrap());
        assertTrue(m.cursorVisible());
        assertFalse(m.bracketedPaste());
        assertEquals(0, m.mouseTrackingMode());
        assertEquals(0, m.cursorShape());
        assertFalse(m.applicationKeypad());
        assertEquals(1, m.scrollTop());
        assertEquals(24, m.scrollBottom());
    }

    @Test
    void scrollRegionClampedAndValidated() {
        HeadlessTerminal.Modes m = track("\u001b[3;20r");
        assertEquals(3, m.scrollTop());
        assertEquals(20, m.scrollBottom());
        // CSI r resets to the full height.
        assertEquals(1, track("\u001b[3;20r\u001b[r").scrollTop());
        assertEquals(24, track("\u001b[3;20r\u001b[r").scrollBottom());
        // Bottom is clamped to the height; a region of fewer than two lines is ignored.
        assertEquals(24, track("\u001b[3;99r").scrollBottom());
        assertEquals(3, track("\u001b[3;20r\u001b[9;9r").scrollTop());
    }

    @Test
    void scrollRegionResetsOnResizeLikeTheEmulator() {
        // Drive a real HeadlessTerminal so the tracker and the emulator can be cross-checked.
        HeadlessTerminal term = new HeadlessTerminal(80, 24, 100, b -> {
        });
        ModeTracker tracker = new ModeTracker(24);
        apply(term, tracker, "\u001b[3;20r");
        assertEquals(3, term.modes().scrollTop());
        assertEquals(20, term.modes().scrollBottom());

        term.resize(80, 30); // xterm: a resize makes the region the full screen again
        tracker.resized(30);
        assertEquals(1, term.modes().scrollTop());
        assertEquals(30, term.modes().scrollBottom());
        assertEquals(term.modes(), tracker.snapshot());
    }

    @Test
    void modesCrossCheckTheEmulator() {
        HeadlessTerminal term = new HeadlessTerminal(80, 24, 100, b -> {
        });
        ModeTracker tracker = new ModeTracker(24);
        apply(term, tracker, "\u001b[?1h\u001b[?7l\u001b[?6h\u001b[?1049h\u001b[?2004h\u001b[?1002h"
                + "\u001b[?1006h\u001b[?1004h\u001b[5 q\u001b=\u001b[?25l\u001b[2;9r\u001b]2;t\u0007");
        assertEquals(tracker.snapshot(), term.modes());
        apply(term, tracker, "\u001bc");
        assertEquals(tracker.snapshot(), term.modes());
    }

    private static void apply(HeadlessTerminal term, ModeTracker tracker, String s) {
        VtTokenizer.Batch batch = new VtTokenizer().feed(s.getBytes(StandardCharsets.UTF_8));
        java.util.List<VtToken> norm = new java.util.ArrayList<>();
        for (VtToken t : batch.tokens()) {
            VtToken n = SgrNormalizer.normalize(t);
            norm.add(n);
            tracker.observe(n);
        }
        term.apply(norm);
    }
}
