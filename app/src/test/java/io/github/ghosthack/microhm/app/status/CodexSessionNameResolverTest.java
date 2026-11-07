package io.github.ghosthack.microhm.app.status;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.FileTime;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class CodexSessionNameResolverTest {

    @Test
    void resolvesLatestSavedNameForActiveRollout(@TempDir Path codexHome) throws Exception {
        String id = "01a0299e-d978-7651-871e-e746fedd1186";
        Path rollout = codexHome.resolve("sessions/2026/08/22/rollout-2026-08-22T00-00-00-" + id + ".jsonl");
        Files.createDirectories(rollout.getParent());
        Files.writeString(rollout, "");
        Files.writeString(codexHome.resolve("session_index.jsonl"), """
                {"id":"%s","thread_name":"old name","updated_at":"2026-08-22T00:00:00Z"}
                {not-yet-complete
                {"id":"%s","thread_name":"new name","updated_at":"2026-08-22T00:01:00Z"}
                """.formatted(id, id));

        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(rollout));

        assertEquals("new name", resolver.resolve(42).orElseThrow());
    }

    @Test
    void missingRenameFallsBackCleanly(@TempDir Path codexHome) throws Exception {
        Path rollout = codexHome.resolve("rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl");
        Files.writeString(rollout, "");
        Files.writeString(codexHome.resolve("session_index.jsonl"), """
                {"id":"someone-else","thread_name":"not this chat"}
                """);

        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(rollout));

        assertTrue(resolver.resolve(42).isEmpty());
        assertTrue(resolver.resolve(-1).isEmpty());
    }

    @Test
    void unnamedExistingChatUsesFirstRealUserPromptAsPreview(@TempDir Path codexHome) throws Exception {
        String id = "01a0299e-d978-7651-871e-e746fedd1186";
        Path rollout = codexHome.resolve("rollout-" + id + ".jsonl");
        Files.writeString(rollout,
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                        + "\"content\":[{\"type\":\"input_text\",\"text\":"
                        + "\"<environment_context>generated metadata</environment_context>\"}]}}\n"
                        + "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                        + "\"content\":[{\"type\":\"input_text\",\"text\":"
                        + "\"Fix the sidebar\\nname inheritance\"}]}}\n");
        Files.writeString(codexHome.resolve("session_index.jsonl"), "");
        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(rollout));

        assertEquals("Fix the sidebar name inheritance", resolver.resolve(42).orElseThrow());
    }

    @Test
    void transcriptIsTheOpenRolloutAndEmptyWithoutAPane(@TempDir Path codexHome) {
        Path rollout = codexHome.resolve("sessions/../rollout-01a0299e-d978-7651-871e-e746fedd1186.jsonl");
        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, pid -> pid == 42 ? Optional.of(rollout) : Optional.empty());

        assertEquals(rollout.toAbsolutePath().normalize(), resolver.transcript(42).orElseThrow());
        assertTrue(resolver.transcript(7).isEmpty());
        assertTrue(resolver.transcript(0).isEmpty());
    }

    @Test
    void indexIsParsedOnlyWhenItChangesAndAppendsAreFolded(@TempDir Path codexHome) throws Exception {
        String id = "01a0299e-d978-7651-871e-e746fedd1186";
        Path index = codexHome.resolve("session_index.jsonl");
        Files.writeString(index, "{\"id\":\"%s\",\"thread_name\":\"first\"}\n".formatted(id));
        Files.setLastModifiedTime(index, FileTime.fromMillis(1_000_000));
        CodexSessionIndex sessionIndex = new CodexSessionIndex(index);

        for (int i = 0; i < 5; i++) {
            assertEquals("first", sessionIndex.name(id).orElseThrow());
        }
        assertEquals(1, sessionIndex.parseCount());

        // A half-written append is ignored if it does not parse, and completed later.
        Files.writeString(index, "{\"id\":\"other\",\"thread_name\":\"x\"}\n{\"id\":\"%s\",\"thr"
                .formatted(id), StandardOpenOption.APPEND);
        Files.setLastModifiedTime(index, FileTime.fromMillis(2_000_000));
        assertEquals("first", sessionIndex.name(id).orElseThrow());
        assertEquals("x", sessionIndex.name("other").orElseThrow());
        assertEquals(2, sessionIndex.parseCount());
        Files.writeString(index, "ead_name\":\"second\"}", StandardOpenOption.APPEND);
        Files.setLastModifiedTime(index, FileTime.fromMillis(3_000_000));
        assertEquals("second", sessionIndex.name(id).orElseThrow());
        Files.writeString(index, "\n", StandardOpenOption.APPEND);
        Files.setLastModifiedTime(index, FileTime.fromMillis(3_500_000));
        assertEquals("second", sessionIndex.name(id).orElseThrow());
        assertEquals("x", sessionIndex.name("other").orElseThrow());
        assertEquals(4, sessionIndex.parseCount());

        // A rewritten, shorter file is parsed afresh.
        Files.writeString(index, "{\"id\":\"%s\",\"thread_name\":\"third\"}\n".formatted(id));
        Files.setLastModifiedTime(index, FileTime.fromMillis(4_000_000));
        assertEquals("third", sessionIndex.name(id).orElseThrow());
        assertTrue(sessionIndex.name("other").isEmpty());

        Files.delete(index);
        assertTrue(sessionIndex.name(id).isEmpty());
    }

    @Test
    void resolverPicksUpARenameAppendedLater(@TempDir Path codexHome) throws Exception {
        String id = "01a0299e-d978-7651-871e-e746fedd1186";
        Path rollout = codexHome.resolve("rollout-" + id + ".jsonl");
        Files.writeString(rollout, "");
        Path index = codexHome.resolve("session_index.jsonl");
        Files.writeString(index, "");
        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(rollout));

        assertTrue(resolver.resolve(42).isEmpty());
        Files.writeString(index, "{\"id\":\"%s\",\"thread_name\":\"named\"}\n".formatted(id));
        assertEquals("named", resolver.resolve(42).orElseThrow());
    }

    @Test
    void emptyPreviewIsRetriedOnceTheRolloutGrows(@TempDir Path codexHome) throws Exception {
        String id = "01a0299e-d978-7651-871e-e746fedd1186";
        Path rollout = codexHome.resolve("rollout-" + id + ".jsonl");
        Files.writeString(rollout, "");
        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(rollout));

        assertTrue(resolver.resolve(42).isEmpty());
        Files.writeString(rollout,
                "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\","
                        + "\"content\":[{\"type\":\"input_text\",\"text\":\"Hello there\"}]}}\n");
        assertEquals("Hello there", resolver.resolve(42).orElseThrow());
    }

    @Test
    void previewCacheIsBounded(@TempDir Path codexHome) throws Exception {
        AtomicReference<Path> current = new AtomicReference<>();
        CodexSessionNameResolver resolver = new CodexSessionNameResolver(
                codexHome, ignored -> Optional.of(current.get()));
        for (int i = 0; i < CodexSessionNameResolver.PREVIEW_CACHE_LIMIT + 50; i++) {
            Path rollout = codexHome.resolve(
                    "rollout-01a0299e-d978-7651-871e-%012d.jsonl".formatted(i));
            Files.writeString(rollout, "");
            current.set(rollout);
            resolver.resolve(42);
        }
        assertEquals(CodexSessionNameResolver.PREVIEW_CACHE_LIMIT, resolver.previewCacheSize());
    }
}
