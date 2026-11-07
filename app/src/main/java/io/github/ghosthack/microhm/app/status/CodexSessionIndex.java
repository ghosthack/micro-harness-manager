package io.github.ghosthack.microhm.app.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

/** Codex's {@code session_index.jsonl} parsed into thread id → latest non-blank
 * {@code thread_name}, re-read only when the file's size or mtime changes. Codex only
 * appends to it, so when it merely grew just the appended bytes are parsed; a shrunk or
 * replaced file (different file key, or the byte before the parsed prefix no longer a
 * newline) is parsed again from the start. A trailing line without its newline yet is
 * honoured but not committed, so it is parsed again once complete. Thread-safe. */
final class CodexSessionIndex {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final Path file;
    private final Map<String, String> names = new HashMap<>();
    /** The last line without a terminating newline, if it parsed: overrides {@link #names}. */
    private String pendingId;
    private String pendingName;
    /** Bytes of complete lines already folded into {@link #names}. */
    private long committedOffset;
    private long seenSize = -1;
    private long seenModified = Long.MIN_VALUE;
    private Object seenFileKey;
    private int parses;

    CodexSessionIndex(Path file) {
        this.file = file;
    }

    synchronized Optional<String> name(String threadId) {
        if (!refresh()) {
            return Optional.empty();
        }
        if (threadId.equals(pendingId)) {
            return Optional.of(pendingName);
        }
        return Optional.ofNullable(names.get(threadId));
    }

    /** How many times the file has been (fully or incrementally) read (for tests). */
    synchronized int parseCount() {
        return parses;
    }

    /** Brings the cache up to date; false when the index cannot be read. */
    private boolean refresh() {
        BasicFileAttributes attributes;
        try {
            attributes = Files.readAttributes(file, BasicFileAttributes.class);
        } catch (IOException e) {
            reset();
            return false;
        }
        if (!attributes.isRegularFile()) {
            reset();
            return false;
        }
        long size = attributes.size();
        long modified = attributes.lastModifiedTime().toMillis();
        Object fileKey = attributes.fileKey();
        if (size == seenSize && modified == seenModified && Objects.equals(fileKey, seenFileKey)) {
            return true;
        }
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.READ)) {
            boolean appendOnly = seenSize >= 0 && Objects.equals(fileKey, seenFileKey)
                    && size >= committedOffset && endsWithNewlineAt(channel, committedOffset);
            if (!appendOnly) {
                names.clear();
                committedOffset = 0;
            }
            parseFrom(channel, committedOffset);
        } catch (IOException e) {
            reset();
            return false;
        }
        seenSize = size;
        seenModified = modified;
        seenFileKey = fileKey;
        parses++;
        return true;
    }

    /** Whether the parsed prefix still ends where it did: offset 0, or a newline just before. */
    private static boolean endsWithNewlineAt(FileChannel channel, long offset) throws IOException {
        if (offset == 0) {
            return true;
        }
        ByteBuffer one = ByteBuffer.allocate(1);
        return channel.read(one, offset - 1) == 1 && one.get(0) == '\n';
    }

    private void parseFrom(FileChannel channel, long offset) throws IOException {
        long remaining = channel.size() - offset;
        if (remaining > Integer.MAX_VALUE - 8) {
            throw new IOException("session index too large");
        }
        ByteBuffer buffer = ByteBuffer.allocate((int) Math.max(remaining, 0));
        long position = offset;
        while (buffer.hasRemaining()) {
            int read = channel.read(buffer, position);
            if (read < 0) {
                break;
            }
            position += read;
        }
        byte[] bytes = buffer.array();
        int length = buffer.position();
        pendingId = null;
        pendingName = null;
        int lineStart = 0;
        for (int i = 0; i < length; i++) {
            if (bytes[i] == '\n') {
                fold(new String(bytes, lineStart, i - lineStart, StandardCharsets.UTF_8));
                lineStart = i + 1;
            }
        }
        committedOffset = offset + lineStart;
        if (lineStart < length) {
            // Possibly a half-written append: use it if it parses, re-read it next time.
            parseRow(new String(bytes, lineStart, length - lineStart, StandardCharsets.UTF_8))
                    .ifPresent(row -> {
                        pendingId = row[0];
                        pendingName = row[1];
                    });
        }
    }

    private void fold(String line) {
        parseRow(line).ifPresent(row -> names.put(row[0], row[1]));
    }

    /** {@code [id, name]} for a row carrying a non-blank name. */
    private static Optional<String[]> parseRow(String line) {
        try {
            JsonNode row = MAPPER.readTree(line);
            if (row == null) {
                return Optional.empty();
            }
            String name = row.path("thread_name").asText().strip();
            if (name.isEmpty()) {
                return Optional.empty();
            }
            return Optional.of(new String[] {row.path("id").asText(), name});
        } catch (IOException ignored) {
            // One partial/corrupt append must not hide an earlier valid rename.
            return Optional.empty();
        }
    }

    private void reset() {
        names.clear();
        pendingId = null;
        pendingName = null;
        committedOffset = 0;
        seenSize = -1;
        seenModified = Long.MIN_VALUE;
        seenFileKey = null;
    }
}
