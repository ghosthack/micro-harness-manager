package io.github.ghosthack.microhm.mux.session;

import io.github.ghosthack.microhm.pty.PtyProcess;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The synthetic trees for
 * the tree-walk heuristic, the {@code ps} rule over canned output, and a live
 * {@code sh -c 'sleep 5'} under a real PTY (the {@code pid == tpgid} rule needs a
 * controlling terminal — without one {@code tpgid} is 0 — so the live process gets one
 * from microhm-pty; bash execs the single command, so the tty's foreground group leader is
 * {@code sleep} itself).
 */
class ForegroundProbeTest {

    /** A synthetic process node; children are added by name and get increasing pids/start times. */
    private static final class Node implements ForegroundProbe.ProcessNode {
        private static long nextPid = 1000;
        private final long pid = nextPid++;
        private final String command;
        private final Instant started = Instant.ofEpochSecond(pid);
        private final List<Node> children = new ArrayList<>();
        boolean alive = true;

        Node(String command) {
            this.command = command;
        }

        Node child(String command) {
            Node c = new Node(command);
            children.add(c);
            return c;
        }

        @Override
        public long pid() {
            return pid;
        }

        @Override
        public String command() {
            return command;
        }

        @Override
        public boolean isAlive() {
            return alive;
        }

        @Override
        public Instant startTime() {
            return started;
        }

        @Override
        public List<Node> children() {
            return children;
        }
    }

    @Test
    void shellAloneReportsTheShell() {
        Node shell = new Node("/bin/zsh");
        ForegroundProbe.Foreground fg = ForegroundProbe.walk(shell);
        assertEquals("zsh", fg.command());
        assertEquals(shell.pid(), fg.pid());
    }

    @Test
    void shellToNodeReportsNode() {
        Node shell = new Node("-zsh");
        Node node = shell.child("/opt/homebrew/bin/node");
        ForegroundProbe.Foreground fg = ForegroundProbe.walk(shell);
        assertEquals("node", fg.command());
        assertEquals(node.pid(), fg.pid());
    }

    @Test
    void unreadableNamesAreSkipped() {
        Node shell = new Node("bash");
        Node node = shell.child("").child("node");
        assertEquals(new ForegroundProbe.Foreground(node.pid(), "node"), ForegroundProbe.walk(shell));
    }

    @Test
    void windowsShellAloneReportsTheShellWithoutExe() {
        Node shell = new Node("C:\\Program Files\\PowerShell\\7\\pwsh.exe");
        assertEquals(new ForegroundProbe.Foreground(shell.pid(), "pwsh"), ForegroundProbe.walk(shell));
    }

    @Test
    void windowsCmdWrapperIsSkipped() {
        // an npm shim runs node through cmd.exe
        Node shell = new Node("powershell.exe");
        Node node = shell.child("cmd.exe").child("C:\\Program Files\\nodejs\\node.exe");
        assertEquals(new ForegroundProbe.Foreground(node.pid(), "node"), ForegroundProbe.walk(shell));
    }

    @Test
    void windowsWrapperWithNoChildrenFallsBackToTheShell() {
        Node shell = new Node("cmd.exe");
        shell.child("conhost.exe");
        assertEquals(new ForegroundProbe.Foreground(shell.pid(), "cmd"), ForegroundProbe.walk(shell));
    }

    @Test
    void harnessIsReportedNotItsVersionChild() {
        Node shell = new Node("/bin/zsh");
        Node claude = shell.child("/Users/x/.local/bin/claude");
        claude.child("2.1.235");
        assertEquals(new ForegroundProbe.Foreground(claude.pid(), "claude"), ForegroundProbe.walk(shell));
    }

    @Test
    void harnessIsReportedNotItsToolOrMcpChildren() {
        Node shell = new Node("-zsh");
        Node claude = shell.child("claude");
        claude.child("Python");
        claude.child("/usr/bin/git");
        assertEquals(new ForegroundProbe.Foreground(claude.pid(), "claude"), ForegroundProbe.walk(shell));
    }

    @Test
    void newestLiveChildWins() {
        Node shell = new Node("bash");
        Node older = shell.child("vim");
        Node newer = shell.child("less");
        assertEquals("less", ForegroundProbe.walk(shell).command());
        newer.alive = false;
        assertEquals("vim", ForegroundProbe.walk(shell).command());
        older.alive = false;
        assertEquals("bash", ForegroundProbe.walk(shell).command());
    }

    @Test
    void unreadableChildWithNoChildrenFallsBackToTheShell() {
        Node shell = new Node("bash");
        shell.child("");
        assertEquals(new ForegroundProbe.Foreground(shell.pid(), "bash"), ForegroundProbe.walk(shell));
    }

    @Test
    void normalizesNames() {
        assertEquals("zsh", ForegroundProbe.normalize("-zsh"));
        assertEquals("node", ForegroundProbe.normalize("/usr/local/bin/Node"));
        assertEquals("node", ForegroundProbe.normalize("C:\\nodejs\\Node.EXE"));
        assertEquals("python", ForegroundProbe.normalize("/opt/homebrew/bin/Python"));
        assertEquals("", ForegroundProbe.normalize(null));
        assertEquals("", ForegroundProbe.normalize("  "));
    }

    @Test
    void psRuleFindsTheForegroundGroupLeader() {
        String ps = """
                  501   501   777 -zsh
                  777   777   777 /usr/local/bin/node
                  778   777   777 /usr/bin/git
                """;
        assertEquals(Optional.of(new ForegroundProbe.Foreground(777, "node")), ForegroundProbe.parsePs(ps, 501));
    }

    @Test
    void psRuleFallsBackToTheShellWhenTheLeaderIsGoneOrNoTty() {
        String leaderGone = """
                  501   501   900 /bin/bash
                  902   900   900 /usr/bin/sort
                """;
        assertEquals(Optional.of(new ForegroundProbe.Foreground(501, "bash")), ForegroundProbe.parsePs(leaderGone, 501));

        String noTty = "  501   501     0 /bin/bash\n  502   501     0 /usr/bin/sleep\n";
        assertEquals(Optional.of(new ForegroundProbe.Foreground(501, "bash")), ForegroundProbe.parsePs(noTty, 501));

        String idle = "  501   501   501 -bash\n";
        assertEquals(Optional.of(new ForegroundProbe.Foreground(501, "bash")), ForegroundProbe.parsePs(idle, 501));
    }

    @Test
    void psRuleKeepsSpacesInCommandPaths() {
        String ps = "  501   501   600 -zsh\n  600   600   600 /Applications/Foo Bar.app/Contents/MacOS/Foo Bar\n";
        assertEquals("foo bar", ForegroundProbe.parsePs(ps, 501).orElseThrow().command());
    }

    @Test
    void psRuleIsEmptyWithoutTheShellRow() {
        assertEquals(Optional.empty(), ForegroundProbe.parsePs("  9   9   9 sh\n", 501));
        assertEquals(Optional.empty(), ForegroundProbe.parsePs("", 501));
        assertEquals(Optional.empty(), ForegroundProbe.parsePs("ps: 501: no such process\n", 501));
    }

    @Test
    void parsesProcStatWithAwkwardNames() {
        assertEquals(Optional.of(new ForegroundProbe.ProcStat(4242, "bash", 4000, 4300)),
                ForegroundProbe.parseStat("4242 (bash) S 4000 4242 4242 34816 4300 4194560 1 2 3\n"));
        assertEquals(Optional.of(new ForegroundProbe.ProcStat(7, "a) b (c", 1, -1)),
                ForegroundProbe.parseStat("7 (a) b (c) R 1 7 7 0 -1 0"));
        assertEquals(Optional.empty(), ForegroundProbe.parseStat(""));
        assertEquals(Optional.empty(), ForegroundProbe.parseStat("7 (x) R 1"));
    }

    @Test
    void procRuleMatchesThePsRule() {
        // The same trees as the ps cases: 501 shell, 777 leader, 778 its child.
        Map<Long, ForegroundProbe.ProcStat> table = new HashMap<>();
        ForegroundProbe.ProcStat shell = new ForegroundProbe.ProcStat(501, "zsh", 1, 777);
        table.put(501L, shell);
        table.put(777L, new ForegroundProbe.ProcStat(777, "node", 501, 777));
        table.put(778L, new ForegroundProbe.ProcStat(778, "git", 777, 777));
        java.util.function.LongFunction<Optional<ForegroundProbe.ProcStat>> stats =
                pid -> Optional.ofNullable(table.get(pid));
        assertEquals(new ForegroundProbe.Foreground(777, "node"), ForegroundProbe.choose(shell, stats));

        // A grandchild leader (sh -c spawning a pipeline) still counts as a descendant.
        ForegroundProbe.ProcStat toGrandchild = new ForegroundProbe.ProcStat(501, "zsh", 1, 778);
        assertEquals(new ForegroundProbe.Foreground(778, "git"), ForegroundProbe.choose(toGrandchild, stats));

        // Leader gone, no tty, idle shell, or a tpgid outside the shell's tree: the shell.
        for (long tpgid : new long[] {900, 0, -1, 501}) {
            assertEquals(new ForegroundProbe.Foreground(501, "zsh"),
                    ForegroundProbe.choose(new ForegroundProbe.ProcStat(501, "-zsh", 1, tpgid), stats));
        }
        table.put(950L, new ForegroundProbe.ProcStat(950, "other", 1, 950));
        assertEquals(new ForegroundProbe.Foreground(501, "zsh"),
                ForegroundProbe.choose(new ForegroundProbe.ProcStat(501, "zsh", 1, 950), stats));
    }

    @Test
    void memoReusesAQuietUnchangedForegroundOnly() {
        long[] now = {0};
        long[] group = {501};
        int[] probes = {0};
        ForegroundProbe.Memo memo = new ForegroundProbe.Memo(true, () -> group[0],
                pid -> new ForegroundProbe.Foreground(pid, "zsh" + probes[0]++), () -> now[0]);
        long s = 1_000_000_000L;
        assertEquals("zsh0", memo.probe(501, 10).command());
        now[0] = 5 * s;
        assertEquals("zsh0", memo.probe(501, 10).command(), "quiet and same group: reused");
        assertEquals("zsh1", memo.probe(501, 11).command(), "output since: re-probed");
        now[0] += s / 2;
        assertEquals("zsh1", memo.probe(501, 12).command(), "younger than FRESH: reused despite output");
        group[0] = 777;
        assertEquals("zsh2", memo.probe(501, 12).command(), "new foreground group: re-probed");
        now[0] += 31 * s;
        assertEquals("zsh3", memo.probe(501, 12).command(), "older than IDLE: re-probed");
        group[0] = -1;
        assertEquals("zsh4", memo.probe(501, 12).command(), "unknown group: never cached");
        assertEquals("zsh5", memo.probe(501, 12).command());

        ForegroundProbe.Memo off = new ForegroundProbe.Memo(false, () -> 501,
                pid -> new ForegroundProbe.Foreground(pid, "p" + probes[0]++), () -> 0);
        assertEquals("p6", off.probe(501, 0).command());
        assertEquals("p7", off.probe(501, 0).command(), "disabled where the probe does not fork");
    }

    @Test
    @EnabledOnOs({OS.MAC, OS.LINUX})
    void ptyReportsItsForegroundGroup() throws IOException {
        Map<String, String> env = new HashMap<>(System.getenv());
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "exec sleep 5"), env,
                Path.of(System.getProperty("java.io.tmpdir")), 80, 24);
        try {
            // setsid makes the child its own group leader and the tty's foreground group.
            Await.until("tcgetpgrp to report pid " + process.pid(),
                    () -> process.foregroundProcessGroup() == process.pid());
        } finally {
            process.destroyForcibly();
        }
    }

    @Test
    @EnabledOnOs({OS.MAC, OS.LINUX})
    void liveSleepUnderAPtyIsTheForeground() throws IOException {
        Map<String, String> env = new HashMap<>(System.getenv());
        env.put("TERM", "xterm-256color");
        PtyProcess process = PtyProcess.start(List.of("/bin/sh", "-c", "exec sleep 5"), env,
                Path.of(System.getProperty("java.io.tmpdir")), 80, 24);
        try {
            Await.until("sleep to be the foreground of pid " + process.pid(),
                    () -> ForegroundProbe.probe(process.pid()).command().equals("sleep"));
            assertTrue(process.isAlive());
        } finally {
            process.destroyForcibly();
        }
    }

    @Test
    void aZombieOrDeadProcessReadsAsExited() {
        assertTrue(ForegroundProbe.exited("4242 (cat) Z 100 4242 100 34816 4242 4194572 0"));
        assertTrue(ForegroundProbe.exited("4242 (my (odd) cmd) X 100 4242"));
        assertFalse(ForegroundProbe.exited("4242 (cat) S 100 4242 100 34816 4242 4194560 0"));
        assertFalse(ForegroundProbe.exited("4242 (Z) R 100 4242 100 34816 4242 4194560 0"));
    }
}
