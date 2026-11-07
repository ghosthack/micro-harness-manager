package io.github.ghosthack.microhm.pty;

import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.StructLayout;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.VarHandle;
import java.util.Locale;
import java.util.Optional;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

/**
 * The libc calls a PTY needs, bound once through the FFM API, with the platform's
 * constants. macOS and Linux only: the values below come from the macOS SDK headers and
 * glibc's x86-64/aarch64 headers (identical for every constant used here on both Linux
 * architectures). Every downcall that can fail captures {@code errno}.
 *
 * <p>Variadic functions ({@code open}, {@code ioctl}) are bound with
 * {@link Linker.Option#firstVariadicArg} — on Apple silicon variadic arguments travel on
 * the stack, so binding them as fixed would silently pass garbage.
 */
final class Posix {

    static final boolean MAC;
    static final boolean LINUX;

    static {
        String os = System.getProperty("os.name", "").toLowerCase(Locale.ROOT);
        MAC = os.startsWith("mac") || os.startsWith("darwin");
        LINUX = os.startsWith("linux");
    }

    static final int O_RDWR = 0x2;
    static final int O_NOCTTY = MAC ? 0x20000 : 0x100;
    static final int O_CLOEXEC = MAC ? 0x1000000 : 0x80000;
    /** {@code _IOW('t', 103, struct winsize)} on macOS; {@code 0x5414} on Linux. */
    static final long TIOCSWINSZ = MAC ? 0x80087467L : 0x5414L;
    /** {@code _IO('t', 97)} on macOS; {@code 0x540E} on Linux. */
    static final long TIOCSCTTY = MAC ? 0x20007461L : 0x540EL;
    /** Bytes waiting to be read: on a PTY master, output the slave side wrote. */
    static final long FIONREAD = MAC ? 0x4004667FL : 0x541BL;
    static final short POSIX_SPAWN_SETSID = (short) (MAC ? 0x0400 : 0x80);
    /** macOS only: every descriptor not named by a file action is closed in the child. */
    static final short POSIX_SPAWN_CLOEXEC_DEFAULT = 0x4000;

    static final int F_SETFD = 2;
    static final int SIG_SETMASK = MAC ? 3 : 2;
    static final int FD_CLOEXEC = 1;

    static final int EINTR = 4;
    static final int EIO = 5;
    static final int ECHILD = 10;
    static final int EAGAIN = MAC ? 35 : 11;

    static final short POLLIN = 0x1;
    static final short POLLERR = 0x8;
    static final short POLLHUP = 0x10;
    static final short POLLNVAL = 0x20;

    static final int SIGHUP = 1;
    static final int SIGKILL = 9;
    static final int SIGTERM = 15;

    /** Opaque {@code posix_spawn_file_actions_t} / {@code posix_spawnattr_t}: a pointer on
     * macOS, an 80- and a 336-byte struct on glibc. Over-allocated to be safe anywhere. */
    static final long SPAWN_STRUCT_BYTES = 1024;

    private static final Linker LINKER = Linker.nativeLinker();
    private static final SymbolLookup LIBC = LINKER.defaultLookup();
    private static final StructLayout CALL_STATE = Linker.Option.captureStateLayout();
    private static final VarHandle ERRNO = CALL_STATE.varHandle(MemoryLayout.PathElement.groupElement("errno"));
    private static final Linker.Option CAPTURE_ERRNO = Linker.Option.captureCallState("errno");

    static final MethodHandle POSIX_OPENPT = errnoCall("posix_openpt", FunctionDescriptor.of(JAVA_INT, JAVA_INT));
    static final MethodHandle GRANTPT = errnoCall("grantpt", FunctionDescriptor.of(JAVA_INT, JAVA_INT));
    static final MethodHandle UNLOCKPT = errnoCall("unlockpt", FunctionDescriptor.of(JAVA_INT, JAVA_INT));
    /** Not reentrant (a static buffer); {@link #slaveName} serialises it. */
    private static final MethodHandle PTSNAME = call("ptsname", FunctionDescriptor.of(ADDRESS, JAVA_INT));
    static final MethodHandle OPEN = errnoCall("open", FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT),
            Linker.Option.firstVariadicArg(2));
    static final MethodHandle FCNTL = errnoCall("fcntl", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT),
            Linker.Option.firstVariadicArg(2));
    static final MethodHandle CLOSE = errnoCall("close", FunctionDescriptor.of(JAVA_INT, JAVA_INT));
    static final MethodHandle PIPE = errnoCall("pipe", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle READ = errnoCall("read", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG));
    static final MethodHandle WRITE = errnoCall("write", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG));
    /** {@code poll(struct pollfd *, nfds_t, int)}; {@code nfds_t} is unsigned int on macOS,
     * unsigned long on Linux. */
    static final MethodHandle POLL = errnoCall("poll",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, MAC ? JAVA_INT : JAVA_LONG, JAVA_INT));
    static final MethodHandle IOCTL = errnoCall("ioctl", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_LONG, ADDRESS),
            Linker.Option.firstVariadicArg(2));
    static final MethodHandle EXECVE = errnoCall("execve", FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS));
    /** Returns the error number instead of setting errno. */
    static final MethodHandle PTHREAD_SIGMASK = call("pthread_sigmask",
            FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS));
    static final MethodHandle KILL = errnoCall("kill", FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT));
    /** The foreground process group of the terminal open on the descriptor (the master
     * works: it reports the slave side's group); -1 with errno on failure. */
    static final MethodHandle TCGETPGRP = errnoCall("tcgetpgrp", FunctionDescriptor.of(JAVA_INT, JAVA_INT));
    static final MethodHandle WAITPID = errnoCall("waitpid", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));

    static final MethodHandle FILE_ACTIONS_INIT = call("posix_spawn_file_actions_init",
            FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle FILE_ACTIONS_DESTROY = call("posix_spawn_file_actions_destroy",
            FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle FILE_ACTIONS_ADDOPEN = call("posix_spawn_file_actions_addopen",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT, JAVA_SHORT));
    static final MethodHandle FILE_ACTIONS_ADDDUP2 = call("posix_spawn_file_actions_adddup2",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT));
    /** {@code addchdir} (POSIX 2024, macOS 26) or its older {@code _np} spelling (macOS
     * 10.15, glibc 2.29); empty when neither exists, and the spawner falls back to a shell. */
    static final Optional<MethodHandle> FILE_ACTIONS_ADDCHDIR = optionalCall(
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS),
            "posix_spawn_file_actions_addchdir", "posix_spawn_file_actions_addchdir_np");
    /** glibc 2.34+: close every descriptor from N up in the child (Linux has no
     * CLOEXEC_DEFAULT flag). */
    static final Optional<MethodHandle> FILE_ACTIONS_ADDCLOSEFROM = optionalCall(
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT), "posix_spawn_file_actions_addclosefrom_np");
    static final MethodHandle ATTR_INIT = call("posix_spawnattr_init", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle ATTR_DESTROY = call("posix_spawnattr_destroy", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle ATTR_SETFLAGS = call("posix_spawnattr_setflags",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_SHORT));
    static final MethodHandle ATTR_SETSIGMASK = call("posix_spawnattr_setsigmask",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));
    static final MethodHandle ATTR_SETSIGDEFAULT = call("posix_spawnattr_setsigdefault",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));
    static final MethodHandle SIGEMPTYSET = call("sigemptyset", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    static final MethodHandle SIGFILLSET = call("sigfillset", FunctionDescriptor.of(JAVA_INT, ADDRESS));
    /** {@code sigset_t}: 4 bytes on macOS, 128 on glibc. */
    static final long SIGSET_BYTES = 128;
    static final short POSIX_SPAWN_SETSIGMASK = 0x08;
    static final short POSIX_SPAWN_SETSIGDEF = 0x04;
    /** {@code posix_spawn} returns the error number instead of setting errno. */
    static final MethodHandle POSIX_SPAWN = call("posix_spawn",
            FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, ADDRESS, ADDRESS, ADDRESS));
    static final MethodHandle STRERROR = call("strerror", FunctionDescriptor.of(ADDRESS, JAVA_INT));

    private Posix() {
    }

    static void requireSupported() throws IOException {
        if (!MAC && !LINUX) {
            throw new IOException("PTYs are only supported on macOS and Linux (os.name="
                    + System.getProperty("os.name") + ")");
        }
    }

    /** A segment to pass as the leading call-state argument of an errno-capturing handle. */
    static MemorySegment callState(Arena arena) {
        return arena.allocate(CALL_STATE);
    }

    static int errno(MemorySegment callState) {
        return (int) ERRNO.get(callState, 0L);
    }

    static String describe(int errno) {
        try {
            MemorySegment message = (MemorySegment) STRERROR.invokeExact(errno);
            return message.reinterpret(256).getString(0) + " (errno " + errno + ")";
        } catch (Throwable t) {
            return "errno " + errno;
        }
    }

    /** {@code ptsname(master)}, serialised because libc's buffer is shared. */
    static synchronized String slaveName(int master) throws IOException {
        MemorySegment name;
        try {
            name = (MemorySegment) PTSNAME.invokeExact(master);
        } catch (Throwable t) {
            throw new IOException("ptsname failed", t);
        }
        if (name.equals(MemorySegment.NULL)) {
            throw new IOException("ptsname failed for fd " + master);
        }
        return name.reinterpret(1024).getString(0);
    }

    private static MethodHandle call(String name, FunctionDescriptor descriptor, Linker.Option... options) {
        return LINKER.downcallHandle(find(name), descriptor, options);
    }

    private static MethodHandle errnoCall(String name, FunctionDescriptor descriptor, Linker.Option... options) {
        Linker.Option[] all = new Linker.Option[options.length + 1];
        System.arraycopy(options, 0, all, 0, options.length);
        all[options.length] = CAPTURE_ERRNO;
        return LINKER.downcallHandle(find(name), descriptor, all);
    }

    private static Optional<MethodHandle> optionalCall(FunctionDescriptor descriptor, String... names) {
        for (String name : names) {
            Optional<MemorySegment> symbol = LIBC.find(name);
            if (symbol.isPresent()) {
                return Optional.of(LINKER.downcallHandle(symbol.get(), descriptor));
            }
        }
        return Optional.empty();
    }

    private static MemorySegment find(String name) {
        return LIBC.find(name).orElseThrow(() -> new UnsatisfiedLinkError("libc has no " + name));
    }
}
