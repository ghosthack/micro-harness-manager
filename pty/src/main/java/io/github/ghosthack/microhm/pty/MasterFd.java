package io.github.ghosthack.microhm.pty;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;

import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

/**
 * The PTY master descriptor, shared by one reader and any number of writers, closed
 * exactly once and never used after: a descriptor number is reused by the next
 * {@code open} anywhere in the JVM, so a late write to a closed number could land in an
 * unrelated file. Every operation registers itself as in flight; {@link #close} marks the
 * descriptor closed and releases it only once nothing is in flight. Reads wait in
 * {@code poll} on the master and on a wake pipe rather than blocking in {@code read}:
 * {@link #close} writes to the pipe, so a close never waits on output that will not come,
 * and an idle session costs no wakeups at all. Should the pipe be unavailable, the wait
 * falls back to a short poll timeout.
 */
final class MasterFd implements AutoCloseable {

    /** Poll timeout used only when the wake pipe could not be created. */
    private static final int FALLBACK_POLL_MILLIS = 100;

    private final int fd;
    /** The wake pipe's read and write ends, or -1 when it could not be created. */
    private final int wakeRead;
    private final int wakeWrite;
    private final Object lock = new Object();
    private int inFlight;          // guarded by lock
    private boolean closing;       // guarded by lock
    private boolean released;      // guarded by lock

    /** Set by the reader once poll reports output and before it reads any of it; cleared
     * by the consumer once what it read is applied. Together with {@link #unread}, some
     * unapplied output is always visible: see {@link #outputPending}. */
    private volatile boolean readPending;

    /** The reader's native buffers, allocated once and reused (there is one reader). */
    private final Object readLock = new Object();
    private MemorySegment readState;   // guarded by readLock
    private MemorySegment readPollfds; // guarded by readLock
    private MemorySegment readBuffer;  // guarded by readLock

    MasterFd(int fd) {
        this.fd = fd;
        int[] pipe = openWakePipe();
        this.wakeRead = pipe[0];
        this.wakeWrite = pipe[1];
    }

    /** A close-on-exec pipe, so the shells this process spawns never inherit it; {-1, -1}
     * when it cannot be created. */
    private static int[] openWakePipe() {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            MemorySegment fds = arena.allocate(JAVA_INT, 2);
            if ((int) Posix.PIPE.invokeExact(state, fds) != 0) {
                return new int[] {-1, -1};
            }
            int r = fds.getAtIndex(JAVA_INT, 0);
            int w = fds.getAtIndex(JAVA_INT, 1);
            int ignored = (int) Posix.FCNTL.invokeExact(state, r, Posix.F_SETFD, Posix.FD_CLOEXEC);
            ignored = (int) Posix.FCNTL.invokeExact(state, w, Posix.F_SETFD, Posix.FD_CLOEXEC);
            return new int[] {r, w};
        } catch (Throwable t) {
            return new int[] {-1, -1};
        }
    }

    int fd() {
        return fd;
    }

    /** Registers an operation; false when the descriptor is closing or closed. */
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

    /**
     * Reads up to {@code length} bytes; returns -1 at end of output: the slave side has
     * been closed by every process (EIO on Linux, EOF on macOS), or this descriptor closed.
     */
    int read(byte[] buffer, int offset, int length) throws IOException {
        if (length == 0) {
            return 0;
        }
        synchronized (readLock) {
            return readLocked(buffer, offset, length);
        }
    }

    private int readLocked(byte[] buffer, int offset, int length) throws IOException {
        if (readState == null) {
            // GC-managed: the reader thread may differ from the one that releases the fd.
            Arena arena = Arena.ofAuto();
            readState = Posix.callState(arena);
            readPollfds = arena.allocate(16);
        }
        if (readBuffer == null || readBuffer.byteSize() < length) {
            readBuffer = Arena.ofAuto().allocate(length);
        }
        MemorySegment state = readState;
        MemorySegment pollfd = readPollfds;
        MemorySegment native_ = readBuffer;
        boolean wakeable = wakeRead >= 0;
        int nfds = wakeable ? 2 : 1;
        int timeout = wakeable ? -1 : FALLBACK_POLL_MILLIS;
        try {
            while (true) {
                if (!enter()) {
                    return -1;
                }
                try {
                    pollfd.set(JAVA_INT, 0, fd);
                    pollfd.set(JAVA_SHORT, 4, Posix.POLLIN);
                    pollfd.set(JAVA_SHORT, 6, (short) 0);
                    pollfd.set(JAVA_INT, 8, wakeRead);
                    pollfd.set(JAVA_SHORT, 12, Posix.POLLIN);
                    pollfd.set(JAVA_SHORT, 14, (short) 0);
                    int ready = Posix.MAC
                            ? (int) Posix.POLL.invokeExact(state, pollfd, nfds, timeout)
                            : (int) Posix.POLL.invokeExact(state, pollfd, (long) nfds, timeout);
                    if (ready < 0) {
                        int errno = Posix.errno(state);
                        if (errno == Posix.EINTR || errno == Posix.EAGAIN) {
                            continue;
                        }
                        throw new IOException("poll on the PTY failed: " + Posix.describe(errno));
                    }
                    if (ready == 0) {
                        continue; // fallback timeout: re-check whether we are closing
                    }
                    if (wakeable && pollfd.get(JAVA_SHORT, 14) != 0) {
                        return -1; // close() woke us
                    }
                    short revents = pollfd.get(JAVA_SHORT, 6);
                    if ((revents & Posix.POLLNVAL) != 0) {
                        return -1;
                    }
                    // Before the read takes the bytes out of the kernel, so that a caller
                    // checking outputPending() never sees them in neither place.
                    readPending = true;
                    long n = (long) Posix.READ.invokeExact(state, fd, native_, (long) length);
                    if (n <= 0) {
                        readPending = false;
                    }
                    if (n > 0) {
                        MemorySegment.copy(native_, JAVA_BYTE_LAYOUT, 0, buffer, offset, (int) n);
                        return (int) n;
                    }
                    if (n == 0) {
                        return -1;
                    }
                    int errno = Posix.errno(state);
                    if (errno == Posix.EINTR || errno == Posix.EAGAIN) {
                        continue;
                    }
                    if (errno == Posix.EIO) {
                        return -1; // Linux: every slave descriptor is closed
                    }
                    throw new IOException("reading the PTY failed: " + Posix.describe(errno));
                } finally {
                    exit();
                }
            }
        } catch (IOException e) {
            throw e;
        } catch (Throwable t) {
            throw new IOException("reading the PTY failed", t);
        }
    }

    /** Writes every byte, or throws: {@code IOException} once the descriptor is closed. */
    void write(byte[] buffer, int offset, int length) throws IOException {
        if (length == 0) {
            return;
        }
        if (!enter()) {
            throw new IOException("the PTY is closed");
        }
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            MemorySegment native_ = arena.allocate(length);
            MemorySegment.copy(buffer, offset, native_, JAVA_BYTE_LAYOUT, 0, length);
            long written = 0;
            while (written < length) {
                long n = (long) Posix.WRITE.invokeExact(state, fd, native_.asSlice(written), (long) length - written);
                if (n < 0) {
                    int errno = Posix.errno(state);
                    if (errno == Posix.EINTR || errno == Posix.EAGAIN) {
                        continue;
                    }
                    throw new IOException("writing the PTY failed: " + Posix.describe(errno));
                }
                written += n;
            }
        } catch (IOException e) {
            throw e;
        } catch (Throwable t) {
            throw new IOException("writing the PTY failed", t);
        } finally {
            exit();
        }
    }

    /**
     * True while the program has output this process has not finished consuming: bytes
     * still in the kernel buffer, or bytes the reader took since the consumer last called
     * {@link #outputConsumed}. False once the descriptor is closed.
     */
    boolean outputPending() {
        return readPending || unread() > 0;
    }

    /** The consumer has applied everything the reader returned so far. */
    void outputConsumed() {
        readPending = false;
    }

    /** {@code FIONREAD}: bytes waiting in the kernel; 0 when closed or unknown. */
    private int unread() {
        int[] count = new int[1];
        with(descriptor -> {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment n = arena.allocate(JAVA_INT);
                if ((int) Posix.IOCTL.invokeExact(Posix.callState(arena), descriptor, Posix.FIONREAD, n) == 0) {
                    count[0] = n.get(JAVA_INT, 0);
                }
            } catch (Throwable ignored) {
                // Unknown: report nothing pending rather than stall a caller.
            }
            return true;
        });
        return count[0];
    }

    /** Runs {@code op} with the live descriptor; false (op not run) once closing. */
    boolean with(java.util.function.IntPredicate op) {
        if (!enter()) {
            return false;
        }
        try {
            return op.test(fd);
        } finally {
            exit();
        }
    }

    /** Marks the descriptor closed; it is released now, or when the last in-flight
     * operation finishes (a read waiting in poll is woken through the pipe). Idempotent. */
    @Override
    public void close() {
        synchronized (lock) {
            if (closing) {
                return;
            }
            closing = true;
            if (inFlight == 0) {
                release();
                return;
            }
            // A read is in flight: wake it. The pipe stays open until release().
            wake();
        }
    }

    private void wake() {
        if (wakeWrite < 0) {
            return;
        }
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment one = arena.allocate(1);
            long ignored = (long) Posix.WRITE.invokeExact(Posix.callState(arena), wakeWrite, one, 1L);
        } catch (Throwable ignored) {
            // The reader then waits for the master's own hang-up instead.
        }
    }

    private void release() {
        if (released) {
            return;
        }
        released = true;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            int ignored = (int) Posix.CLOSE.invokeExact(state, fd);
            if (wakeRead >= 0) {
                ignored = (int) Posix.CLOSE.invokeExact(state, wakeRead);
                ignored = (int) Posix.CLOSE.invokeExact(state, wakeWrite);
            }
        } catch (Throwable ignored) {
            // Nothing useful to do: the descriptors are abandoned either way.
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
                java.util.Objects.checkFromIndexSize(off, len, b.length);
                return MasterFd.this.read(b, off, len);
            }

            @Override
            public void close() {
                MasterFd.this.close();
            }
        };
    }

    /** The writer's stream. Closing it does not close the master (the reader still needs
     * it); {@link PtyProcess} closes the master once output has ended. */
    OutputStream outputStream() {
        return new OutputStream() {
            @Override
            public void write(int b) throws IOException {
                MasterFd.this.write(new byte[] {(byte) b}, 0, 1);
            }

            @Override
            public void write(byte[] b, int off, int len) throws IOException {
                java.util.Objects.checkFromIndexSize(off, len, b.length);
                MasterFd.this.write(b, off, len);
            }
        };
    }

    private static final java.lang.foreign.ValueLayout.OfByte JAVA_BYTE_LAYOUT = java.lang.foreign.ValueLayout.JAVA_BYTE;
}
