package io.github.ghosthack.microhm.mux.client;

import org.junit.jupiter.api.Test;

import java.io.InterruptedIOException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

class InboundPipeTest {

    /** An interrupted read surfaces as {@link InterruptedIOException} specifically, not the
     * plain {@link java.io.IOException} supertype, so a reader stopped by interrupting its
     * thread mid-read can tell a quiet stop from an error. */
    @Test
    void interruptingABlockedReadThrowsInterruptedIOExceptionAndRestoresTheInterruptFlag() throws Exception {
        InboundPipe pipe = new InboundPipe(64);
        CountDownLatch blocked = new CountDownLatch(1);
        AtomicReference<Throwable> thrown = new AtomicReference<>();
        AtomicReference<Boolean> interruptedAfterCatch = new AtomicReference<>();

        Thread reader = new Thread(() -> {
            blocked.countDown();
            try {
                pipe.read(new byte[16], 0, 16);
            } catch (Throwable t) {
                thrown.set(t);
                interruptedAfterCatch.set(Thread.currentThread().isInterrupted());
            }
        });
        reader.start();
        assertTrue(blocked.await(5, TimeUnit.SECONDS));
        Thread.sleep(50); // let the reader actually reach the blocking await()
        reader.interrupt();
        reader.join(5000);

        assertInstanceOf(InterruptedIOException.class, thrown.get());
        assertEquals(Boolean.TRUE, interruptedAfterCatch.get(), "interrupt status must be restored");
    }
}
