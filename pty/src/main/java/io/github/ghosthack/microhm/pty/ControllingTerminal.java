package io.github.ghosthack.microhm.pty;

import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import static java.lang.foreign.ValueLayout.ADDRESS;

/**
 * macOS: the first program a PTY child runs. It makes fd 0 — the PTY slave, opened by the
 * spawn — its controlling terminal with {@code ioctl(TIOCSCTTY)}, which macOS requires
 * of the session leader itself and {@code posix_spawn} cannot do, then {@code execve}s
 * the real program: same pid, same session, the given {@code argv[0]}.
 *
 * <p>{@code ControllingTerminal [--keep NAME]... [--env NAME=VALUE]... -- PROGRAM ARGV0 [ARG]...}
 *
 * <p>Before {@code execve}: every descriptor above 2 is marked close-on-exec (the JVM's own
 * jar and library descriptors must not reach the program), and this thread's signal mask
 * is emptied (a signal mask survives {@code execve}). The JVM is started with {@code -Xrs}
 * so it installs no handlers for the signals a shell cares about; any handler it does
 * install is reset by {@code execve}. The program's environment is exactly the one the
 * spawner meant: this JVM's variables named by {@code --keep} (the JVM and macOS add their
 * own, such as {@code JAVA_MAIN_CLASS_<pid>} and {@code __CF_USER_TEXT_ENCODING}, which
 * are dropped), plus the {@code --env} entries — the JVM options variables, withheld from
 * this JVM because it would print "Picked up ..." on the terminal.
 *
 * <p>On failure it prints one line to the terminal and exits 126 (could not take the
 * terminal) or 127 (could not run the program), the shell conventions.
 */
public final class ControllingTerminal {

    /** Variables the JVM launcher reads and announces; kept out of this JVM's environment. */
    static final List<String> JVM_OPTION_VARIABLES = List.of("JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS");

    private ControllingTerminal() {
    }

    public static void main(String[] args) {
        Map<String, String> environment = new LinkedHashMap<>();
        Map<String, String> own = System.getenv();
        int i = 0;
        while (i + 1 < args.length && args[i].equals("--keep")) {
            String value = own.get(args[i + 1]);
            if (value != null) {
                environment.put(args[i + 1], value);
            }
            i += 2;
        }
        while (i + 1 < args.length && args[i].equals("--env")) {
            String entry = args[i + 1];
            int eq = entry.indexOf('=');
            environment.put(entry.substring(0, eq), entry.substring(eq + 1));
            i += 2;
        }
        if (i + 2 > args.length || !args[i].equals("--")) {
            fail(127, "usage: ControllingTerminal [--keep NAME]... [--env NAME=VALUE]... -- PROGRAM ARGV0 [ARG]...");
        }
        String program = args[i + 1];
        List<String> argv = List.of(args).subList(i + 2, args.length);
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            int rc = (int) Posix.IOCTL.invokeExact(state, 0, Posix.TIOCSCTTY, MemorySegment.NULL);
            if (rc != 0) {
                fail(126, "cannot take the terminal (TIOCSCTTY): " + Posix.describe(Posix.errno(state)));
            }
            closeOnExecAbove2(state);
            MemorySegment empty = arena.allocate(Posix.SIGSET_BYTES);
            int ignored = (int) Posix.SIGEMPTYSET.invokeExact(empty);
            ignored = (int) Posix.PTHREAD_SIGMASK.invokeExact(Posix.SIG_SETMASK, empty, MemorySegment.NULL);
            List<String> envp = new ArrayList<>(environment.size());
            environment.forEach((name, value) -> envp.add(name + "=" + value));
            rc = (int) Posix.EXECVE.invokeExact(state, arena.allocateFrom(program),
                    strings(arena, argv), strings(arena, envp));
            fail(127, "cannot run " + program + ": " + Posix.describe(Posix.errno(state)));
        } catch (Throwable t) {
            fail(127, "cannot run " + program + ": " + t);
        }
    }

    private static void closeOnExecAbove2(MemorySegment state) throws Throwable {
        List<Integer> fds = new ArrayList<>();
        try (Stream<Path> open = Files.list(Path.of("/dev/fd"))) {
            open.forEach(p -> {
                try {
                    fds.add(Integer.parseInt(p.getFileName().toString()));
                } catch (NumberFormatException notADescriptor) {
                    // nothing else lives there
                }
            });
        } catch (IOException e) {
            for (int fd = 3; fd < 1024; fd++) {
                fds.add(fd);
            }
        }
        for (int fd : fds) {
            if (fd > 2) {
                int ignored = (int) Posix.FCNTL.invokeExact(state, fd, Posix.F_SETFD, Posix.FD_CLOEXEC);
            }
        }
    }

    private static MemorySegment strings(Arena arena, List<String> values) {
        MemorySegment array = arena.allocate(ADDRESS, values.size() + 1L);
        for (int i = 0; i < values.size(); i++) {
            array.setAtIndex(ADDRESS, i, arena.allocateFrom(values.get(i), StandardCharsets.UTF_8));
        }
        array.setAtIndex(ADDRESS, values.size(), MemorySegment.NULL);
        return array;
    }

    private static void fail(int status, String message) {
        System.err.println("micro-harness-manager: " + message);
        System.err.flush();
        Runtime.getRuntime().halt(status);
    }
}
