package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.host.FakeSessionHost;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.BooleanSupplier;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LiveTitlesTest {

    @Test
    void framesArrivingFasterThanTheUiDrainsCoalesceToTheNewestPerSession() {
        List<Runnable> edtQueue = new ArrayList<>();
        List<Map<String, String>> delivered = new ArrayList<>();
        LiveTitles titles = new LiveTitles(new FakeSessionHost(), edtQueue::add, delivered::add);
        titles.start();
        try {
            titles.titleChanged("a", "◐ build");
            titles.titleChanged("a", "◓ build");
            titles.titleChanged("b", "✳ docs");
            titles.titleChanged("a", "◑ build");

            assertEquals(1, edtQueue.size(), "one drain queued for the whole burst");
            edtQueue.remove(0).run();
            assertEquals(List.of(Map.of("a", "◑ build", "b", "✳ docs")), delivered);

            titles.titleChanged("a", "◒ build");
            assertEquals(1, edtQueue.size(), "a frame after the drain queues the next one");
            edtQueue.remove(0).run();
            assertEquals(Map.of("a", "◒ build"), delivered.get(1));
        } finally {
            titles.stop();
        }
    }

    @Test
    void streamsTitlesFromTheHostAndReopensAStreamThatEnds() throws Exception {
        FakeSessionHost host = new FakeSessionHost();
        host.enableTitleStream();
        host.failTitleWatches(1); // no daemon yet: the first open fails and is retried
        List<Map<String, String>> delivered = new CopyOnWriteArrayList<>();
        LiveTitles titles = new LiveTitles(host, Runnable::run, delivered::add);
        titles.start();
        try {
            await(() -> host.titleWatchOpens.get() == 1);
            host.emitTitle("mhm-a", "⠋ working");
            assertEquals(List.of(Map.of("mhm-a", "⠋ working")), delivered);

            host.endTitleStreams();
            await(() -> host.titleWatchOpens.get() == 2);
            host.emitTitle("mhm-a", "⠙ working");
            assertEquals(Map.of("mhm-a", "⠙ working"), delivered.get(1));
        } finally {
            titles.stop();
        }
    }

    @Test
    void stopsQuietlyWhenTheHostHasNoTitleStream() throws Exception {
        FakeSessionHost host = new FakeSessionHost();
        LiveTitles titles = new LiveTitles(host, Runnable::run, batch -> { });
        titles.start();
        titles.stop();
        assertEquals(0, host.titleWatchOpens.get());
    }

    private static void await(BooleanSupplier condition) throws InterruptedException {
        long deadline = System.nanoTime() + 10_000_000_000L;
        while (!condition.getAsBoolean()) {
            assertTrue(System.nanoTime() < deadline, "timed out");
            Thread.sleep(20);
        }
    }
}
