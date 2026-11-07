package io.github.ghosthack.microhm.mux.protocol;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Reads and writes {@link Frame}s over blocking streams. Not thread-safe per direction:
 * one reader thread and one writer thread per connection; the writer must be externally
 * serialized when several threads can send (attach mode: session output and
 * SESSION_EXITED race) — callers synchronize on the codec instance for writes.
 */
public final class FrameCodec {

    /** Payloads up to this size are sent in one write together with the header (one copy,
     * one syscall); larger ones go header-then-payload to avoid copying them. */
    static final int COALESCE_LIMIT = 16 * 1024;

    private final DataInputStream in;
    private final OutputStream out;

    /** The input is buffered here (a frame header and a small payload then cost one read
     * syscall instead of three); nothing may read the underlying stream after construction.
     * The output is not buffered: each {@link #write} pushes its frame out before returning. */
    public FrameCodec(InputStream in, OutputStream out) {
        this.in = new DataInputStream(new BufferedInputStream(in));
        this.out = out;
    }

    /** Blocks until one full frame has arrived. Returns null on a clean EOF at a frame
     * boundary; throws on a truncated frame or an oversized/unknown one. */
    public Frame read() throws IOException {
        int length;
        try {
            length = in.readInt();
        } catch (EOFException e) {
            return null;
        }
        if (length < 1 || length - 1 > Frame.MAX_PAYLOAD) {
            throw new IOException("bad frame length " + length);
        }
        int typeCode = in.readUnsignedByte();
        FrameType type;
        try {
            type = FrameType.fromCode(typeCode);
        } catch (IllegalArgumentException e) {
            throw new IOException(e.getMessage());
        }
        byte[] payload = new byte[length - 1];
        in.readFully(payload);
        return new Frame(type, payload);
    }

    /** Writes one frame and flushes. Synchronize on this codec when several threads write. */
    public synchronized void write(Frame frame) throws IOException {
        byte[] payload = frame.payload();
        int length = payload.length + 1;
        byte type = (byte) frame.type().code();
        if (payload.length <= COALESCE_LIMIT) {
            byte[] wire = new byte[5 + payload.length];
            putHeader(wire, length, type);
            System.arraycopy(payload, 0, wire, 5, payload.length);
            out.write(wire);
        } else {
            byte[] header = new byte[5];
            putHeader(header, length, type);
            out.write(header);
            out.write(payload);
        }
        out.flush();
    }

    private static void putHeader(byte[] buf, int length, byte type) {
        buf[0] = (byte) (length >>> 24);
        buf[1] = (byte) (length >>> 16);
        buf[2] = (byte) (length >>> 8);
        buf[3] = (byte) length;
        buf[4] = type;
    }
}
