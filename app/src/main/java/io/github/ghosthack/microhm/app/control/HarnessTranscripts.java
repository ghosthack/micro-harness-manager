package io.github.ghosthack.microhm.app.control;

import io.github.ghosthack.microhm.app.harness.ClaudeProjects;
import io.github.ghosthack.microhm.app.harness.GrokSessions;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.harness.MuseSessions;
import io.github.ghosthack.microhm.app.status.CodexSessionNameResolver;
import io.github.ghosthack.microhm.app.status.OpenFileLocator;

import java.nio.file.Path;
import java.util.Comparator;
import java.util.Objects;
import java.util.Optional;
import java.util.function.LongFunction;

/**
 * The transcript locations the app knows:
 * <ul>
 *   <li>Codex: the rollout file its process has open (found from the pane's process tree,
 *       see {@link CodexSessionNameResolver#transcript});</li>
 *   <li>Claude Code: its per-project JSONL directory ({@link ClaudeProjects}): the
 *       session's own {@code <id>.jsonl} when the id is known (nothing until Claude has
 *       written it), else the project's newest file — which the caller must not present
 *       as this session's when other Claude sessions share the project;</li>
 *   <li>Muse: the {@code session.jsonl} of the session directory whose lock its process
 *       holds open ({@link MuseSessions});</li>
 *   <li>Grok: the {@code chat_history.jsonl} of the session its process registered in
 *       {@code active_sessions.json} ({@link GrokSessions}).</li>
 * </ul>
 * Other harnesses have none (yet).
 */
public final class HarnessTranscripts implements TranscriptLocator {

    private final Path claudeProjects;
    private final CodexSessionNameResolver codex;
    private final LongFunction<Optional<Path>> muse;
    private final LongFunction<Optional<Path>> grok;

    /** Claude Code and Codex only (tests of those). */
    public HarnessTranscripts(Path claudeProjects, CodexSessionNameResolver codex) {
        this(claudeProjects, codex, pane -> Optional.empty(), pane -> Optional.empty());
    }

    /**
     * @param muse a pane's Muse transcript, from the pane's shell pid
     * @param grok a pane's Grok transcript, from the pane's shell pid
     */
    public HarnessTranscripts(Path claudeProjects, CodexSessionNameResolver codex,
                              LongFunction<Optional<Path>> muse, LongFunction<Optional<Path>> grok) {
        this.claudeProjects = claudeProjects;
        this.codex = codex;
        this.muse = Objects.requireNonNull(muse, "muse");
        this.grok = Objects.requireNonNull(grok, "grok");
    }

    /** {@code ~/.claude/projects} (or {@code $CLAUDE_CONFIG_DIR/projects}), the default
     * Codex home, Muse's sessions under its data directory and {@code $GROK_HOME}. */
    public static HarnessTranscripts standard() {
        Path museRoot = MuseSessions.root();
        Path grokHome = GrokSessions.home();
        return new HarnessTranscripts(ClaudeProjects.root(), new CodexSessionNameResolver(),
                OpenFileLocator.overLsof(MuseSessions::isExecutable, open -> MuseSessions.transcriptOf(museRoot, open)),
                pane -> grokTranscript(grokHome, pane));
    }

    /** The newest transcript of the Grok processes under the pane. */
    static Optional<Path> grokTranscript(Path grokHome, long paneProcessId) {
        return OpenFileLocator.processes(paneProcessId, GrokSessions::isExecutable).stream()
                .map(process -> GrokSessions.transcript(grokHome, process.pid(), process.startMillis()))
                .flatMap(Optional::stream)
                .max(Comparator.comparingLong(path -> path.toFile().lastModified()));
    }

    @Override
    public Optional<Path> transcript(HarnessType harness, Path project, Optional<String> harnessSessionId,
                                     long paneProcessId) {
        try {
            return switch (harness) {
                case CODEX -> codex.transcript(paneProcessId);
                case CLAUDE_CODE -> claude(project, harnessSessionId);
                case MUSE -> paneProcessId > 0 ? muse.apply(paneProcessId) : Optional.empty();
                case GROK -> paneProcessId > 0 ? grok.apply(paneProcessId) : Optional.empty();
                default -> Optional.empty();
            };
        } catch (RuntimeException e) {
            return Optional.empty();
        }
    }

    private Optional<Path> claude(Path project, Optional<String> harnessSessionId) {
        if (harnessSessionId.isPresent()) {
            // never another session's file: a known id whose conversation has no message
            // yet has no transcript
            return ClaudeProjects.transcript(claudeProjects, project, harnessSessionId.get());
        }
        return ClaudeProjects.newest(claudeProjects, project);
    }
}
