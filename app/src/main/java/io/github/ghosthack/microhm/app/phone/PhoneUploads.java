package io.github.ghosthack.microhm.app.phone;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.FileTime;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;

/**
 * Files sent from the phone page (a screenshot of the problem, say), kept in one folder so
 * a prompt can name them by path: the session's project's {@code .microhm/uploads}, where
 * the agent may read without asking, else a folder beside the registry. Each gets a fresh
 * name; files older than {@link #KEEP} are removed as new ones arrive.
 */
final class PhoneUploads {

    /** Big enough for a phone photo or a screen recording clip. */
    static final long MAX_BYTES = 25L * 1024 * 1024;
    static final Duration KEEP = Duration.ofDays(7);

    private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss");
    private static final int MAX_STEM = 60;
    private static final Map<String, String> EXTENSIONS = Map.of(
            "image/png", ".png", "image/jpeg", ".jpg", "image/gif", ".gif", "image/webp", ".webp",
            "image/heic", ".heic", "application/pdf", ".pdf", "text/plain", ".txt", "video/quicktime", ".mov",
            "video/mp4", ".mp4");

    /** The hidden folder in a project; it ignores itself in git ({@code .gitignore}: {@code *}). */
    static final String PROJECT_FOLDER = ".microhm";

    private final Path dir;
    private final Clock clock;
    /** A folder to keep out of git once it exists, or null. */
    private final Path ignored;
    private final SecureRandom random = new SecureRandom();

    PhoneUploads(Path dir, Clock clock) {
        this(dir, clock, null);
    }

    private PhoneUploads(Path dir, Clock clock, Path ignored) {
        this.dir = dir;
        this.clock = clock;
        this.ignored = ignored;
    }

    /** Uploads kept in {@code project/.microhm/uploads}. */
    static PhoneUploads inProject(Path project, Clock clock) {
        Path folder = project.resolve(PROJECT_FOLDER);
        return new PhoneUploads(folder.resolve("uploads"), clock, folder);
    }

    /** Whether {@code project} is a folder uploads can go into. */
    static boolean usableProject(String project) {
        if (project == null || project.isBlank()) {
            return false;
        }
        try {
            Path path = Path.of(project);
            return path.isAbsolute() && Files.isDirectory(path) && Files.isWritable(path);
        } catch (java.nio.file.InvalidPathException e) {
            return false;
        }
    }

    /** Thrown when the body is larger than {@link #MAX_BYTES}; nothing is kept. */
    static final class TooLarge extends IOException {
        TooLarge() {
            super("that file is larger than " + MAX_BYTES / (1024 * 1024) + " MB");
        }
    }

    /** Saves {@code body} and answers the absolute path it was saved at. */
    Path save(InputStream body, String name, String contentType) throws IOException {
        Files.createDirectories(dir);
        if (ignored != null) {
            Path gitignore = ignored.resolve(".gitignore");
            if (!Files.exists(gitignore)) {
                Files.writeString(gitignore, "# Microhm's own files (uploads from the phone page)\n*\n");
            }
        }
        prune();
        Path target = dir.resolve(fileName(name, contentType));
        long written = 0;
        try (OutputStream out = Files.newOutputStream(target, StandardOpenOption.CREATE_NEW)) {
            byte[] buffer = new byte[64 * 1024];
            int n;
            while ((n = body.read(buffer)) > 0) {
                written += n;
                if (written > MAX_BYTES) {
                    throw new TooLarge();
                }
                out.write(buffer, 0, n);
            }
        } catch (IOException | RuntimeException e) {
            Files.deleteIfExists(target);
            throw e;
        }
        if (written == 0) {
            Files.deleteIfExists(target);
            throw new IOException("the file was empty");
        }
        return target.toAbsolutePath();
    }

    /** {@code 20261120-153012-a1b2-<name>}: sortable, unique, and safe in a prompt or a shell
     * (letters, digits, dot, dash and underscore only). */
    String fileName(String name, String contentType) {
        String base = name == null ? "" : name.replace('\\', '/');
        base = base.substring(base.lastIndexOf('/') + 1);
        String extension = "";
        int dot = base.lastIndexOf('.');
        if (dot > 0) {
            extension = clean(base.substring(dot)).toLowerCase(Locale.ROOT);
            base = base.substring(0, dot);
            if (extension.length() > 10 || extension.length() < 2) {
                extension = "";
            }
        }
        if (extension.isEmpty() && contentType != null) {
            extension = EXTENSIONS.getOrDefault(contentType.split(";")[0].trim().toLowerCase(Locale.ROOT), "");
        }
        String stem = clean(base).replaceAll("^[._-]+", "");
        if (stem.length() > MAX_STEM) {
            stem = stem.substring(0, MAX_STEM);
        }
        if (stem.isEmpty()) {
            stem = "upload";
        }
        byte[] tag = new byte[2];
        random.nextBytes(tag);
        String stamp = LocalDateTime.ofInstant(clock.instant(), ZoneId.systemDefault()).format(STAMP);
        return stamp + "-" + HexFormat.of().formatHex(tag) + "-" + stem + extension;
    }

    private static String clean(String text) {
        return text.replaceAll("[^A-Za-z0-9._-]+", "_");
    }

    /** Removes files older than {@link #KEEP}; best effort. */
    void prune() {
        FileTime cutoff = FileTime.from(clock.instant().minus(KEEP));
        try (DirectoryStream<Path> files = Files.newDirectoryStream(dir)) {
            for (Path file : files) {
                try {
                    if (Files.isRegularFile(file) && Files.getLastModifiedTime(file).compareTo(cutoff) < 0) {
                        Files.delete(file);
                    }
                } catch (IOException ignored) {
                    // in use or gone: the next upload tries again
                }
            }
        } catch (IOException ignored) {
            // no folder yet
        }
    }
}
