package io.github.ghosthack.microhm.pty;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicBoolean;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;

/**
 * Windows: a child process in a ConPTY pseudoconsole (Windows 10 1809+), through the FFM API.
 *
 * <p>Two anonymous pipes carry input and output; {@code CreatePseudoConsole} takes their
 * child ends, which this side then closes. The child is created suspended with
 * {@code PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE}, {@code STARTF_USESTDHANDLES} with no
 * handles (so it attaches to the pseudoconsole, never to this process's own redirected
 * stdio) and no inherited handles, joins a job object that kills the whole tree when the
 * job is closed, and only then runs.
 *
 * <p>Lifecycle: {@link #hangup} closes the pseudoconsole, which sends every attached
 * process the console's close event (what closing a terminal window does). Output ends
 * when the pseudoconsole closes; since conhost would otherwise keep it open after the
 * child exits, the reaper closes it once the child is gone, after which the remaining
 * output drains and the stream reports end of output. {@code ClosePseudoConsole} can wait
 * for that output to be read, so it always runs on its own thread.
 *
 * <p>Ctrl+C: "ignore Ctrl+C" is a process attribute every child inherits, and launchers
 * such as Windows OpenSSH set it, so a program in the pseudoconsole would ignore the
 * Ctrl+C typed at it. Before the first child, this process restores normal Ctrl+C
 * processing for itself ({@code SetConsoleCtrlHandler(NULL, FALSE)}), which its children
 * then inherit; the JVM's own Ctrl+C handler is a separate, registered handler and is
 * unaffected.
 */
final class ConPty {

    private static final Object CTRL_C_ONCE = new Object();
    private static boolean ctrlCRestored;

    private ConPty() {
    }

    private static void restoreCtrlC() {
        synchronized (CTRL_C_ONCE) {
            if (ctrlCRestored) {
                return;
            }
            ctrlCRestored = true;
            try (Arena arena = Arena.ofConfined()) {
                int ignored = (int) Win32.SET_CONSOLE_CTRL_HANDLER.invokeExact(Win32.callState(arena),
                        MemorySegment.NULL, 0);
            } catch (Throwable ignored) {
                // children then keep whatever this process inherited
            }
        }
    }

    static PtyProcess start(List<String> command, Map<String, String> environment, Path directory,
                            int columns, int rows) throws IOException {
        Objects.requireNonNull(command, "command");
        if (command.isEmpty()) {
            throw new IllegalArgumentException("empty command");
        }
        Objects.requireNonNull(environment, "environment");
        Objects.requireNonNull(directory, "directory");
        if (!Files.isDirectory(directory)) {
            throw new IOException("not a directory: " + directory);
        }
        restoreCtrlC();
        String program = resolve(command.get(0), environment);
        String applicationName = program;
        String commandLine = commandLine(program, command.subList(1, command.size()));
        String lower = program.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".cmd") || lower.endsWith(".bat")) {
            // A batch file runs through cmd.exe; /s makes it keep the inner quoting intact.
            String comspec = getIgnoreCase(environment, "ComSpec");
            applicationName = comspec == null ? "C:\\Windows\\System32\\cmd.exe" : comspec;
            commandLine = quote(applicationName) + " /d /s /c \"" + commandLine + "\"";
        }

        MemorySegment inRead = MemorySegment.NULL;
        MemorySegment inWrite = MemorySegment.NULL;
        MemorySegment outRead = MemorySegment.NULL;
        MemorySegment outWrite = MemorySegment.NULL;
        MemorySegment console = MemorySegment.NULL;
        MemorySegment job = MemorySegment.NULL;
        boolean started = false;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Win32.callState(arena);
            MemorySegment pair = arena.allocate(ADDRESS, 2);
            check((int) Win32.CREATE_PIPE.invokeExact(state, pair, pair.asSlice(ADDRESS.byteSize()),
                    MemorySegment.NULL, 0), state, "CreatePipe (input)");
            inRead = pair.getAtIndex(ADDRESS, 0);
            inWrite = pair.getAtIndex(ADDRESS, 1);
            check((int) Win32.CREATE_PIPE.invokeExact(state, pair, pair.asSlice(ADDRESS.byteSize()),
                    MemorySegment.NULL, 0), state, "CreatePipe (output)");
            outRead = pair.getAtIndex(ADDRESS, 0);
            outWrite = pair.getAtIndex(ADDRESS, 1);

            MemorySegment consoleOut = arena.allocate(ADDRESS);
            int hr = (int) Win32.CREATE_PSEUDO_CONSOLE.invokeExact(Win32.coord(arena, columns, rows), inRead,
                    outWrite, 0, consoleOut);
            if (hr != 0) {
                throw new IOException("CreatePseudoConsole failed: HRESULT 0x" + Integer.toHexString(hr));
            }
            console = consoleOut.get(ADDRESS, 0);
            // The pseudoconsole holds its own copies of the child ends.
            Win32.closeHandle(inRead);
            inRead = MemorySegment.NULL;
            Win32.closeHandle(outWrite);
            outWrite = MemorySegment.NULL;

            MemorySegment size = arena.allocate(JAVA_LONG);
            int ignored = (int) Win32.INITIALIZE_ATTRIBUTE_LIST.invokeExact(state, MemorySegment.NULL, 1, 0, size);
            MemorySegment attributes = arena.allocate(size.get(JAVA_LONG, 0), 8);
            check((int) Win32.INITIALIZE_ATTRIBUTE_LIST.invokeExact(state, attributes, 1, 0, size), state,
                    "InitializeProcThreadAttributeList");
            MemorySegment processInfo;
            try {
                check((int) Win32.UPDATE_ATTRIBUTE.invokeExact(state, attributes, 0,
                        Win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console, ADDRESS.byteSize(),
                        MemorySegment.NULL, MemorySegment.NULL), state, "UpdateProcThreadAttribute");
                MemorySegment startup = arena.allocate(Win32.STARTUPINFOEX_BYTES, 8);
                startup.set(JAVA_INT, 0, (int) Win32.STARTUPINFOEX_BYTES);
                startup.set(JAVA_INT, Win32.STARTUPINFO_FLAGS_OFFSET, Win32.STARTF_USESTDHANDLES);
                startup.set(ADDRESS, Win32.STARTUPINFO_ATTRIBUTES_OFFSET, attributes);
                processInfo = arena.allocate(Win32.PROCESS_INFORMATION_BYTES, 8);
                int flags = Win32.EXTENDED_STARTUPINFO_PRESENT | Win32.CREATE_UNICODE_ENVIRONMENT
                        | Win32.CREATE_SUSPENDED;
                int ok = (int) Win32.CREATE_PROCESS.invokeExact(state, wide(arena, applicationName),
                        wide(arena, commandLine), MemorySegment.NULL, MemorySegment.NULL, 0, flags,
                        environmentBlock(arena, environment), wide(arena, directory.toAbsolutePath().toString()),
                        startup, processInfo);
                if (ok == 0) {
                    throw new IOException("cannot run " + program + ": " + describe(Win32.lastError(state)));
                }
            } finally {
                Win32.DELETE_ATTRIBUTE_LIST.invokeExact(attributes);
            }
            MemorySegment process = processInfo.get(ADDRESS, 0);
            MemorySegment thread = processInfo.get(ADDRESS, 8);
            long pid = Integer.toUnsignedLong(processInfo.get(JAVA_INT, 16));

            job = (MemorySegment) Win32.CREATE_JOB.invokeExact(state, MemorySegment.NULL, MemorySegment.NULL);
            if (job.address() != 0) {
                MemorySegment limits = arena.allocate(Win32.JOB_LIMIT_BYTES, 8);
                limits.set(JAVA_INT, Win32.JOB_LIMIT_FLAGS_OFFSET, Win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE);
                ignored = (int) Win32.SET_JOB_INFORMATION.invokeExact(state, job,
                        Win32.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, limits, (int) Win32.JOB_LIMIT_BYTES);
                ignored = (int) Win32.ASSIGN_TO_JOB.invokeExact(state, job, process);
            }
            ignored = (int) Win32.RESUME_THREAD.invokeExact(state, thread);
            Win32.closeHandle(thread);

            CompletableFuture<Integer> exit = new CompletableFuture<>();
            Pipe input = new Pipe(outRead);
            Pipe output = new Pipe(inWrite);
            Console terminal = new Console(console, job, process, input, output, exit);
            started = true;
            Thread.ofPlatform().daemon().name("conpty-reaper-" + pid).start(terminal::reap);
            return new PtyProcess(pid, terminal, input.inputStream(), output.outputStream(), exit);
        } catch (IOException e) {
            throw e;
        } catch (Throwable t) {
            throw new IOException("starting " + command.get(0) + " in a pseudoconsole failed", t);
        } finally {
            if (!started) {
                Win32.closeHandle(inRead);
                Win32.closeHandle(inWrite);
                Win32.closeHandle(outRead);
                Win32.closeHandle(outWrite);
                if (console.address() != 0) {
                    closeConsoleAsync(console);
                }
                Win32.closeHandle(job);
            }
        }
    }

    // =====================================================================================
    // The terminal half
    // =====================================================================================

    /** The pseudoconsole, the job and the process handle; the pipes for {@link #close}. */
    private static final class Console implements PtyProcess.Terminal {
        private final MemorySegment console;
        private final MemorySegment job;
        private final MemorySegment process;
        private final Pipe input;
        private final Pipe output;
        private final CompletableFuture<Integer> exit;
        private final AtomicBoolean consoleClosed = new AtomicBoolean();
        private final AtomicBoolean closed = new AtomicBoolean();

        Console(MemorySegment console, MemorySegment job, MemorySegment process, Pipe input, Pipe output,
                CompletableFuture<Integer> exit) {
            this.console = console;
            this.job = job;
            this.process = process;
            this.input = input;
            this.output = output;
            this.exit = exit;
        }

        @Override
        public void setWinSize(int columns, int rows) throws IOException {
            if (consoleClosed.get()) {
                throw new IOException("the pseudoconsole is closed");
            }
            try (Arena arena = Arena.ofConfined()) {
                int hr = (int) Win32.RESIZE_PSEUDO_CONSOLE.invokeExact(console, Win32.coord(arena, columns, rows));
                if (hr != 0) {
                    throw new IOException("ResizePseudoConsole failed: HRESULT 0x" + Integer.toHexString(hr));
                }
            } catch (IOException e) {
                throw e;
            } catch (Throwable t) {
                throw new IOException("ResizePseudoConsole failed", t);
            }
        }

        @Override
        public void hangup() {
            closeConsole();
        }

        @Override
        public void terminate() {
            terminateJob();
        }

        @Override
        public void kill() {
            terminateJob();
        }

        @Override
        public void close() {
            if (!closed.compareAndSet(false, true)) {
                return;
            }
            output.close();
            closeConsole();
            input.close();
        }

        private void closeConsole() {
            if (consoleClosed.compareAndSet(false, true)) {
                closeConsoleAsync(console);
            }
        }

        private void terminateJob() {
            if (exit.isDone() || job.address() == 0) {
                return;
            }
            try (Arena arena = Arena.ofConfined()) {
                int ignored = (int) Win32.TERMINATE_JOB.invokeExact(Win32.callState(arena), job, 1);
            } catch (Throwable ignored) {
                // Already gone; the reaper reports the exit.
            }
        }

        /** Waits for the child, reports its exit code, then closes the pseudoconsole so the
         * rest of the output drains and the stream ends. */
        void reap() {
            int code = -1;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment state = Win32.callState(arena);
                int ignored = (int) Win32.WAIT_FOR_SINGLE_OBJECT.invokeExact(state, process, Win32.INFINITE);
                MemorySegment status = arena.allocate(JAVA_INT);
                if ((int) Win32.GET_EXIT_CODE_PROCESS.invokeExact(state, process, status) != 0) {
                    code = status.get(JAVA_INT, 0);
                }
            } catch (Throwable ignored) {
                // the exit status is lost
            } finally {
                Win32.closeHandle(process);
                exit.complete(code);
                closeConsole();
            }
            // The job stays open until the child is gone, so it can end the tree; closing it
            // now ends any descendant the console close left behind.
            Win32.closeHandle(job);
        }
    }

    private static void closeConsoleAsync(MemorySegment console) {
        Thread.ofPlatform().daemon().name("conpty-close").start(() -> {
            try {
                Win32.CLOSE_PSEUDO_CONSOLE.invokeExact(console);
            } catch (Throwable ignored) {
                // nothing more to close
            }
        });
    }

    // =====================================================================================
    // Pipes
    // =====================================================================================

    /**
     * One end of an anonymous pipe, closed exactly once and never used after: handle values
     * are reused like file descriptors. Operations register as in flight; {@link #close}
     * releases the handle once none is. A blocked read ends when the pseudoconsole closes
     * (the other end goes away), so a close never waits on it for long.
     */
    private static final class Pipe {
        private final MemorySegment handle;
        private final Object lock = new Object();
        private int inFlight;
        private boolean closing;
        private boolean released;

        Pipe(MemorySegment handle) {
            this.handle = handle;
        }

        private boolean enter() {
            synchronized (lock) {
                if (closing) {
                    return false;
                }
                inFlight++;
                return true;
            }
        }

        private void exit() {
            synchronized (lock) {
                inFlight--;
                if (inFlight == 0 && closing) {
                    release();
                }
            }
        }

        void close() {
            synchronized (lock) {
                if (closing) {
                    return;
                }
                closing = true;
                if (inFlight == 0) {
                    release();
                }
            }
        }

        private void release() {
            if (!released) {
                released = true;
                Win32.closeHandle(handle);
            }
        }

        int read(byte[] buffer, int offset, int length) throws IOException {
            if (length == 0) {
                return 0;
            }
            if (!enter()) {
                return -1;
            }
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment state = Win32.callState(arena);
                MemorySegment data = arena.allocate(length);
                MemorySegment count = arena.allocate(JAVA_INT);
                int ok = (int) Win32.READ_FILE.invokeExact(state, handle, data, length, count, MemorySegment.NULL);
                if (ok == 0) {
                    int error = Win32.lastError(state);
                    if (error == Win32.ERROR_BROKEN_PIPE) {
                        return -1;
                    }
                    throw new IOException("reading the pseudoconsole failed: " + describe(error));
                }
                int n = count.get(JAVA_INT, 0);
                if (n == 0) {
                    return -1;
                }
                MemorySegment.copy(data, java.lang.foreign.ValueLayout.JAVA_BYTE, 0, buffer, offset, n);
                return n;
            } catch (IOException e) {
                throw e;
            } catch (Throwable t) {
                throw new IOException("reading the pseudoconsole failed", t);
            } finally {
                exit();
            }
        }

        void write(byte[] buffer, int offset, int length) throws IOException {
            if (length == 0) {
                return;
            }
            if (!enter()) {
                throw new IOException("the pseudoconsole is closed");
            }
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment state = Win32.callState(arena);
                MemorySegment data = arena.allocate(length);
                MemorySegment.copy(buffer, offset, data, java.lang.foreign.ValueLayout.JAVA_BYTE, 0, length);
                MemorySegment count = arena.allocate(JAVA_INT);
                long written = 0;
                while (written < length) {
                    int ok = (int) Win32.WRITE_FILE.invokeExact(state, handle, data.asSlice(written),
                            (int) (length - written), count, MemorySegment.NULL);
                    if (ok == 0) {
                        throw new IOException("writing the pseudoconsole failed: " + describe(Win32.lastError(state)));
                    }
                    written += count.get(JAVA_INT, 0);
                }
            } catch (IOException e) {
                throw e;
            } catch (Throwable t) {
                throw new IOException("writing the pseudoconsole failed", t);
            } finally {
                exit();
            }
        }

        InputStream inputStream() {
            return new InputStream() {
                @Override
                public int read() throws IOException {
                    byte[] one = new byte[1];
                    int n = read(one, 0, 1);
                    return n < 0 ? -1 : one[0] & 0xff;
                }

                @Override
                public int read(byte[] b, int off, int len) throws IOException {
                    Objects.checkFromIndexSize(off, len, b.length);
                    return Pipe.this.read(b, off, len);
                }
            };
        }

        OutputStream outputStream() {
            return new OutputStream() {
                @Override
                public void write(int b) throws IOException {
                    Pipe.this.write(new byte[]{(byte) b}, 0, 1);
                }

                @Override
                public void write(byte[] b, int off, int len) throws IOException {
                    Objects.checkFromIndexSize(off, len, b.length);
                    Pipe.this.write(b, off, len);
                }
            };
        }
    }

    // =====================================================================================
    // Command line, environment, program lookup
    // =====================================================================================

    /** The program (quoted) and its arguments, quoted as the C runtime parses them back. */
    static String commandLine(String program, List<String> arguments) {
        StringBuilder sb = new StringBuilder(quote(program));
        for (String argument : arguments) {
            sb.append(' ').append(quote(argument));
        }
        return sb.toString();
    }

    /** One argument as {@code CommandLineToArgvW} / the C runtime split it: quoted when it
     * holds whitespace or a quote (or is empty), backslashes doubled only before a quote. */
    static String quote(String argument) {
        if (!argument.isEmpty() && argument.chars().noneMatch(c -> c == ' ' || c == '\t' || c == '\n'
                || c == 0x0B || c == '"')) {
            return argument;
        }
        StringBuilder sb = new StringBuilder("\"");
        int backslashes = 0;
        for (int i = 0; i < argument.length(); i++) {
            char c = argument.charAt(i);
            if (c == '\\') {
                backslashes++;
                continue;
            }
            if (c == '"') {
                sb.append("\\".repeat(backslashes * 2 + 1)).append('"');
            } else {
                sb.append("\\".repeat(backslashes)).append(c);
            }
            backslashes = 0;
        }
        sb.append("\\".repeat(backslashes * 2)).append('"');
        return sb.toString();
    }

    /** {@code NAME=value\0...\0\0} in UTF-16, sorted case-insensitively as Windows keeps it. */
    private static MemorySegment environmentBlock(Arena arena, Map<String, String> environment) {
        TreeMap<String, String> sorted = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        sorted.putAll(environment);
        StringBuilder sb = new StringBuilder();
        sorted.forEach((name, value) -> sb.append(name).append('=').append(value).append('\0'));
        if (sorted.isEmpty()) {
            sb.append('\0');
        }
        // allocateFrom adds one more NUL: the block's terminating empty string
        return arena.allocateFrom(sb.toString(), StandardCharsets.UTF_16LE);
    }

    private static MemorySegment wide(Arena arena, String s) {
        return arena.allocateFrom(s, StandardCharsets.UTF_16LE);
    }

    /**
     * The executable for {@code program}: as given when it names a path, else the first
     * match on the child's {@code PATH}, trying each {@code PATHEXT} extension when it has
     * none (CreateProcess would search this process's PATH, not the child's). Throws when
     * nothing matches, so a missing program fails at start.
     */
    static String resolve(String program, Map<String, String> environment) throws IOException {
        List<String> extensions = new ArrayList<>();
        String pathext = getIgnoreCase(environment, "PATHEXT");
        for (String ext : (pathext == null || pathext.isBlank() ? ".COM;.EXE;.BAT;.CMD" : pathext).split(";")) {
            if (!ext.isBlank()) {
                extensions.add(ext.trim());
            }
        }
        boolean hasExtension = program.lastIndexOf('.') > Math.max(program.lastIndexOf('\\'), program.lastIndexOf('/'));
        List<Path> candidates = new ArrayList<>();
        if (program.contains("\\") || program.contains("/") || program.contains(":")) {
            candidates.add(Path.of(program));
        } else {
            String path = getIgnoreCase(environment, "PATH");
            if (path == null) {
                path = System.getenv("PATH");
            }
            for (String dir : path == null ? new String[0] : path.split(";")) {
                if (!dir.isBlank()) {
                    candidates.add(Path.of(dir.trim(), program));
                }
            }
        }
        for (Path candidate : candidates) {
            if (hasExtension && Files.isRegularFile(candidate)) {
                return candidate.toString();
            }
            for (String ext : extensions) {
                Path withExtension = Path.of(candidate + ext);
                if (Files.isRegularFile(withExtension)) {
                    return withExtension.toString();
                }
            }
        }
        throw new IOException("cannot run " + program + ": not found");
    }

    static String getIgnoreCase(Map<String, String> map, String key) {
        String exact = map.get(key);
        if (exact != null) {
            return exact;
        }
        for (Map.Entry<String, String> e : map.entrySet()) {
            if (e.getKey().equalsIgnoreCase(key)) {
                return e.getValue();
            }
        }
        return null;
    }

    private static void check(int ok, MemorySegment state, String what) throws IOException {
        if (ok == 0) {
            throw new IOException(what + " failed: " + describe(Win32.lastError(state)));
        }
    }

    private static String describe(int error) {
        return switch (error) {
            case 2 -> "file not found (error 2)";
            case 3 -> "path not found (error 3)";
            case 5 -> "access denied (error 5)";
            case 193 -> "not a valid Win32 application (error 193)";
            default -> "error " + error;
        };
    }
}
