package io.github.ghosthack.microhm.mux.session;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * A live {@link PtySession} on Windows: the platform login shell (PowerShell) in a ConPTY
 * pseudoconsole — typed commands, the capture, the foreground probe following a program
 * and back, Ctrl+C, the in-band size, and the kill sequence ending the whole tree.
 */
@EnabledOnOs(OS.WINDOWS)
class WindowsPtySessionTest {

    private static final int HISTORY = 1000;
    private static final Duration SLOW = Duration.ofSeconds(20);

    @TempDir
    Path workdir;

    private PtySession session;
    private final RecordingClient client = new RecordingClient();
    private final CountDownLatch ended = new CountDownLatch(1);
    private final AtomicReference<Integer> endedWith = new AtomicReference<>();

    @BeforeEach
    void spawn() throws IOException {
        ShellCommand shell = ShellCommand.forSession("w", null, null);
        session = PtySession.spawn("w", workdir, 100, 30, shell, HISTORY, (s, code) -> {
            endedWith.set(code);
            ended.countDown();
        });
        session.attach(client, 100, 30);
    }

    @AfterEach
    void kill() {
        if (session != null) {
            session.kill();
        }
    }

    @Test
    void theLoginShellIsPowerShellAndReportsItself() {
        Await.until("PowerShell at its prompt", SLOW, () -> session.capture().text().contains("PS "),
                () -> session.capture().text());
        String fg = session.capture().foregroundCommand();
        assertTrue(fg.equals("powershell") || fg.equals("pwsh"), fg);
        assertEquals("conpty", session.info().backend());
    }

    @Test
    void typedCommandsReachTheScreenAndTheForegroundFollowsAProgram() {
        Await.until("PowerShell at its prompt", SLOW, () -> session.capture().text().contains("PS "));
        session.sendKeys("Write-Output ('hel' + 'lo-' + 'win')", true);
        Await.until("the output", SLOW, () -> session.capture().text().contains("hello-win"),
                () -> session.capture().text());
        assertTrue(client.text().contains("hello-win"), "the attached client saw the live output");

        session.sendKeys("ping -n 60 127.0.0.1", true);
        Await.until("ping in the foreground", SLOW, () -> session.capture().foregroundCommand().equals("ping"),
                () -> session.capture().foregroundCommand());
        session.input(List.of("C-c"));
        Await.until("Ctrl+C to end ping", SLOW, () -> !session.capture().foregroundCommand().equals("ping"),
                () -> session.capture().foregroundCommand());
        String fg = session.capture().foregroundCommand();
        assertTrue(fg.equals("powershell") || fg.equals("pwsh"), "back at the shell: " + fg);
    }

    @Test
    void resizeReachesTheShell() {
        Await.until("PowerShell at its prompt", SLOW, () -> session.capture().text().contains("PS "));
        session.resize(132, 40, null);
        session.sendKeys("Write-Output ('w=' + $Host.UI.RawUI.WindowSize.Width + ' h=' + $Host.UI.RawUI.WindowSize.Height)", true);
        Await.until("the new size", SLOW, () -> session.capture().text().contains("w=132 h=40"),
                () -> session.capture().text());
    }

    @Test
    void killEndsTheShellAndWhatItStarted() throws Exception {
        Await.until("PowerShell at its prompt", SLOW, () -> session.capture().text().contains("PS "));
        session.sendKeys("ping -n 60 127.0.0.1", true);
        Await.until("ping in the foreground", SLOW, () -> session.capture().foregroundCommand().equals("ping"));
        List<ProcessHandle> descendants = ProcessHandle.of(session.info().pid()).orElseThrow().descendants().toList();
        assertFalse(descendants.isEmpty(), "ping is a descendant of the shell");
        session.kill();
        assertFalse(session.isAlive());
        assertTrue(ended.await(20, TimeUnit.SECONDS), "the exit listener ran");
        assertNotNull(endedWith.get());
        for (ProcessHandle h : descendants) {
            assertTrue(h.onExit().get(20, TimeUnit.SECONDS) != null);
        }
        Await.until("onExit on the client", SLOW, client::hasExited);
    }

    @Test
    void exitEndsTheSession() throws Exception {
        Await.until("PowerShell at its prompt", SLOW, () -> session.capture().text().contains("PS "));
        session.sendKeys("exit 5", true);
        assertTrue(ended.await(20, TimeUnit.SECONDS), "the session ended");
        assertEquals(5, endedWith.get());
    }
}
