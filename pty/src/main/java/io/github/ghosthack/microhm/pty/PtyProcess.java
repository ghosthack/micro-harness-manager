package io.github.ghosthack.microhm.pty;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

/**
 * A child process whose stdin, stdout and stderr are the slave side of a new pseudo-
 * terminal, which is also its controlling terminal; the parent holds the master side.
 * macOS and Linux, through the FFM API — no native helper of its own, no JNA.
 *
 * <p>How the child gets its controlling terminal without running Java code after fork:
 * {@code posix_spawn} with {@code POSIX_SPAWN_SETSID} makes the child a new session
 * leader, and a file action opens the slave <em>by path</em> in the child as fd 0
 * (without {@code O_NOCTTY}). On Linux that is enough: glibc runs {@code setsid} before
 * the file actions, and a session leader with no controlling terminal acquires the first
 * terminal it opens. macOS has BSD semantics — opening a terminal never makes it the
 * controlling one; only {@code ioctl(TIOCSCTTY)} from the session leader does — and
 * {@code posix_spawn} has no action for it, so there the child is first a small JVM
 * running {@link ControllingTerminal}, which issues that ioctl on fd 0 and
 * {@code execve}s the program (same pid). That costs a JVM start per session (tens of
 * milliseconds warm) and needs nothing outside this library. Without it (bash takes the
 * terminal for itself, zsh does not) the shell has no controlling terminal: no job
 * control, no {@code /dev/tty}, and {@code tpgid} — how the foreground program is found
 * — is 0. fds 1 and 2 are dup2'd from 0. On macOS
 * {@code POSIX_SPAWN_CLOEXEC_DEFAULT} closes every other descriptor in the child; on
 * Linux every descriptor this class opens is {@code O_CLOEXEC} and, where glibc has it,
 * {@code addclosefrom_np(3)} closes the rest. The signal mask is emptied and every signal
 * reset to its default disposition, so the child does not inherit the JVM's.
 *
 * <p>The parent opens the slave too ({@code O_NOCTTY}), only long enough to set the
 * initial window size — on macOS {@code TIOCSWINSZ} on a master whose slave was never
 * opened fails with ENOTTY — and closes it right after the spawn, so that output ends
 * (EOF/EIO on the master) once the child and its descendants have closed the terminal.
 *
 * <p>Exit: a daemon reaper thread blocks in {@code waitpid} for this pid only; the exit
 * value is the exit status, or 128 + the signal number when the child was killed by a
 * signal (the shell convention).
 */
public final class PtyProcess {

    /** Windows runs the child in a ConPTY pseudoconsole ({@link ConPty}); everything else here
     * is the POSIX implementation. */
    static final boolean WINDOWS = System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT)
            .startsWith("windows");

    /** The platform half of a PTY: what it does beyond its streams and exit status. */
    interface Terminal {
        /** Columns × rows; IOException once the terminal is closed. */
        void setWinSize(int columns, int rows) throws IOException;

        /** What closing the terminal delivers: SIGHUP, or the console's close event. */
        void hangup();

        /** SIGTERM, or ending the process tree. */
        void terminate();

        /** SIGKILL, or ending the process tree. */
        void kill();

        /** Closes the terminal: output ends, writes fail. Idempotent. */
        void close();

        /** The terminal's foreground process group; -1 when unknown (closed, or no such
         * notion, as on ConPTY). */
        default long foregroundProcessGroup() {
            return -1;
        }
    }

    private final long pid;
    private final Terminal terminal;
    private final InputStream input;
    private final OutputStream output;
    private final CompletableFuture<Integer> exit;

    PtyProcess(long pid, Terminal terminal, InputStream input, OutputStream output, CompletableFuture<Integer> exit) {
        this.pid = pid;
        this.terminal = terminal;
        this.input = input;
        this.output = output;
        this.exit = exit;
    }

    private static PtyProcess unix(int pid, MasterFd master) {
        CompletableFuture<Integer> exit = new CompletableFuture<>();
        PtyProcess process = new PtyProcess(pid, new UnixTerminal(pid, master, exit), master.inputStream(),
                master.outputStream(), exit);
        Thread.ofPlatform().daemon().name("pty-reaper-" + pid).start(() -> reap(pid, exit));
        return process;
    }

    /**
     * Starts {@code command} in a new {@code columns}×{@code rows} PTY.
     *
     * @param command     argv; a program name without '/' is looked up on the PATH from
     *                    {@code environment} (falling back to this process's PATH)
     * @param environment the child's entire environment
     * @param directory   the child's working directory
     */
    public static PtyProcess start(List<String> command, Map<String, String> environment, Path directory,
                                   int columns, int rows) throws IOException {
        if (WINDOWS) {
            return ConPty.start(command, environment, directory, columns, rows);
        }
        Posix.requireSupported();
        Objects.requireNonNull(command, "command");
        if (command.isEmpty()) {
            throw new IllegalArgumentException("empty command");
        }
        Objects.requireNonNull(environment, "environment");
        Objects.requireNonNull(directory, "directory");
        if (!Files.isDirectory(directory)) {
            throw new IOException("not a directory: " + directory);
        }
        String program = resolve(command.get(0), environment);
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            int masterFd = (int) Posix.POSIX_OPENPT.invokeExact(state, Posix.O_RDWR | Posix.O_NOCTTY);
            if (masterFd < 0) {
                throw new IOException("posix_openpt failed: " + Posix.describe(Posix.errno(state)));
            }
            MasterFd master = new MasterFd(masterFd);
            boolean started = false;
            try {
                setCloexec(masterFd);
                check((int) Posix.GRANTPT.invokeExact(state, masterFd), state, "grantpt");
                check((int) Posix.UNLOCKPT.invokeExact(state, masterFd), state, "unlockpt");
                String slave = Posix.slaveName(masterFd);
                MemorySegment slavePath = arena.allocateFrom(slave);
                int slaveFd = (int) Posix.OPEN.invokeExact(state, slavePath,
                        Posix.O_RDWR | Posix.O_NOCTTY | Posix.O_CLOEXEC, 0);
                if (slaveFd < 0) {
                    throw new IOException("opening " + slave + " failed: " + Posix.describe(Posix.errno(state)));
                }
                int pid;
                try {
                    setWinSize(masterFd, columns, rows);
                    pid = spawn(arena, program, command, environment, directory, slavePath);
                } finally {
                    int ignored = (int) Posix.CLOSE.invokeExact(state, slaveFd);
                }
                started = true;
                return unix(pid, master);
            } finally {
                if (!started) {
                    master.close();
                }
            }
        } catch (IOException e) {
            throw e;
        } catch (Throwable t) {
            throw new IOException("starting " + command.get(0) + " in a PTY failed", t);
        }
    }

    private static int spawn(Arena arena, String program, List<String> command, Map<String, String> environment,
                             Path directory, MemorySegment slavePath) throws Throwable {
        MemorySegment actions = arena.allocate(Posix.SPAWN_STRUCT_BYTES);
        MemorySegment attr = arena.allocate(Posix.SPAWN_STRUCT_BYTES);
        int rc = (int) Posix.FILE_ACTIONS_INIT.invokeExact(actions);
        checkSpawn(rc, "posix_spawn_file_actions_init");
        try {
            rc = (int) Posix.ATTR_INIT.invokeExact(attr);
            checkSpawn(rc, "posix_spawnattr_init");
            try {
                List<String> argv = command;
                Map<String, String> spawnEnvironment = environment;
                if (Posix.MAC) {
                    Trampoline trampoline = macTrampoline(program, command, environment);
                    program = trampoline.argv().get(0);
                    argv = trampoline.argv();
                    spawnEnvironment = trampoline.environment();
                }
                if (Posix.FILE_ACTIONS_ADDCHDIR.isPresent()) {
                    rc = (int) Posix.FILE_ACTIONS_ADDCHDIR.get().invokeExact(actions,
                            arena.allocateFrom(directory.toString()));
                    checkSpawn(rc, "posix_spawn_file_actions_addchdir");
                } else {
                    // No chdir file action in this libc: let a POSIX shell change directory
                    // and exec the program, which keeps the same pid.
                    List<String> wrapped = new ArrayList<>(List.of("/bin/sh", "-c", "cd \"$0\" && exec \"$@\"",
                            directory.toString(), program));
                    wrapped.addAll(command.subList(1, command.size()));
                    argv = wrapped;
                    program = "/bin/sh";
                }
                rc = (int) Posix.FILE_ACTIONS_ADDOPEN.invokeExact(actions, 0, slavePath, Posix.O_RDWR, (short) 0);
                checkSpawn(rc, "posix_spawn_file_actions_addopen");
                rc = (int) Posix.FILE_ACTIONS_ADDDUP2.invokeExact(actions, 0, 1);
                checkSpawn(rc, "posix_spawn_file_actions_adddup2");
                rc = (int) Posix.FILE_ACTIONS_ADDDUP2.invokeExact(actions, 0, 2);
                checkSpawn(rc, "posix_spawn_file_actions_adddup2");
                if (Posix.LINUX && Posix.FILE_ACTIONS_ADDCLOSEFROM.isPresent()) {
                    rc = (int) Posix.FILE_ACTIONS_ADDCLOSEFROM.get().invokeExact(actions, 3);
                    checkSpawn(rc, "posix_spawn_file_actions_addclosefrom_np");
                }

                MemorySegment empty = arena.allocate(Posix.SIGSET_BYTES);
                MemorySegment all = arena.allocate(Posix.SIGSET_BYTES);
                int ignored = (int) Posix.SIGEMPTYSET.invokeExact(empty);
                ignored = (int) Posix.SIGFILLSET.invokeExact(all);
                checkSpawn((int) Posix.ATTR_SETSIGMASK.invokeExact(attr, empty), "posix_spawnattr_setsigmask");
                checkSpawn((int) Posix.ATTR_SETSIGDEFAULT.invokeExact(attr, all), "posix_spawnattr_setsigdefault");
                short flags = (short) (Posix.POSIX_SPAWN_SETSID | Posix.POSIX_SPAWN_SETSIGMASK
                        | Posix.POSIX_SPAWN_SETSIGDEF | (Posix.MAC ? Posix.POSIX_SPAWN_CLOEXEC_DEFAULT : 0));
                checkSpawn((int) Posix.ATTR_SETFLAGS.invokeExact(attr, flags), "posix_spawnattr_setflags");

                MemorySegment argvSegment = stringArray(arena, argv);
                List<String> envp = new ArrayList<>(spawnEnvironment.size());
                spawnEnvironment.forEach((k, v) -> envp.add(k + "=" + v));
                MemorySegment envSegment = stringArray(arena, envp);
                MemorySegment pidOut = arena.allocate(JAVA_INT);
                rc = (int) Posix.POSIX_SPAWN.invokeExact(pidOut, arena.allocateFrom(program), actions, attr,
                        argvSegment, envSegment);
                if (rc != 0) {
                    throw new IOException("cannot run " + program + ": " + Posix.describe(rc));
                }
                return pidOut.get(JAVA_INT, 0);
            } finally {
                int ignored = (int) Posix.ATTR_DESTROY.invokeExact(attr);
            }
        } finally {
            int ignored = (int) Posix.FILE_ACTIONS_DESTROY.invokeExact(actions);
        }
    }

    public long pid() {
        return pid;
    }

    /** The terminal's output. Ends (-1) once every holder of the slave side closed it. */
    public InputStream getInputStream() {
        return input;
    }

    /** Typing into the terminal. Throws once the master is closed. */
    public OutputStream getOutputStream() {
        return output;
    }

    /** Sets the terminal size (SIGWINCH to the foreground group; ConPTY resizes its buffer). */
    public void setWinSize(int columns, int rows) throws IOException {
        terminal.setWinSize(columns, rows);
    }

    public boolean isAlive() {
        return !exit.isDone();
    }

    /** Blocks until the child exits; returns its exit value. */
    public int waitFor() throws InterruptedException {
        try {
            return exit.get();
        } catch (ExecutionException e) {
            throw new IllegalStateException(e.getCause());
        }
    }

    /** Waits up to {@code timeout}; returns whether the child exited. */
    public boolean waitFor(long timeout, TimeUnit unit) throws InterruptedException {
        try {
            exit.get(timeout, unit);
            return true;
        } catch (TimeoutException e) {
            return false;
        } catch (ExecutionException e) {
            throw new IllegalStateException(e.getCause());
        }
    }

    /** The exit value; throws {@link IllegalThreadStateException} while running. */
    public int exitValue() {
        Integer value = exit.getNow(null);
        if (value == null) {
            throw new IllegalThreadStateException("process " + pid + " is still running");
        }
        return value;
    }

    /** A future completed with the exit value. */
    public CompletableFuture<Integer> onExit() {
        return exit.copy();
    }

    /** SIGHUP, what closing a terminal delivers: interactive shells exit on it (they ignore
     * SIGTERM) and forward it to their jobs. */
    public void hangup() {
        terminal.hangup();
    }

    /** SIGTERM. */
    public void destroy() {
        terminal.terminate();
    }

    /** SIGKILL. */
    public void destroyForcibly() {
        terminal.kill();
    }

    /** Closes the master side. Output ends; further writes fail. Idempotent. */
    public void closeTerminal() {
        terminal.close();
    }

    /** The terminal's foreground process group id ({@code tcgetpgrp} on the master, no
     * fork); -1 when unknown: the terminal is closed, no process has it as its controlling
     * terminal yet, or on Windows. */
    public long foregroundProcessGroup() {
        return terminal.foregroundProcessGroup();
    }

    /** The POSIX terminal: the master descriptor and signals to the child. */
    private record UnixTerminal(int pid, MasterFd master, CompletableFuture<Integer> exit) implements Terminal {

        @Override
        public void setWinSize(int columns, int rows) throws IOException {
            IOException[] failure = new IOException[1];
            boolean live = master.with(fd -> {
                try {
                    PtyProcess.setWinSize(fd, columns, rows);
                    return true;
                } catch (IOException e) {
                    failure[0] = e;
                    return false;
                }
            });
            if (failure[0] != null) {
                throw failure[0];
            }
            if (!live) {
                throw new IOException("the PTY is closed");
            }
        }

        @Override
        public void hangup() {
            signal(Posix.SIGHUP);
        }

        @Override
        public void terminate() {
            signal(Posix.SIGTERM);
        }

        @Override
        public void kill() {
            signal(Posix.SIGKILL);
        }

        @Override
        public void close() {
            master.close();
        }

        @Override
        public long foregroundProcessGroup() {
            long[] group = {-1};
            master.with(fd -> {
                try (Arena arena = Arena.ofConfined()) {
                    group[0] = (int) Posix.TCGETPGRP.invokeExact(Posix.callState(arena), fd);
                } catch (Throwable ignored) {
                    // Unknown; the caller falls back to its slower strategy.
                }
                return true;
            });
            return group[0] > 0 ? group[0] : -1;
        }

        private void signal(int signal) {
            if (exit.isDone()) {
                return; // never signal a pid that may already have been reused
            }
            try (Arena arena = Arena.ofConfined()) {
                int ignored = (int) Posix.KILL.invokeExact(Posix.callState(arena), pid, signal);
            } catch (Throwable ignored) {
                // The process is gone, or cannot be signalled; the reaper reports the exit.
            }
        }
    }

    private static void reap(int pid, CompletableFuture<Integer> exit) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            MemorySegment status = arena.allocate(JAVA_INT);
            while (true) {
                int rc = (int) Posix.WAITPID.invokeExact(state, pid, status, 0);
                if (rc == pid) {
                    exit.complete(decode(status.get(JAVA_INT, 0)));
                    return;
                }
                int errno = Posix.errno(state);
                if (rc < 0 && errno == Posix.EINTR) {
                    continue;
                }
                // ECHILD: someone else reaped it; the exit status is lost.
                exit.complete(-1);
                return;
            }
        } catch (Throwable t) {
            exit.complete(-1);
        }
    }

    /** {@code WIFEXITED → WEXITSTATUS}, {@code WIFSIGNALED → 128 + WTERMSIG}. */
    static int decode(int status) {
        int signal = status & 0x7f;
        if (signal == 0) {
            return (status >> 8) & 0xff;
        }
        return 128 + signal;
    }

    private static void setWinSize(int fd, int columns, int rows) throws IOException {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment winsize = arena.allocate(8);
            winsize.set(JAVA_SHORT, 0, (short) Math.clamp(rows, 1, Short.MAX_VALUE));
            winsize.set(JAVA_SHORT, 2, (short) Math.clamp(columns, 1, Short.MAX_VALUE));
            MemorySegment state = Posix.callState(arena);
            int rc = (int) Posix.IOCTL.invokeExact(state, fd, Posix.TIOCSWINSZ, winsize);
            if (rc != 0) {
                throw new IOException("TIOCSWINSZ failed: " + Posix.describe(Posix.errno(state)));
            }
        } catch (IOException e) {
            throw e;
        } catch (Throwable t) {
            throw new IOException("TIOCSWINSZ failed", t);
        }
    }

    /** {@code posix_openpt} has no O_CLOEXEC flag on macOS: set FD_CLOEXEC with fcntl. */
    private static void setCloexec(int fd) throws Throwable {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            int rc = (int) Posix.FCNTL.invokeExact(state, fd, Posix.F_SETFD, Posix.FD_CLOEXEC);
            check(rc, state, "fcntl(FD_CLOEXEC)");
        }
    }

    private static MemorySegment stringArray(Arena arena, List<String> strings) {
        MemorySegment array = arena.allocate(ADDRESS, strings.size() + 1L);
        for (int i = 0; i < strings.size(); i++) {
            array.setAtIndex(ADDRESS, i, arena.allocateFrom(strings.get(i)));
        }
        array.setAtIndex(ADDRESS, strings.size(), MemorySegment.NULL);
        return array;
    }

    /** {@code program} as given when it contains '/', else the first executable match on
     * the child's PATH (or ours); unresolved names are returned as is and fail at spawn. */
    /** What the spawn runs instead of the program on macOS, and with which environment. */
    record Trampoline(List<String> argv, Map<String, String> environment) {
    }

    /** Fast-starting options for a JVM that lives a few tens of milliseconds. */
    private static final List<String> TRAMPOLINE_JVM_OPTIONS = List.of("-Xrs", "-XX:+UseSerialGC",
            "-XX:TieredStopAtLevel=1", "-XX:-UsePerfData", "-Xshare:auto", "-Xmx32m",
            "--enable-native-access=ALL-UNNAMED");

    /**
     * macOS: runs {@code program} (with {@code command}'s arguments and {@code argv[0]})
     * through {@link ControllingTerminal}, on this JVM's own {@code java} and the class
     * path this class was loaded from. The program is checked here, since the trampoline
     * would only fail after starting. Every variable name goes along as {@code --keep}, and
     * the JVM options variables move from the environment into {@code --env} arguments;
     * see {@link ControllingTerminal}.
     */
    static Trampoline macTrampoline(String program, List<String> command, Map<String, String> environment)
            throws IOException {
        Path resolved = Path.of(program);
        if (!resolved.isAbsolute() || !Files.isRegularFile(resolved) || !Files.isExecutable(resolved)) {
            throw new IOException("cannot run " + program + ": not an executable file");
        }
        Path java = Path.of(System.getProperty("java.home"), "bin", "java");
        if (!Files.isExecutable(java)) {
            throw new IOException("cannot give " + program + " a controlling terminal: no " + java);
        }
        String classPath;
        try {
            classPath = Path.of(ControllingTerminal.class.getProtectionDomain().getCodeSource().getLocation().toURI())
                    .toString();
        } catch (java.net.URISyntaxException | RuntimeException e) {
            throw new IOException("cannot locate the PTY classes for the terminal trampoline", e);
        }
        List<String> argv = new ArrayList<>();
        argv.add(java.toString());
        argv.addAll(TRAMPOLINE_JVM_OPTIONS);
        argv.addAll(List.of("-cp", classPath, ControllingTerminal.class.getName()));
        Map<String, String> jvmEnvironment = new java.util.LinkedHashMap<>(environment);
        for (String name : environment.keySet()) {
            if (!ControllingTerminal.JVM_OPTION_VARIABLES.contains(name)) {
                argv.add("--keep");
                argv.add(name);
            }
        }
        for (String name : ControllingTerminal.JVM_OPTION_VARIABLES) {
            String value = jvmEnvironment.remove(name);
            if (value != null) {
                argv.add("--env");
                argv.add(name + "=" + value);
            }
        }
        argv.add("--");
        argv.add(program);
        argv.addAll(command);
        return new Trampoline(List.copyOf(argv), jvmEnvironment);
    }

    static String resolve(String program, Map<String, String> environment) {
        if (program.indexOf('/') >= 0) {
            return program;
        }
        String path = environment.getOrDefault("PATH", System.getenv("PATH"));
        if (path != null) {
            for (String dir : path.split(":")) {
                if (dir.isEmpty()) {
                    continue;
                }
                Path candidate = Path.of(dir, program);
                if (Files.isRegularFile(candidate) && Files.isExecutable(candidate)) {
                    return candidate.toString();
                }
            }
        }
        return program;
    }

    private static void check(int rc, MemorySegment state, String what) throws IOException {
        if (rc != 0) {
            throw new IOException(what + " failed: " + Posix.describe(Posix.errno(state)));
        }
    }

    private static void checkSpawn(int rc, String what) throws IOException {
        if (rc != 0) {
            throw new IOException(what + " failed: " + Posix.describe(rc));
        }
    }

    @Override
    public String toString() {
        return "PtyProcess[pid " + pid + (exit.isDone() ? ", exited " + exit.getNow(null) : "") + "]";
    }
}
