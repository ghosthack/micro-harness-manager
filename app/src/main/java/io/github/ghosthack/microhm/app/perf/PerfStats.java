package io.github.ghosthack.microhm.app.perf;

import java.io.IOException;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryUsage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Inexpensive figures about this run of the app, for Settings' Performance section: all read from
 * the JVM's management beans (and, on Linux, {@code /proc/self/status}) when asked, so
 * nothing is measured in the background.
 */
public final class PerfStats {

    /** One line of the section. */
    public record Row(String label, String value) {
    }

    public static List<Row> snapshot() {
        List<Row> rows = new ArrayList<>();
        var runtime = ManagementFactory.getRuntimeMXBean();

        long toWindow = StartupTimes.toWindow();
        rows.add(new Row("Startup", toWindow < 0 ? "—" : seconds(toWindow) + " to the window"
                + (StartupTimes.toMain() < 0 ? "" : " (" + seconds(StartupTimes.toMain()) + " to start the app code)")));
        AotCache cache = AotCache.current();
        String cacheText = cache.state().description();
        if (cache.size() > 0) {
            cacheText += ", " + megabytes(cache.size());
        }
        rows.add(new Row("Startup cache", cacheText));
        rows.add(new Row("Uptime", duration(Duration.ofMillis(runtime.getUptime()))));

        if (ManagementFactory.getOperatingSystemMXBean() instanceof com.sun.management.OperatingSystemMXBean os) {
            long cpu = os.getProcessCpuTime();
            if (cpu >= 0) {
                rows.add(new Row("CPU time", seconds(cpu / 1_000_000)));
            }
        }
        long rss = residentBytes();
        if (rss > 0) {
            rows.add(new Row("Memory in use", megabytes(rss)));
        }
        var memory = ManagementFactory.getMemoryMXBean();
        MemoryUsage heap = memory.getHeapMemoryUsage();
        rows.add(new Row("Java heap", megabytes(heap.getUsed()) + " used of " + megabytes(heap.getCommitted())
                + " (limit " + megabytes(heap.getMax()) + ")"));
        rows.add(new Row("Other Java memory", megabytes(memory.getNonHeapMemoryUsage().getCommitted())));

        long collections = 0;
        long collectionMillis = 0;
        List<String> collectors = new ArrayList<>();
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            collections += Math.max(0, gc.getCollectionCount());
            collectionMillis += Math.max(0, gc.getCollectionTime());
            collectors.add(gc.getName());
        }
        rows.add(new Row("Garbage collection", collections + " collections, " + seconds(collectionMillis)
                + " in total (" + String.join(", ", collectors) + ")"));
        rows.add(new Row("Threads", String.valueOf(ManagementFactory.getThreadMXBean().getThreadCount())));
        rows.add(new Row("Classes loaded", String.valueOf(ManagementFactory.getClassLoadingMXBean().getLoadedClassCount())));
        rows.add(new Row("Java", System.getProperty("java.runtime.version", "?") + " ("
                + System.getProperty("java.vendor", "?") + ")"));
        return rows;
    }

    /** The rows as plain text, for Copy. */
    public static String asText(List<Row> rows) {
        StringBuilder text = new StringBuilder();
        for (Row row : rows) {
            text.append(row.label()).append(": ").append(row.value()).append('\n');
        }
        return text.toString();
    }

    /** Resident memory on Linux; -1 elsewhere (no cheap portable reading). */
    private static long residentBytes() {
        Path status = Path.of("/proc/self/status");
        if (!Files.isReadable(status)) {
            return -1;
        }
        try {
            for (String line : Files.readAllLines(status)) {
                if (line.startsWith("VmRSS:")) {
                    return Long.parseLong(line.replaceAll("[^0-9]", "")) * 1024;
                }
            }
        } catch (IOException | NumberFormatException e) {
            // unreadable
        }
        return -1;
    }

    static String seconds(long millis) {
        return millis < 10_000
                ? String.format(Locale.ROOT, "%.2f s", millis / 1000.0)
                : String.format(Locale.ROOT, "%.1f s", millis / 1000.0);
    }

    static String megabytes(long bytes) {
        return bytes < 0 ? "—" : String.format(Locale.ROOT, "%.0f MB", bytes / (1024.0 * 1024.0));
    }

    static String duration(Duration d) {
        long h = d.toHours();
        long m = d.toMinutesPart();
        return h > 0 ? h + " h " + m + " min" : m > 0 ? m + " min " + d.toSecondsPart() + " s" : d.toSecondsPart() + " s";
    }

    private PerfStats() {
    }
}
