package io.github.ghosthack.microhm.mux.client;

import java.util.List;

/**
 * JVM options for the long-lived processes: the app, the session daemon and the
 * background host. Their heaps stay small (screens, scrollback, a few caches) and they
 * run for days, so footprint matters more than throughput. The default G1 collector sizes
 * its bookkeeping to the default maximum heap (a quarter of RAM) and keeps heap it once
 * grew into; the serial collector, starting small and returning memory after a collection,
 * measured 35% less resident memory for the app and 55% less for a daemon after heavy
 * output, at the same throughput and with fewer idle wakeups.
 *
 * <p>Mirrored in {@code run.sh}, {@code run.cmd}, {@code microhm-mux}, {@code microhm-mux.cmd}
 * and {@code scripts/package.sh}; keep them in step.
 */
public final class JvmOptions {

    public static final List<String> RESIDENT = List.of(
            "-XX:+UseSerialGC", "-Xms16m", "-Xmx2g", "-XX:MinHeapFreeRatio=10", "-XX:MaxHeapFreeRatio=30");

    private JvmOptions() {
    }
}
