package io.github.ghosthack.microhm.app.status;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.function.LongFunction;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Resolves Codex's saved {@code /rename} name without reading conversation content.
 * Codex keeps the name in {@code session_index.jsonl}; the active rollout file held by
 * the pane's Codex process supplies the thread id used to select the matching row.
 * Public so the MCP session controller can also point agents at a live Codex session's
 * transcript ({@link #transcript}). Thread-safe. A call may block for a couple of
 * seconds ({@code lsof}) the first time it meets a Codex process, so never call it on
 * the EDT; after that the process's rollout and the parsed index are cached
 * ({@link CodexRolloutLocator}, {@link CodexSessionIndex}). */
public final class CodexSessionNameResolver {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Pattern THREAD_ID = Pattern.compile(
            "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.jsonl$");

    /** Bound on remembered first-prompt previews: one per recently seen rollout. */
    static final int PREVIEW_CACHE_LIMIT = 128;

    private final Path codexHome;
    private final LongFunction<Optional<Path>> rolloutLocator;
    private final CodexSessionIndex sessionIndex;
    /** Rollout → first-prompt preview, least recently used dropped first. An empty
     * preview remembers the rollout's size so it is retried once the file grows. */
    private final Map<Path, Preview> previewCache = new LinkedHashMap<>(16, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<Path, Preview> eldest) {
            return size() > PREVIEW_CACHE_LIMIT;
        }
    };

    private record Preview(String text, long rolloutSize) { }

    /** Over {@code $CODEX_HOME}, else {@code ~/.codex}. */
    public CodexSessionNameResolver() {
        this(codexHome());
    }

    private CodexSessionNameResolver(Path codexHome) {
        this(codexHome, new CodexRolloutLocator(
                codexHome.toAbsolutePath().normalize().resolve("sessions")));
    }

    /** Over an explicit Codex home, finding a pane's open rollout file with
     * {@code rolloutLocator} — tests inject one instead of {@code lsof}. */
    public CodexSessionNameResolver(Path codexHome, LongFunction<Optional<Path>> rolloutLocator) {
        this.codexHome = codexHome.toAbsolutePath().normalize();
        this.rolloutLocator = rolloutLocator;
        this.sessionIndex = new CodexSessionIndex(this.codexHome.resolve("session_index.jsonl"));
    }

    /**
     * The rollout ({@code rollout-…-<thread id>.jsonl}) the Codex process under the
     * pane's shell {@code paneProcessId} currently has open — the session's transcript —
     * or empty when no Codex runs there or it cannot be told.
     */
    public Optional<Path> transcript(long paneProcessId) {
        if (paneProcessId <= 0) {
            return Optional.empty();
        }
        return rolloutLocator.apply(paneProcessId).map(path -> path.toAbsolutePath().normalize());
    }

    /** The session's saved {@code /rename} name, else its first real prompt, else empty. */
    public Optional<String> resolve(long paneProcessId) {
        if (paneProcessId <= 0) {
            return Optional.empty();
        }
        Optional<Path> rollout = rolloutLocator.apply(paneProcessId);
        if (rollout.isEmpty()) {
            return Optional.empty();
        }
        Matcher id = THREAD_ID.matcher(rollout.get().getFileName().toString());
        if (!id.find()) {
            return Optional.empty();
        }
        Optional<String> savedName = nameFromIndex(id.group(1));
        if (savedName.isPresent()) {
            return savedName;
        }
        // Codex's history UI uses the first real user prompt as the preview for an
        // unnamed thread. Mirror that instead of falling all the way back to the cwd.
        Path rolloutPath = rollout.get().toAbsolutePath().normalize();
        String preview = preview(rolloutPath);
        return preview.isEmpty() ? Optional.empty() : Optional.of(preview);
    }

    /** Remembered previews (for tests). */
    int previewCacheSize() {
        synchronized (previewCache) {
            return previewCache.size();
        }
    }

    private String preview(Path rollout) {
        synchronized (previewCache) {
            Preview cached = previewCache.get(rollout);
            if (cached != null && (!cached.text().isEmpty() || cached.rolloutSize() == size(rollout))) {
                return cached.text();
            }
        }
        long size = size(rollout);
        String text = previewFromRollout(rollout).orElse("");
        synchronized (previewCache) {
            previewCache.put(rollout, new Preview(text, size));
        }
        return text;
    }

    private static long size(Path path) {
        try {
            return Files.size(path);
        } catch (IOException e) {
            return -1;
        }
    }

    private Optional<String> nameFromIndex(String threadId) {
        return sessionIndex.name(threadId);
    }

    private static Optional<String> previewFromRollout(Path rollout) {
        if (!Files.isRegularFile(rollout)) {
            return Optional.empty();
        }
        try (BufferedReader lines = Files.newBufferedReader(rollout)) {
            for (String line; (line = lines.readLine()) != null; ) {
                JsonNode row;
                try {
                    row = MAPPER.readTree(line);
                } catch (IOException ignored) {
                    continue;
                }
                JsonNode payload = row.path("payload");
                if (!"response_item".equals(row.path("type").asText())
                        || !"message".equals(payload.path("type").asText())
                        || !"user".equals(payload.path("role").asText())) {
                    continue;
                }
                for (JsonNode content : payload.path("content")) {
                    if (!"input_text".equals(content.path("type").asText())) {
                        continue;
                    }
                    String text = content.path("text").asText().strip();
                    // The CLI records launch context as a synthetic user item before
                    // the user's actual prompt. It is metadata, never a chat preview.
                    if (text.isEmpty() || text.startsWith("<environment_context>")) {
                        continue;
                    }
                    String oneLine = text.replaceAll("[\\r\\n\\t]+", " ")
                            .replaceAll(" {2,}", " ").strip();
                    return Optional.of(oneLine);
                }
            }
        } catch (IOException ignored) {
            return Optional.empty();
        }
        return Optional.empty();
    }

    private static Path codexHome() {
        String configured = System.getenv("CODEX_HOME");
        if (configured != null && !configured.isBlank()) {
            return Path.of(configured);
        }
        return Path.of(System.getProperty("user.home"), ".codex");
    }
}
