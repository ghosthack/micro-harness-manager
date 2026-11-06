package io.github.ghosthack.microhm.app.terminal;

import io.github.ghosthack.microhm.app.host.SessionConnection;

import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** A scripted {@link SessionConnection}: {@link #push} queues output, {@link #end} queues EOF. */
final class FakeConnection implements SessionConnection {

    private static final byte[] EOF = new byte[0];

    private final LinkedBlockingQueue<byte[]> output = new LinkedBlockingQueue<>();
    private byte[] current;
    private int pos;
    private final ByteArrayOutputStream written = new ByteArrayOutputStream();
    final List<String> resizes = new CopyOnWriteArrayList<>();
    final AtomicInteger closes = new AtomicInteger();
    private volatile boolean alive = true;

    void push(byte[] bytes) {
        output.add(bytes);
    }

    void push(String s) {
        push(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    void end() {
        output.add(EOF);
    }

    synchronized String written() {
        return written.toString(java.nio.charset.StandardCharsets.UTF_8);
    }

    /** Waits until the writer thread has delivered {@code expected} (or times out). */
    String awaitWritten(String expected) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (!written().contains(expected) && System.nanoTime() < deadline) {
            Thread.sleep(5);
        }
        return written();
    }

    @Override
    public String name() {
        return "fake";
    }

    @Override
    public int read(byte[] buf, int off, int len) {
        try {
            while (current == null || pos == current.length) {
                if (!alive) {
                    return -1;
                }
                byte[] next = output.poll(50, TimeUnit.MILLISECONDS);
                if (next == EOF) {
                    alive = false;
                    return -1;
                }
                if (next != null) {
                    current = next;
                    pos = 0;
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return -1;
        }
        int n = Math.min(len, current.length - pos);
        System.arraycopy(current, pos, buf, off, n);
        pos += n;
        return n;
    }

    @Override
    public synchronized void write(byte[] bytes) {
        written.writeBytes(bytes);
    }

    @Override
    public void resize(int columns, int rows) {
        resizes.add(columns + "x" + rows);
    }

    @Override
    public boolean isAlive() {
        return alive;
    }

    @Override
    public int waitFor() {
        return 0;
    }

    @Override
    public void close() {
        closes.incrementAndGet();
        alive = false;
    }
}
