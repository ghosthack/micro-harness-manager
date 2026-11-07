package io.github.ghosthack.microhm.app.perf;

import java.lang.management.ManagementFactory;

/** When this run of the app started, reached {@code main}, and first showed its window. */
public final class StartupTimes {

    private static volatile long mainMillis = -1;
    private static volatile long windowMillis = -1;

    /** Called first thing in {@code main}. */
    public static void markMain() {
        mainMillis = System.currentTimeMillis();
    }

    /** Called when the main window first opens. */
    public static void markWindowShown() {
        if (windowMillis < 0) {
            windowMillis = System.currentTimeMillis();
        }
    }

    /** The JVM's start, in epoch milliseconds. */
    public static long jvmStartMillis() {
        return ManagementFactory.getRuntimeMXBean().getStartTime();
    }

    /** Milliseconds from the JVM's start to {@code main}, or -1. */
    public static long toMain() {
        return mainMillis < 0 ? -1 : mainMillis - jvmStartMillis();
    }

    /** Milliseconds from the JVM's start to the window opening, or -1. */
    public static long toWindow() {
        return windowMillis < 0 ? -1 : windowMillis - jvmStartMillis();
    }

    private StartupTimes() {
    }
}
