package io.github.ghosthack.microhm.app.control;

import io.github.ghosthack.microhm.mux.session.Session;
import io.github.ghosthack.microhm.vt.HeadlessTerminal;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.Reader;
import java.io.UncheckedIOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.function.UnaryOperator;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.GZIPOutputStream;

/**
 * Plain-text copies of sessions' output, written into the folder of the agent that asked
 * about them ({@link #FOLDER} in its project), so an agent whose sandbox keeps it inside its
 * project can still grep a session's history.
 *
 * <p>A session's log is {@code <session>.log}: the lines that scrolled off the top of its
 * screen, each once, in order. A full-screen program (the alternate screen) scrolls nothing
 * off, so for it the log gets its screen's lines, without the harness's chrome, as they
 * appear: each line not among the last {@link #RECENT_LINES} written (the bottom one once
 * it has held for a sample, as it may be still being drawn), under a
 * {@code --- microhm · <time> · screen ---} line when it took over the screen. Other such
 * lines mark a restarted session and lines that scrolled past before they could be copied.
 * (Sampling the screen each second and keeping only unseen lines keeps a streamed answer
 * whole, in order and about once, where copying the screen whenever it stopped changing
 * logged the same lines many times over, mid-answer and while the user typed.)
 *
 * <p>Nothing is deleted: once the live file would pass {@link #MAX_LIVE_LINES} lines it is
 * compressed to {@code <session>.<NNNN>.log.gz} (0001 the oldest) and started afresh. The
 * folder ignores itself for git ({@code .gitignore} holding {@code *}), and keeps each log's
 * progress in a hidden {@code .<session>.state} file so a restarted app neither repeats nor
 * skips lines.
 *
 * <p>Each {@link Log} is used under its own monitor.
 */
final class SessionLogs {

    static final String FOLDER = ".microhm-sessions";
    static final int MAX_LIVE_LINES = 8000;
    /** How many of the lines last written a full-screen program's line is checked against. */
    static final int RECENT_LINES = 400;

    private final ConcurrentHashMap<Path, Log> logs = new ConcurrentHashMap<>();

    /** The live log file of {@code session} for an agent working in {@code dir}. */
    static Path file(Path dir, String session) {
        return dir.resolve(FOLDER).resolve(safe(session) + ".log");
    }

    /** The log of {@code session} in {@code dir}'s folder, opened (and the folder made) on
     * first use. */
    Log open(Path dir, String session) {
        return logs.computeIfAbsent(file(dir, session), file -> Log.open(dir.resolve(FOLDER), safe(session)));
    }

    /** Forgets an open log (its files stay). */
    void close(Path file) {
        logs.remove(file);
    }

    private static String safe(String session) {
        return session.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    /** One session's log in one folder. */
    static final class Log {
        private final Path folder;
        private final String base;
        private final Path live;
        private final Path state;
        private long pid;
        private long added;
        private int lines;
        private int parts;
        /** Whether the previous record saw the alternate screen. */
        private boolean onAlternateScreen;
        /** The last row of the full screen the previous record saw. */
        private String lastRow;
        /** The last {@link #RECENT_LINES} lines written, oldest first, and how often each
         * is among them. */
        private final ArrayDeque<String> recent = new ArrayDeque<>();
        private final Map<String, Integer> recentCounts = new HashMap<>();

        private Log(Path folder, String base) {
            this.folder = folder;
            this.base = base;
            this.live = folder.resolve(base + ".log");
            this.state = folder.resolve("." + base + ".state");
        }

        static Log open(Path folder, String base) {
            Log log = new Log(folder, base);
            try {
                Files.createDirectories(folder);
                Path ignore = folder.resolve(".gitignore");
                if (!Files.exists(ignore)) {
                    Files.writeString(ignore, "*\n");
                }
                log.load();
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
            return log;
        }

        Path file() {
            return live;
        }

        /** The scrollback count to read from: what the log has, for the session it has. */
        long since() {
            return added;
        }

        /** The pid of the session the log follows; 0 before its first record. */
        long pid() {
            return pid;
        }

        /** Marks the start of another session under the same name (its scrollback counts
         * afresh: read it {@link #since() since} 0). */
        void restarted(long newPid, Instant now) {
            write(marker(now, "a new session (pid " + newPid + ")"));
            pid = newPid;
            added = 0;
            onAlternateScreen = false;
            lastRow = null;
            save();
        }

        /** Appends what {@code capture} (taken with its scrollback) adds: its new scrollback,
         * and on the alternate screen, where nothing scrolls off, the lines of its screen
         * reduced by {@code chrome} (the harness's {@code maskChrome}) that are not among
         * those written lately. */
        void record(Session.Capture capture, UnaryOperator<String> chrome, Instant now) {
            StringBuilder out = new StringBuilder();
            HeadlessTerminal.History history = java.util.Objects.requireNonNull(capture.history(), "history");
            long fresh = history.added() - Math.min(added, history.added());
            long got = count(history.text());
            if (fresh > got) {
                out.append(marker(now, (fresh - got) + " lines scrolled past before they could be copied"));
            }
            out.append(history.text());
            added = history.added();
            remember(history.text());
            if (history.alternateScreen()) {
                String screen = chrome.apply(capture.text() == null ? "" : capture.text());
                List<String> rows = screen.lines().map(String::stripTrailing).filter(l -> !l.isBlank()).toList();
                // the last row may be still being drawn: it waits until it has held for a sample
                String last = rows.isEmpty() ? null : rows.getLast();
                boolean lastHeld = last != null && (last.equals(lastRow) || !capture.alive());
                lastRow = last;
                StringBuilder unseen = new StringBuilder();
                for (int i = 0; i < rows.size(); i++) {
                    String line = rows.get(i);
                    if ((i < rows.size() - 1 || lastHeld) && !recentCounts.containsKey(line)) {
                        unseen.append(line).append('\n');
                        remember(line + "\n");
                    }
                }
                if (!unseen.isEmpty()) {
                    if (!onAlternateScreen) {
                        out.append(marker(now, "screen"));
                    }
                    out.append(unseen);
                    onAlternateScreen = true;
                }
            } else {
                onAlternateScreen = false;
                lastRow = null;
            }
            pid = capture.processId();
            write(out.toString());
            save();
        }

        /** Adds {@code text}'s lines to the recent ones, letting the oldest go. */
        private void remember(String text) {
            if (text.isEmpty()) {
                return;
            }
            for (String line : text.split("\n")) {
                line = line.stripTrailing();
                if (line.isBlank()) {
                    continue;
                }
                recent.addLast(line);
                recentCounts.merge(line, 1, Integer::sum);
                if (recent.size() > RECENT_LINES) {
                    recentCounts.computeIfPresent(recent.removeFirst(), (k, n) -> n == 1 ? null : n - 1);
                }
            }
        }

        private void write(String text) {
            if (text.isEmpty()) {
                return;
            }
            int n = count(text);
            try {
                if (lines > 0 && lines + n > MAX_LIVE_LINES) {
                    roll();
                }
                Files.writeString(live, text, StandardCharsets.UTF_8, StandardOpenOption.CREATE,
                        StandardOpenOption.APPEND);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
            lines += n;
        }

        /** Compresses the live file into the next part and empties it. */
        private void roll() throws IOException {
            Path part;
            do {
                parts++;
                part = folder.resolve(base + "." + String.format("%04d", parts) + ".log.gz");
            } while (Files.exists(part));
            Path partial = folder.resolve("." + part.getFileName() + ".tmp");
            try (InputStream in = Files.newInputStream(live);
                 OutputStream gz = new GZIPOutputStream(Files.newOutputStream(partial))) {
                in.transferTo(gz);
            }
            Files.move(partial, part, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            Files.writeString(live, "", StandardCharsets.UTF_8);
            lines = 0;
        }

        private void load() throws IOException {
            if (Files.exists(state)) {
                Properties p = new Properties();
                try (Reader in = Files.newBufferedReader(state, StandardCharsets.UTF_8)) {
                    p.load(in);
                }
                pid = number(p, "pid");
                added = number(p, "added");
                parts = (int) number(p, "parts");
            }
            if (Files.exists(live)) {
                List<String> all = Files.readAllLines(live, StandardCharsets.UTF_8);
                lines = all.size();
                remember(String.join("\n", all.subList(Math.max(0, all.size() - RECENT_LINES), all.size())));
            }
        }

        private void save() {
            Properties p = new Properties();
            p.setProperty("pid", Long.toString(pid));
            p.setProperty("added", Long.toString(added));
            p.setProperty("parts", Integer.toString(parts));
            Path partial = folder.resolve("." + base + ".state.tmp");
            try {
                try (Writer out = Files.newBufferedWriter(partial, StandardCharsets.UTF_8)) {
                    p.store(out, "microhm session log progress");
                }
                Files.move(partial, state, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            } catch (IOException e) {
                throw new UncheckedIOException(e);
            }
        }

        private static long number(Properties p, String key) {
            try {
                return Long.parseLong(p.getProperty(key, "0").strip());
            } catch (NumberFormatException e) {
                return 0;
            }
        }

        private static String marker(Instant now, String what) {
            return "--- microhm · " + now.truncatedTo(ChronoUnit.SECONDS) + " · " + what + " ---\n";
        }

        private static int count(String text) {
            int n = 0;
            for (int i = 0; i < text.length(); i++) {
                if (text.charAt(i) == '\n') {
                    n++;
                }
            }
            return n;
        }
    }
}
