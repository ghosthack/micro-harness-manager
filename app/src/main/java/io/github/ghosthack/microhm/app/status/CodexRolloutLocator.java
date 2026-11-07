package io.github.ghosthack.microhm.app.status;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;
import java.util.function.LongFunction;
import java.util.function.LongSupplier;
import java.util.function.Predicate;
import java.util.stream.Stream;

/** Finds the rollout file the Codex process under a pane's shell has open, remembering
 * each Codex process's answer so {@code lsof} is forked once per process rather than
 * once per status tick. A process whose lookup found nothing is retried after
 * {@link #MISS_RETRY_NANOS} (a just-started Codex opens its rollout a moment later); a
 * found rollout is re-checked after {@link #HIT_REFRESH_NANOS} so a {@code /new} or
 * {@code /resume} inside the same process is still picked up. Entries for processes
 * that have exited are dropped. Thread-safe. */
final class CodexRolloutLocator implements LongFunction<Optional<Path>> {

    static final long MISS_RETRY_NANOS = TimeUnit.SECONDS.toNanos(30);
    static final long HIT_REFRESH_NANOS = TimeUnit.MINUTES.toNanos(2);
    static final long PRUNE_INTERVAL_NANOS = TimeUnit.SECONDS.toNanos(30);

    /** A Codex process, identified by pid and start time so a reused pid is not confused
     * with the process that held it before. */
    record CodexProcess(long pid, long startMillis) { }

    private record Lookup(Optional<Path> rollout, long checkedAtNanos) { }

    private final LongFunction<List<CodexProcess>> codexProcesses;
    private final Function<CodexProcess, Optional<Path>> openRollout;
    private final Predicate<CodexProcess> stillRunning;
    private final LongSupplier nanoClock;
    private final ConcurrentHashMap<CodexProcess, Lookup> lookups = new ConcurrentHashMap<>();
    private volatile long lastPruneNanos;

    /** Over the live process table and {@code lsof}, accepting only rollouts under
     * {@code sessionsRoot}. */
    CodexRolloutLocator(Path sessionsRoot) {
        this(CodexRolloutLocator::liveCodexProcesses,
                process -> openRolloutForProcess(process.pid(), sessionsRoot),
                CodexRolloutLocator::isRunning,
                System::nanoTime);
    }

    /** Test seam: the process walk, the per-process {@code lsof}, the liveness check and
     * the clock are all injected. */
    CodexRolloutLocator(LongFunction<List<CodexProcess>> codexProcesses,
                        Function<CodexProcess, Optional<Path>> openRollout,
                        Predicate<CodexProcess> stillRunning,
                        LongSupplier nanoClock) {
        this.codexProcesses = codexProcesses;
        this.openRollout = openRollout;
        this.stillRunning = stillRunning;
        this.nanoClock = nanoClock;
        this.lastPruneNanos = nanoClock.getAsLong();
    }

    @Override
    public Optional<Path> apply(long paneProcessId) {
        long now = nanoClock.getAsLong();
        pruneIfDue(now);
        return codexProcesses.apply(paneProcessId).stream()
                .map(process -> lookup(process, now))
                .flatMap(Optional::stream)
                .max(Comparator.comparingLong(CodexRolloutLocator::lastModified));
    }

    /** Number of Codex processes currently remembered (for tests). */
    int cachedProcessCount() {
        return lookups.size();
    }

    private Optional<Path> lookup(CodexProcess process, long now) {
        Lookup cached = lookups.get(process);
        if (cached != null) {
            long age = now - cached.checkedAtNanos();
            long ttl = cached.rollout().isPresent() ? HIT_REFRESH_NANOS : MISS_RETRY_NANOS;
            if (age < ttl) {
                return cached.rollout();
            }
        }
        Optional<Path> found = openRollout.apply(process);
        lookups.put(process, new Lookup(found, now));
        return found;
    }

    private void pruneIfDue(long now) {
        if (now - lastPruneNanos < PRUNE_INTERVAL_NANOS) {
            return;
        }
        lastPruneNanos = now;
        lookups.keySet().removeIf(process -> !stillRunning.test(process));
    }

    private static List<CodexProcess> liveCodexProcesses(long paneProcessId) {
        Optional<ProcessHandle> pane = ProcessHandle.of(paneProcessId);
        if (pane.isEmpty()) {
            return List.of();
        }
        return Stream.concat(Stream.of(pane.get()), pane.get().descendants())
                .flatMap(handle -> {
                    ProcessHandle.Info info = handle.info();
                    boolean codex = info.command()
                            .map(command -> Path.of(command).getFileName().toString().equals("codex"))
                            .orElse(false);
                    return codex
                            ? Stream.of(new CodexProcess(handle.pid(), startMillis(info)))
                            : Stream.empty();
                })
                .toList();
    }

    private static boolean isRunning(CodexProcess process) {
        return ProcessHandle.of(process.pid())
                .filter(ProcessHandle::isAlive)
                .map(handle -> startMillis(handle.info()) == process.startMillis())
                .orElse(false);
    }

    private static long startMillis(ProcessHandle.Info info) {
        return info.startInstant().map(Instant::toEpochMilli).orElse(0L);
    }

    private static Optional<Path> openRolloutForProcess(long processId, Path sessionsRoot) {
        Process process = null;
        try {
            process = new ProcessBuilder("lsof", "-a", "-p", Long.toString(processId), "-Fn")
                    .redirectErrorStream(true).start();
            if (!process.waitFor(2, TimeUnit.SECONDS)) {
                process.destroyForcibly();
                return Optional.empty();
            }
            Path newest = null;
            try (BufferedReader output = process.inputReader()) {
                for (String line; (line = output.readLine()) != null; ) {
                    if (line.startsWith("n") && line.contains("/rollout-")
                            && line.endsWith(".jsonl")) {
                        Path candidate = Path.of(line.substring(1)).toAbsolutePath().normalize();
                        if (!candidate.startsWith(sessionsRoot)) {
                            continue;
                        }
                        if (newest == null || lastModified(candidate) > lastModified(newest)) {
                            newest = candidate;
                        }
                    }
                }
            }
            return Optional.ofNullable(newest);
        } catch (IOException e) {
            return Optional.empty();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        } finally {
            if (process != null && process.isAlive()) {
                process.destroyForcibly();
            }
        }
    }

    static long lastModified(Path path) {
        try {
            return Files.getLastModifiedTime(path).toMillis();
        } catch (IOException e) {
            return Long.MIN_VALUE;
        }
    }
}
