package io.github.ghosthack.microhm.mux.session;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;
import java.util.function.LongFunction;
import java.util.function.LongSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * The session's foreground command, as tmux's {@code pane_current_command} reports it.
 *
 * <p>Unix: the foreground process is the one among the shell and its descendants whose
 * {@code pid} equals the shell's {@code tpgid} (the leader of the terminal's foreground
 * process group), falling back to the shell itself when none matches (the leader already
 * exited, or the shell has no controlling terminal). Linux reads it all from procfs
 * ({@code /proc/<pid>/stat}: {@code ppid}, {@code tpgid} and {@code comm}, the same fields
 * {@code ps} prints there) and never forks. Elsewhere it is
 * {@code ps -o pid=,pgid=,tpgid=,comm= -p <shell + descendants>}, which forks, so a session
 * probes through a {@link Memo} that reuses the last answer while the terminal's foreground
 * group ({@code tcgetpgrp}, no fork) is unchanged and the session has been quiet.
 *
 * <p>Windows, or when {@code ps} is unavailable: walk from the shell down the chain formed
 * by taking the newest live child at each level, skipping transparent wrappers
 * ({@code cmd}, {@code conhost}) and processes whose name cannot be read, and report the
 * first remaining process; else the shell. Never the leaf: tool children and MCP servers
 * under a harness are newer leaves and would flip the name mid-turn. The walk is written
 * over {@link ProcessNode} so it can be exercised with synthetic trees.
 *
 * <p>Every reported name is the basename (either separator), lower-cased, with a trailing
 * {@code .exe} and a login-shell {@code -} prefix removed.
 */
public final class ForegroundProbe {

    /** Foreground pid and normalized command name; {@code command} is "" when unknown. */
    public record Foreground(long pid, String command) {
    }

    /** A process-tree node: {@code ProcessHandle} in production, a synthetic tree in tests. */
    public interface ProcessNode {
        long pid();

        /** The raw executable name or path ("" when unreadable); normalized by the probe. */
        String command();

        boolean isAlive();

        /** Launch time, used to pick the newest child; {@code Instant.EPOCH} when unknown. */
        Instant startTime();

        List<? extends ProcessNode> children();
    }

    /** Processes the fallback walk looks through rather than at (an npm shim's cmd.exe). */
    static final Set<String> TRANSPARENT = Set.of("cmd", "conhost");

    private static final String OS = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
    private static final boolean WINDOWS = OS.startsWith("windows");
    private static final boolean LINUX = OS.startsWith("linux");
    /** Bound on a parent-chain walk through procfs. */
    private static final int MAX_DEPTH = 4096;

    /** {@code pid pgid tpgid comm}; comm may contain spaces (a path under /Applications). */
    private static final Pattern PS_ROW = Pattern.compile("^\\s*(\\d+)\\s+(\\d+)\\s+(-?\\d+)\\s+(.*?)\\s*$");

    /** The foreground of the session whose shell is {@code shellPid}. Never null; when the
     * shell is gone the command is "" and the pid is the shell's. */
    public static Foreground probe(long shellPid) {
        Optional<ProcessHandle> shell = ProcessHandle.of(shellPid);
        if (shell.isEmpty()) {
            return new Foreground(shellPid, "");
        }
        if (LINUX) {
            Optional<Foreground> viaProc = viaProc(shellPid);
            if (viaProc.isPresent()) {
                return viaProc.get();
            }
        } else if (!WINDOWS) {
            Optional<Foreground> viaPs = viaPs(shell.get());
            if (viaPs.isPresent()) {
                return viaPs.get();
            }
        }
        return walk(HandleNode.of(shell.get()));
    }

    /** Whether {@link #probe} forks on this platform (so a {@link Memo} is worth keeping). */
    static boolean forks() {
        return !LINUX && !WINDOWS;
    }

    /** The fields of one procfs {@code stat} line the probe uses. */
    record ProcStat(long pid, String comm, long ppid, long tpgid) {
    }

    /** Linux: the {@code pid == tpgid} rule over {@code /proc/<pid>/stat}; empty when the
     * shell's own stat is unreadable (then the caller falls back to the tree walk). */
    private static Optional<Foreground> viaProc(long shellPid) {
        return procStat(shellPid).map(shell -> choose(shell, ForegroundProbe::procStat));
    }

    /** The rule over any stat source: the {@code tpgid} process when it is the shell or one
     * of its descendants (its parent chain reaches the shell), else the shell. */
    static Foreground choose(ProcStat shell, LongFunction<Optional<ProcStat>> stats) {
        long tpgid = shell.tpgid();
        if (tpgid > 0 && tpgid != shell.pid()) {
            Optional<ProcStat> leader = stats.apply(tpgid);
            if (leader.isPresent()) {
                long parent = leader.get().ppid();
                for (int i = 0; i < MAX_DEPTH && parent > 0; i++) {
                    if (parent == shell.pid()) {
                        return new Foreground(leader.get().pid(), normalize(leader.get().comm()));
                    }
                    Optional<ProcStat> up = stats.apply(parent);
                    if (up.isEmpty()) {
                        break;
                    }
                    parent = up.get().ppid();
                }
            }
        }
        return new Foreground(shell.pid(), normalize(shell.comm()));
    }

    /** A live process's stat; empty when it is unreadable, or a zombie or dead: a command
     * that just exited stays the terminal's foreground leader until the shell reaps it, and
     * must not read as still running (a caller waiting for the next command would see it). */
    private static Optional<ProcStat> procStat(long pid) {
        try {
            byte[] bytes = Files.readAllBytes(Path.of("/proc", Long.toString(pid), "stat"));
            String stat = new String(bytes, StandardCharsets.UTF_8);
            if (exited(stat)) {
                return Optional.empty();
            }
            return parseStat(stat);
        } catch (IOException | RuntimeException e) {
            return Optional.empty();
        }
    }

    /** True when a stat line's state (the field after the last {@code ')'}) is zombie or dead. */
    static boolean exited(String stat) {
        int close = stat.lastIndexOf(')');
        for (int i = close + 1; i >= 1 && i < stat.length(); i++) {
            char c = stat.charAt(i);
            if (c != ' ') {
                return c == 'Z' || c == 'X' || c == 'x';
            }
        }
        return false;
    }

    /** {@code pid (comm) state ppid pgrp session tty_nr tpgid ...}; comm may hold spaces and
     * parentheses, so it ends at the <em>last</em> {@code ')'}. */
    static Optional<ProcStat> parseStat(String stat) {
        int open = stat.indexOf('(');
        int close = stat.lastIndexOf(')');
        if (open < 0 || close < open) {
            return Optional.empty();
        }
        String[] rest = stat.substring(close + 1).strip().split("\\s+");
        if (rest.length < 6) {
            return Optional.empty();
        }
        try {
            long pid = Long.parseLong(stat.substring(0, open).strip());
            return Optional.of(new ProcStat(pid, stat.substring(open + 1, close),
                    Long.parseLong(rest[1]), Long.parseLong(rest[5])));
        } catch (NumberFormatException e) {
            return Optional.empty();
        }
    }

    private static Optional<Foreground> viaPs(ProcessHandle shell) {
        String pids = Stream.concat(Stream.of(shell), shell.descendants())
                .map(h -> Long.toString(h.pid()))
                .collect(Collectors.joining(","));
        return ProbeCommand.output(List.of("ps", "-o", "pid=,pgid=,tpgid=,comm=", "-p", pids))
                .flatMap(out -> parsePs(out, shell.pid()));
    }

    /** The {@code pid == tpgid} rule over canned or live {@code ps} output; empty when the
     * shell's own row is missing (then the caller falls back to the tree walk). */
    static Optional<Foreground> parsePs(String psOutput, long shellPid) {
        record Row(long pid, long tpgid, String comm) {
        }
        List<Row> rows = new ArrayList<>();
        for (String line : psOutput.split("\\R")) {
            Matcher m = PS_ROW.matcher(line);
            if (m.matches()) {
                rows.add(new Row(Long.parseLong(m.group(1)), Long.parseLong(m.group(3)), m.group(4)));
            }
        }
        Row shell = rows.stream().filter(r -> r.pid() == shellPid).findFirst().orElse(null);
        if (shell == null) {
            return Optional.empty();
        }
        Row foreground = rows.stream().filter(r -> r.pid() == shell.tpgid()).findFirst().orElse(shell);
        return Optional.of(new Foreground(foreground.pid(), normalize(foreground.comm())));
    }

    /** The tree-walk heuristic over any {@link ProcessNode} tree. */
    static Foreground walk(ProcessNode shell) {
        ProcessNode node = shell;
        while (true) {
            ProcessNode child = newestLiveChild(node);
            if (child == null) {
                return new Foreground(shell.pid(), normalize(shell.command()));
            }
            String name = normalize(child.command());
            if (!name.isEmpty() && !TRANSPARENT.contains(name)) {
                return new Foreground(child.pid(), name);
            }
            node = child;
        }
    }

    private static ProcessNode newestLiveChild(ProcessNode node) {
        return node.children().stream()
                .filter(ProcessNode::isAlive)
                .max(Comparator.comparing(ProcessNode::startTime).thenComparingLong(ProcessNode::pid))
                .orElse(null);
    }

    /** Basename, without a login-shell {@code -} prefix, lower-cased, without {@code .exe}. */
    static String normalize(String command) {
        if (command == null) {
            return "";
        }
        String name = command.strip();
        int cut = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
        if (cut >= 0) {
            name = name.substring(cut + 1);
        }
        if (name.startsWith("-")) {
            name = name.substring(1);
        }
        name = name.toLowerCase(Locale.ROOT);
        if (name.endsWith(".exe")) {
            name = name.substring(0, name.length() - 4);
        }
        return name;
    }

    /**
     * A session's probe, for the platforms where {@link #probe} forks ({@code ps} on macOS):
     * the last answer is reused while the terminal's foreground process group is unchanged
     * (read with {@code tcgetpgrp} on the master, no fork) and it is either younger than
     * {@link #FRESH} or the session produced no output since, for up to {@link #IDLE}. A new
     * foreground group (a command started or ended) or output re-probes. Where the probe
     * does not fork, or the group is unknown, every call probes.
     */
    static final class Memo {

        static final Duration FRESH = Duration.ofSeconds(1);
        static final Duration IDLE = Duration.ofSeconds(30);

        private record Entry(long shellPid, long group, long outputBytes, long atNanos, Foreground foreground) {
        }

        private final boolean enabled;
        private final LongSupplier foregroundGroup;
        private final LongFunction<Foreground> probe;
        private final LongSupplier clock;
        private Entry last; // guarded by this

        /** {@code foregroundGroup}: the terminal's foreground process group, -1 when unknown. */
        Memo(LongSupplier foregroundGroup) {
            this(forks(), foregroundGroup, ForegroundProbe::probe, System::nanoTime);
        }

        Memo(boolean enabled, LongSupplier foregroundGroup, LongFunction<Foreground> probe, LongSupplier clock) {
            this.enabled = enabled;
            this.foregroundGroup = foregroundGroup;
            this.probe = probe;
            this.clock = clock;
        }

        /** The foreground of {@code shellPid}; {@code outputBytes} is the session's output
         * counter, whose change means the screen (and maybe the foreground) moved on. */
        synchronized Foreground probe(long shellPid, long outputBytes) {
            if (!enabled) {
                return probe.apply(shellPid);
            }
            long group = foregroundGroup.getAsLong();
            long now = clock.getAsLong();
            Entry e = last;
            if (group > 0 && e != null && e.shellPid() == shellPid && e.group() == group) {
                long age = now - e.atNanos();
                boolean fresh = age < FRESH.toNanos();
                boolean quiet = outputBytes == e.outputBytes() && age < IDLE.toNanos();
                if (age >= 0 && (fresh || quiet)) {
                    return e.foreground();
                }
            }
            Foreground fg = probe.apply(shellPid);
            last = group > 0 ? new Entry(shellPid, group, outputBytes, now, fg) : null;
            return fg;
        }
    }

    /** {@link ProcessNode} over a live {@code ProcessHandle}. */
    private record HandleNode(ProcessHandle handle) implements ProcessNode {

        static HandleNode of(ProcessHandle handle) {
            return new HandleNode(handle);
        }

        @Override
        public long pid() {
            return handle.pid();
        }

        @Override
        public String command() {
            ProcessHandle.Info info = handle.info();
            return info.command().orElseGet(() -> {
                // Without permission to read the command, the first token of the command line
                // (when readable) is the next best thing.
                String[] argv = info.arguments().orElse(null);
                return argv == null || argv.length == 0 ? "" : argv[0];
            });
        }

        @Override
        public boolean isAlive() {
            return handle.isAlive();
        }

        @Override
        public Instant startTime() {
            return handle.info().startInstant().orElse(Instant.EPOCH);
        }

        @Override
        public List<HandleNode> children() {
            return handle.children().map(HandleNode::of).toList();
        }
    }

    private ForegroundProbe() {
    }
}
