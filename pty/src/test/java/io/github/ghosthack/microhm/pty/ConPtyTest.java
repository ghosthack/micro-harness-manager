package io.github.ghosthack.microhm.pty;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** The Windows PTY: a ConPTY pseudoconsole. */
@EnabledOnOs(OS.WINDOWS)
final class ConPtyTest {

    private static final String POWERSHELL = "powershell.exe";

    private static Map<String, String> env() {
        Map<String, String> env = new HashMap<>();
        for (String name : List.of("SystemRoot", "windir", "ComSpec", "PATHEXT", "SystemDrive", "TEMP", "TMP",
                "USERPROFILE", "LOCALAPPDATA", "APPDATA", "HOMEDRIVE", "HOMEPATH", "USERNAME", "PSModulePath")) {
            String value = System.getenv(name);
            if (value != null) {
                env.put(name, value);
            }
        }
        String root = System.getenv("SystemRoot");
        env.put("PATH", root + "\\System32;" + root + ";" + root + "\\System32\\WindowsPowerShell\\v1.0");
        return env;
    }

    /** Everything the pseudoconsole prints until output ends. */
    private static String drain(PtyProcess process) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        InputStream in = process.getInputStream();
        byte[] buffer = new byte[4096];
        int n;
        while ((n = in.read(buffer)) >= 0) {
            out.write(buffer, 0, n);
        }
        return out.toString(StandardCharsets.UTF_8);
    }

    private static String readUntil(PtyProcess process, String needle) throws IOException {
        StringBuilder seen = new StringBuilder();
        byte[] buffer = new byte[4096];
        int n;
        while (!seen.toString().contains(needle) && (n = process.getInputStream().read(buffer)) >= 0) {
            seen.append(new String(buffer, 0, n, StandardCharsets.UTF_8));
        }
        return seen.toString();
    }

    @Test
    void outputArrivesAndOutputEndsAfterExit(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("cmd.exe", "/c", "echo hello-conpty& cd"), env(), dir, 100, 30);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("hello-conpty"), output);
        assertTrue(output.toLowerCase().contains(dir.toRealPath().toString().toLowerCase()), "working directory: " + output);
    }

    @Test
    void exitCodeIsReported(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("cmd.exe", "/c", "exit 7"), env(), dir, 80, 24);
        drain(process);
        assertEquals(7, process.waitFor());
        assertFalse(process.isAlive());
    }

    @Test
    void inputReachesTheChild(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of(POWERSHELL, "-NoProfile", "-Command",
                "$line = Read-Host 'ready'; Write-Output ('got:' + $line)"), env(), dir, 80, 24);
        readUntil(process, "ready");
        process.getOutputStream().write("hello\r".getBytes(StandardCharsets.UTF_8));
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("got:hello"), output);
    }

    @Test
    void sizeAndResizeAreSeenByTheChild(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of(POWERSHELL, "-NoProfile", "-Command",
                "Write-Output ('size1=' + $Host.UI.RawUI.WindowSize.Width + 'x' + $Host.UI.RawUI.WindowSize.Height);"
                        + " $null = Read-Host 'go';"
                        + " Write-Output ('size2=' + $Host.UI.RawUI.WindowSize.Width + 'x' + $Host.UI.RawUI.WindowSize.Height)"),
                env(), dir, 100, 30);
        String first = readUntil(process, "go");
        assertTrue(first.contains("size1=100x30"), first);
        process.setWinSize(132, 40);
        Thread.sleep(300);
        process.getOutputStream().write("\r".getBytes(StandardCharsets.UTF_8));
        String rest = drain(process);
        assertTrue(rest.contains("size2=132x40"), rest);
    }

    @Test
    void theChildGetsTheGivenEnvironment(@TempDir Path dir) throws Exception {
        Map<String, String> env = env();
        env.put("MICROHM_PTY_TEST", "yes");
        env.put("WITH_SPACES", "a b  c");
        PtyProcess process = PtyProcess.start(List.of("cmd.exe", "/c", "set"), env, dir, 200, 50);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("MICROHM_PTY_TEST=yes"), output);
        assertTrue(output.contains("WITH_SPACES=a b  c"), output);
        assertFalse(output.contains("JAVA_HOME="), "nothing from the parent: " + output);
    }

    /** A space-containing argument reaches the child whole (the quoting rules themselves
     * are checked exactly in {@link ConPtyQuotingTest}). */
    @Test
    void argumentsArriveIntact(@TempDir Path dir) throws Exception {
        // -File passes the remaining arguments through as arguments (-Command would take them as script)
        Path script = java.nio.file.Files.writeString(dir.resolve("args.ps1"),
                "Write-Output ('count=' + $args.Count + ' first=[' + $args[0] + '] second=[' + $args[1] + ']')");
        PtyProcess process = PtyProcess.start(List.of(POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", script.toString(), "with space", "quote\"inside"), env(), dir, 200, 50);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("count=2 first=[with space] second=[quote\"inside]"), output);
    }

    @Test
    void aMissingProgramOrDirectoryFailsToStart(@TempDir Path dir) {
        assertThrows(IOException.class, () -> PtyProcess.start(List.of("no-such-program-xyz"), env(), dir, 80, 24));
        assertThrows(IOException.class, () -> PtyProcess.start(List.of("C:\\nope\\nothing.exe"), env(), dir, 80, 24));
        assertThrows(IOException.class, () -> PtyProcess.start(List.of("cmd.exe"), env(), dir.resolve("missing"), 80, 24));
    }

    @Test
    void killEndsTheWholeTree(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("cmd.exe", "/c", "ping -n 60 127.0.0.1 >nul"), env(), dir, 80, 24);
        Thread reader = Thread.ofVirtual().start(() -> {
            try {
                drain(process);
            } catch (IOException ignored) {
                // consumed
            }
        });
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        List<ProcessHandle> children = List.of();
        while (children.isEmpty() && System.nanoTime() < deadline) {
            Thread.sleep(100);
            children = ProcessHandle.of(process.pid()).map(h -> h.descendants().toList()).orElse(List.of());
        }
        assertFalse(children.isEmpty(), "ping started under cmd");
        process.destroyForcibly();
        assertTrue(process.waitFor(10, TimeUnit.SECONDS));
        for (ProcessHandle child : children) {
            assertTrue(child.onExit().get(10, TimeUnit.SECONDS) != null, "descendant ended with the job");
        }
        reader.join(10_000);
    }

    /** Ctrl+C typed into the terminal interrupts the program in it, whatever this process
     * inherited: Windows OpenSSH (and other launchers) start processes with Ctrl+C ignored,
     * a flag every child inherits, so the pseudoconsole's children would ignore it too. */
    @Test
    void ctrlCInterruptsTheForegroundProgram(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("cmd.exe", "/c", "ping -n 30 127.0.0.1"), env(), dir, 100, 30);
        readUntil(process, "Reply from");
        process.getOutputStream().write(3);
        Thread reader = Thread.ofVirtual().start(() -> {
            try {
                drain(process);
            } catch (IOException ignored) {
                // consumed
            }
        });
        assertTrue(process.waitFor(10, TimeUnit.SECONDS), "ping still running after Ctrl+C");
        reader.join(10_000);
    }

    @Test
    void hangupEndsAnInteractiveShell(@TempDir Path dir) throws Exception {
        PtyProcess shell = PtyProcess.start(List.of("cmd.exe"), env(), dir, 80, 24);
        Thread reader = Thread.ofVirtual().start(() -> {
            try {
                drain(shell);
            } catch (IOException ignored) {
                // consumed
            }
        });
        Thread.sleep(500);
        shell.hangup();
        assertTrue(shell.waitFor(10, TimeUnit.SECONDS));
        reader.join(10_000);
        assertFalse(reader.isAlive(), "output ended");
    }

    @Test
    void writesAfterTheTerminalClosesFail(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("cmd.exe", "/c", "exit 0"), env(), dir, 80, 24);
        drain(process);
        process.waitFor();
        process.closeTerminal();
        assertThrows(IOException.class, () -> process.getOutputStream().write('x'));
        assertThrows(IOException.class, () -> process.setWinSize(10, 10));
        assertEquals(-1, process.getInputStream().read());
    }

    @Test
    void largeOutputArrivesIntact(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of(POWERSHELL, "-NoProfile", "-Command",
                "1..20000 | ForEach-Object { 'line' + $_ }"), env(), dir, 120, 30);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("line1\r\n") || output.contains("line1"), output.length() + " chars");
        assertTrue(output.contains("line20000"), output.length() + " chars");
    }
}
