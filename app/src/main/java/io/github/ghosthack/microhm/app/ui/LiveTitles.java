package io.github.ghosthack.microhm.app.ui;

import io.github.ghosthack.microhm.app.host.SessionHost;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * Keeps the host's title stream ({@link SessionHost#watchTitles}) open and hands each
 * session's newest title to the UI, so the sidebar shows the frames a harness writes into
 * its title as it writes them rather than whatever frame the next status poll samples.
 *
 * <p>Titles are coalesced per session between deliveries: a burst of spinner frames
 * arriving faster than the EDT drains becomes one delivery carrying the latest frame of
 * each session, so a busy harness can never queue up stale frames. Nothing is invented
 * or interpolated; at worst a frame is skipped. A stream that ends (daemon restarted, no
 * daemon yet, one too old to watch) is reopened with backoff, and the status poll's title
 * covers the gap.
 */
final class LiveTitles {

    private static final Logger LOG = LoggerFactory.getLogger(LiveTitles.class);

    static final Duration BACKOFF_MIN = Duration.ofSeconds(1);
    static final Duration BACKOFF_MAX = Duration.ofSeconds(30);
    /** How often the loop checks that an open stream is still open. */
    private static final Duration CHECK = Duration.ofSeconds(1);

    private final SessionHost host;
    private final Consumer<Runnable> edt;
    private final Consumer<Map<String, String>> onTitles;
    private final Map<String, String> latest = new ConcurrentHashMap<>();
    private final AtomicBoolean drainQueued = new AtomicBoolean();
    private volatile boolean running;
    private Thread loop;

    /**
     * @param edt       runs a task on the UI thread ({@code SwingUtilities::invokeLater})
     * @param onTitles  gets {@code sessionName -> newest title} on the UI thread
     */
    LiveTitles(SessionHost host, Consumer<Runnable> edt, Consumer<Map<String, String>> onTitles) {
        this.host = host;
        this.edt = edt;
        this.onTitles = onTitles;
    }

    synchronized void start() {
        if (loop != null) {
            return;
        }
        running = true;
        loop = Thread.ofVirtual().name("mhm-live-titles").start(this::run);
    }

    synchronized void stop() {
        running = false;
        if (loop != null) {
            loop.interrupt();
            loop = null;
        }
    }

    /** Called on the stream's reader thread for every title change. */
    void titleChanged(String session, String title) {
        latest.put(session, title);
        if (drainQueued.compareAndSet(false, true)) {
            edt.accept(this::drain);
        }
    }

    private void drain() {
        drainQueued.set(false);
        Map<String, String> batch = new HashMap<>();
        for (String session : latest.keySet()) {
            String title = latest.remove(session);
            if (title != null) {
                batch.put(session, title);
            }
        }
        if (!batch.isEmpty() && running) {
            onTitles.accept(batch);
        }
    }

    private void run() {
        Duration backoff = BACKOFF_MIN;
        SessionHost.TitleWatch watch = null;
        try {
            while (running) {
                if (watch == null || !watch.isOpen()) {
                    closeQuietly(watch);
                    watch = null;
                    try {
                        Optional<SessionHost.TitleWatch> opened = host.watchTitles(this::titleChanged);
                        if (opened.isEmpty()) {
                            return; // this host has no title stream: the poll is all there is
                        }
                        watch = opened.get();
                        backoff = BACKOFF_MIN;
                    } catch (RuntimeException e) {
                        LOG.debug("title stream unavailable, retrying in {}: {}", backoff, e.toString());
                        Thread.sleep(backoff.toMillis());
                        Duration doubled = backoff.multipliedBy(2);
                        backoff = doubled.compareTo(BACKOFF_MAX) > 0 ? BACKOFF_MAX : doubled;
                        continue;
                    }
                }
                Thread.sleep(CHECK.toMillis());
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } finally {
            closeQuietly(watch);
        }
    }

    private static void closeQuietly(SessionHost.TitleWatch watch) {
        if (watch != null) {
            try {
                watch.close();
            } catch (RuntimeException ignored) {
                // already gone
            }
        }
    }
}
