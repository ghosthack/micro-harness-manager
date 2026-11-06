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
 * {@code poll} with a short timeout rather than blocking in {@code read}, so a close never
 * waits on output that will not come.
 */
final class MasterFd implements AutoCloseable {

    private static final int POLL_MILLIS = 100;

    private final int fd;
    private final Object lock = new Object();
    private int inFlight;          // guarded by lock
    private boolean closing;       // guarded by lock
    private boolean released;      // guarded by lock

    MasterFd(int fd) {
        this.fd = fd;
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
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment state = Posix.callState(arena);
            MemorySegment pollfd = arena.allocate(8);
            MemorySegment native_ = arena.allocate(length);
            while (true) {
                if (!enter()) {
                    return -1;
                }
                try {
                    pollfd.set(JAVA_INT, 0, fd);
                    pollfd.set(JAVA_SHORT, 4, Posix.POLLIN);
                    pollfd.set(JAVA_SHORT, 6, (short) 0);
                    int ready = Posix.MAC
                            ? (int) Posix.POLL.invokeExact(state, pollfd, 1, POLL_MILLIS)
                            : (int) Posix.POLL.invokeExact(state, pollfd, 1L, POLL_MILLIS);
                    if (ready < 0) {
                        int errno = Posix.errno(state);
                        if (errno == Posix.EINTR || errno == Posix.EAGAIN) {
                            continue;
                        }
                        throw new IOException("poll on the PTY failed: " + Posix.describe(errno));
                    }
                    if (ready == 0) {
                        continue; // timeout: re-check whether we are closing
                    }
                    short revents = pollfd.get(JAVA_SHORT, 6);
                    if ((revents & Posix.POLLNVAL) != 0) {
                        return -1;
                    }
                    long n = (long) Posix.READ.invokeExact(state, fd, native_, (long) length);
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
     * operation (at most one poll timeout away for a read) finishes. Idempotent. */
    @Override
    public void close() {
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
        if (released) {
            return;
        }
        released = true;
        try (Arena arena = Arena.ofConfined()) {
            int ignored = (int) Posix.CLOSE.invokeExact(Posix.callState(arena), fd);
        } catch (Throwable ignored) {
            // Nothing useful to do: the descriptor is abandoned either way.
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
