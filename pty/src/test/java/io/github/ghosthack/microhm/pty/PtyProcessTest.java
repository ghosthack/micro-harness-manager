package io.github.ghosthack.microhm.pty;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class PtyProcessTest {

    private static Map<String, String> env() {
        Map<String, String> env = new HashMap<>();
        env.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
        env.put("TERM", "xterm-256color");
        env.put("LANG", "en_US.UTF-8");
        return env;
    }

    /** Everything the terminal prints until output ends. */
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

    /** Reads until {@code needle} appears (or output ends). */
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
    void childHasThePtyAsItsControllingTerminalAtTheRequestedSize(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c",
                "tty; stty size; (exec 3</dev/tty && echo CTTY-OK) 2>&1; pwd -P"), env(), dir, 100, 30);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("/dev/"), output);
        assertTrue(output.contains("30 100"), output);
        assertTrue(output.contains("CTTY-OK"), output);
        assertTrue(output.contains(dir.toRealPath().toString()), output);
    }

    /** zsh, unlike bash, does not take the terminal for itself: the PTY layer must have made
     * it the controlling terminal already, or job control, /dev/tty and the foreground
     * process group ({@code tpgid}, which the session daemon's foreground probe reads) are
     * all missing. */
    @Test
    void aShellThatDoesNotTakeTheTerminalItselfStillHasIt(@TempDir Path dir) throws Exception {
        org.junit.jupiter.api.Assumptions.assumeTrue(Files.isExecutable(Path.of("/bin/zsh")), "no /bin/zsh");
        PtyProcess process = PtyProcess.start(List.of("/bin/zsh", "-f", "-c",
                "ps -o tpgid= -p $$; (exec 3</dev/tty && echo CTTY-OK) 2>&1; true"), env(), dir, 80, 24);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("CTTY-OK"), output);
        assertEquals(Long.toString(process.pid()), output.trim().split("\\s+")[0],
                "the shell's own process group is the terminal's foreground group: " + output);
    }

    @Test
    void argvZeroIsPreserved(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "echo \"[$0]\"", "custom-name"),
                env(), dir, 80, 24);
        assertTrue(drain(process).contains("[custom-name]"));
        assertEquals(0, process.waitFor());
    }

    @Test
    void childIsASessionLeader(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "ps -o sess= -o pgid= -p $$"),
                env(), dir, 80, 24);
        String output = drain(process).trim();
        process.waitFor();
        String[] columns = output.split("\\s+");
        assertEquals(Long.toString(process.pid()), columns[columns.length - 1], output);
    }

    @Test
    void inputIsEchoedAndReachesTheChild(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "read line; echo \"got:$line\""),
                env(), dir, 80, 24);
        process.getOutputStream().write("hello\r".getBytes(StandardCharsets.UTF_8));
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("got:hello"), output);
    }

    @Test
    void resizeIsSeenByTheChild(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c",
                "echo ready; read x; stty size"), env(), dir, 80, 24);
        readUntil(process, "ready");
        process.setWinSize(132, 50);
        process.getOutputStream().write("\r".getBytes(StandardCharsets.UTF_8));
        String output = drain(process);
        assertTrue(output.contains("50 132"), output);
    }

    @Test
    void exitStatusAndSignalDeathAreReported(@TempDir Path dir) throws Exception {
        PtyProcess exits = PtyProcess.start(List.of("/bin/sh", "-c", "exit 7"), env(), dir, 80, 24);
        drain(exits);
        assertEquals(7, exits.waitFor());
        assertFalse(exits.isAlive());

        PtyProcess sleeper = PtyProcess.start(List.of("/bin/sleep", "60"), env(), dir, 80, 24);
        assertTrue(sleeper.isAlive());
        assertFalse(sleeper.waitFor(100, TimeUnit.MILLISECONDS));
        sleeper.destroyForcibly();
        assertTrue(sleeper.waitFor(5, TimeUnit.SECONDS));
        assertEquals(128 + 9, sleeper.exitValue());
    }

    /** The output is read throughout, as the daemon does: a process exiting with unread
     * output on its controlling terminal waits in close for it to drain. */
    @Test
    void hangupEndsAnInteractiveShell(@TempDir Path dir) throws Exception {
        PtyProcess shell = PtyProcess.start(List.of("/bin/sh", "-i"), env(), dir, 80, 24);
        Thread reader = Thread.ofVirtual().start(() -> {
            try {
                drain(shell);
            } catch (IOException ignored) {
                // the test only needs the output consumed
            }
        });
        Thread.sleep(200);
        shell.hangup();
        assertTrue(shell.waitFor(5, TimeUnit.SECONDS));
        reader.join(5000);
    }

    @Test
    void programIsResolvedOnTheChildPath(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("echo", "resolved"), env(), dir, 80, 24);
        assertTrue(drain(process).contains("resolved"));
        assertEquals(0, process.waitFor());
    }

    @Test
    void theChildGetsExactlyTheGivenEnvironment(@TempDir Path dir) throws Exception {
        Map<String, String> env = env();
        env.put("MICROHM_PTY_TEST", "yes");
        env.put("WITH_SPACES", "a b  c");
        PtyProcess process = PtyProcess.start(List.of("/usr/bin/env"), env, dir, 80, 24);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        Map<String, String> seen = new HashMap<>();
        for (String line : output.split("\r\n")) {
            int eq = line.indexOf('=');
            if (eq > 0) {
                seen.put(line.substring(0, eq), line.substring(eq + 1));
            }
        }
        assertEquals(env, seen, "exactly the given environment, nothing from the parent or a launcher");
    }

    /** The JVM options variables reach the program, and nothing announces them on the
     * terminal (a JVM started with them prints "Picked up ..."). */
    @Test
    void jvmOptionVariablesReachTheProgramSilently(@TempDir Path dir) throws Exception {
        Map<String, String> env = env();
        env.put("JAVA_TOOL_OPTIONS", "-Dmicrohm.test=1");
        env.put("JDK_JAVA_OPTIONS", "-Dmicrohm.test=2");
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "echo \"[$JAVA_TOOL_OPTIONS|$JDK_JAVA_OPTIONS]\""),
                env, dir, 80, 24);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertEquals("[-Dmicrohm.test=1|-Dmicrohm.test=2]", output.trim());
    }

    /** No signal is blocked or ignored in the child: each one it sends itself kills it with
     * the default action. */
    @Test
    void theChildStartsWithDefaultSignals(@TempDir Path dir) throws Exception {
        int[] signals = {1, 2, 3, 13, 15, 25}; // HUP INT QUIT PIPE TERM XFSZ
        for (int signal : signals) {
            PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "kill -" + signal + " $$; echo SURVIVED"),
                    env(), dir, 80, 24);
            String output = drain(process);
            assertEquals(128 + signal, process.waitFor(), "signal " + signal + ": " + output);
            assertFalse(output.contains("SURVIVED"), "signal " + signal + " was ignored");
        }
        PtyProcess mask = PtyProcess.start(List.of("/bin/sh", "-c", "ps -o sigmask= -p $$"), env(), dir, 80, 24);
        String blocked = drain(mask).trim();
        assertEquals(0, mask.waitFor());
        assertEquals(0L, Long.parseLong(blocked, 16), "blocked signals: " + blocked);
    }

    @Test
    void noParentDescriptorsLeakIntoTheChild(@TempDir Path dir) throws Exception {
        Path marker = Files.writeString(dir.resolve("open-in-parent"), "x");
        try (var held = Files.newInputStream(marker)) {
            // a shell glob, no child process: only the shell's own descriptors are listed
            PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "for f in /dev/fd/*; do echo \"${f#/dev/fd/}\"; done"),
                    env(), dir, 80, 24);
            String fds = drain(process).trim();
            // 0, 1, 2, plus the descriptor the glob itself opens to read the directory
            for (String fd : fds.split("\\s+")) {
                assertTrue(Integer.parseInt(fd) <= 3, "unexpected descriptor in the child: " + fds);
            }
        }
    }

    @Test
    void writesAfterTheTerminalClosesFailInsteadOfHittingAReusedDescriptor(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "exit 0"), env(), dir, 80, 24);
        drain(process);
        process.closeTerminal();
        assertThrows(IOException.class, () -> process.getOutputStream().write('x'));
        assertThrows(IOException.class, () -> process.setWinSize(10, 10));
        assertEquals(-1, process.getInputStream().read());
    }

    @Test
    void aMissingProgramOrDirectoryFailsToStart(@TempDir Path dir) {
        assertThrows(IOException.class,
                () -> PtyProcess.start(List.of("/nonexistent/program"), env(), dir, 80, 24));
        assertThrows(IOException.class,
                () -> PtyProcess.start(List.of("/bin/sh"), env(), dir.resolve("missing"), 80, 24));
    }

    @Test
    void decodesWaitStatus() {
        assertEquals(0, PtyProcess.decode(0));
        assertEquals(3, PtyProcess.decode(3 << 8));
        assertEquals(128 + 15, PtyProcess.decode(15));
    }

    @Test
    void largeOutputArrivesIntact(@TempDir Path dir) throws Exception {
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c",
                "stty -opost; i=0; while [ $i -lt 20000 ]; do echo line$i; i=$((i+1)); done"), env(), dir, 80, 24);
        String output = drain(process);
        assertEquals(0, process.waitFor());
        assertTrue(output.contains("line0\n") && output.contains("line19999\n"), output.length() + " chars");
    }
}
