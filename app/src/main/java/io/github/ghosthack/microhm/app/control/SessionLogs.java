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
import java.util.Properties;
import java.util.concurrent.ConcurrentHashMap;
import java.util.zip.GZIPOutputStream;

/**
 * Plain-text copies of sessions' output, written into the folder of the agent that asked
 * about them ({@link #FOLDER} in its project), so an agent whose sandbox keeps it inside its
 * project can still grep a session's history.
 *
 * <p>A session's log is {@code <session>.log}: the lines that scrolled off the top of its
 * screen, each once, in order. A full-screen program (the alternate screen) scrolls nothing
 * off, so for it the log gets a copy of the screen each time it settles on something new, under a
 * {@code --- microhm · <time> · screen ---} line. Other such lines mark a restarted session
 * and lines that scrolled past before they could be copied.
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
        private int snapshotHash;
        /** The screen the previous record saw, to tell when it has settled. */
        private String lastScreen;

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
            lastScreen = null;
            snapshotHash = 0;
            save();
        }

        /** Appends what {@code capture} (taken with its scrollback) adds: its new scrollback,
         * and on the alternate screen, where nothing scrolls off, a copy of the screen when
         * it has settled on something new (or the session ended). */
        void record(Session.Capture capture, Instant now) {
            StringBuilder out = new StringBuilder();
            HeadlessTerminal.History history = java.util.Objects.requireNonNull(capture.history(), "history");
            long fresh = history.added() - Math.min(added, history.added());
            long got = count(history.text());
            if (fresh > got) {
                out.append(marker(now, (fresh - got) + " lines scrolled past before they could be copied"));
            }
            out.append(history.text());
            added = history.added();
            if (history.alternateScreen()) {
                String screen = withoutTrailingBlankLines(capture.text() == null ? "" : capture.text());
                boolean settled = screen.equals(lastScreen) || !capture.alive();
                if (settled && !screen.isBlank() && screen.hashCode() != snapshotHash) {
                    out.append(marker(now, "screen")).append(screen);
                    snapshotHash = screen.hashCode();
                }
                lastScreen = screen;
            } else {
                lastScreen = null;
            }
            pid = capture.processId();
            write(out.toString());
            save();
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
                snapshotHash = (int) number(p, "snapshot");
            }
            if (Files.exists(live)) {
                try (InputStream in = Files.newInputStream(live)) {
                    byte[] buffer = new byte[64 * 1024];
                    for (int read; (read = in.read(buffer)) > 0; ) {
                        for (int i = 0; i < read; i++) {
                            if (buffer[i] == '\n') {
                                lines++;
                            }
                        }
                    }
                }
            }
        }

        private void save() {
            Properties p = new Properties();
            p.setProperty("pid", Long.toString(pid));
            p.setProperty("added", Long.toString(added));
            p.setProperty("parts", Integer.toString(parts));
            p.setProperty("snapshot", Integer.toString(snapshotHash));
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

        /** {@code text} without blank lines at its end, ending with one newline (or empty). */
        private static String withoutTrailingBlankLines(String text) {
            String stripped = text.stripTrailing();
            return stripped.isEmpty() ? "" : stripped + "\n";
        }
    }
}
