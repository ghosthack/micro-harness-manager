package io.github.ghosthack.microhm.app.session;

import io.github.ghosthack.microhm.app.harness.HarnessPlugin;
import io.github.ghosthack.microhm.app.harness.HarnessPlugins;
import io.github.ghosthack.microhm.app.harness.HarnessType;
import io.github.ghosthack.microhm.app.harness.McpEndpoint;
import io.github.ghosthack.microhm.app.host.SessionHost;
import io.github.ghosthack.microhm.app.mcp.McpService.McpLink;
import io.github.ghosthack.microhm.app.registry.SessionEntry;
import io.github.ghosthack.microhm.app.registry.SessionNaming;
import io.github.ghosthack.microhm.app.registry.SessionRegistry;
import io.github.ghosthack.microhm.app.settings.AppSettings;
import io.github.ghosthack.microhm.app.terminal.SessionTerminal;
import io.github.ghosthack.microhm.mux.client.SessionServerException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.FileAttribute;
import java.nio.file.attribute.PosixFilePermissions;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;

/**
 * Creates and resumes registered sessions: the blocking body behind the window's
 * Open…/Duplicate/Shell-here/Resume actions, and behind the MCP {@code spawn} tool. Free
 * of Swing and safe from any non-EDT thread — every call blocks on host round trips (and
 * {@code sendKeys}' deliberate 400 ms pause), so never call it on the EDT.
 *
 * <p>A launch is: a unique {@code mhm-} name, the daemon session at the standard
 * terminal size, the {@code harness}/{@code project}/{@code display} labels (best
 * effort), the harness launch command typed into its shell, and the registry row. When
 * the MCP service is running, the launch command also registers the app's MCP server
 * for that session (see {@link HarnessPlugin#withMcpServer}).
 *
 * <p>The MCP token is never typed: a harness that reads it from the environment
 * ({@link HarnessPlugin#usesMcpTokenEnv}) gets a session started with it in its
 * {@value HarnessPlugin#MCP_TOKEN_ENV} environment variable — no other session carries
 * it — and a harness that reads its MCP config from a file gets an owner-only
 * {@code <mcpConfigDir>/<session>.json} (rewritten on resume; {@link #discardMcpConfig}
 * deletes it once the session is gone). A daemon that predates per-session
 * environments starts the session without the variable; such a session is launched
 * without MCP (logged), since its harness could not authenticate.
 */
public final class SessionLauncher {

    private static final Logger LOG = LoggerFactory.getLogger(SessionLauncher.class);

    /** Label keys every launched session carries. */
    public static final String LABEL_HARNESS = "harness";
    public static final String LABEL_PROJECT = "project";
    public static final String LABEL_DISPLAY = "display";

    private final SessionRegistry registry;
    private final SessionHost host;
    private final Function<String, McpLink> mcpLinkFor;
    private final Path mcpConfigDir;
    private final SessionLabeller labeller;
    private final EnvSessionStarter envStarter;

    /** How many times {@link #reserveName} re-derives before giving up. */
    static final int MAX_NAME_ATTEMPTS = 32;

    /** Names derived but not yet visible to the host or registry; guarded by itself. */
    private final Set<String> reserved = new HashSet<>();

    /**
     * @param mcpLinkFor   the MCP URL and token for a session name, or null while the
     *                     MCP service is not running (then nothing is injected)
     * @param mcpConfigDir where per-session MCP config files go (created owner-only)
     * @param labeller     sets daemon labels; {@link SessionLabeller#NONE} for none
     * @param envStarter   starts a session with the MCP token in its
     *                     environment (used only while the MCP service runs, and only
     *                     for a harness that {@linkplain HarnessPlugin#usesMcpTokenEnv
     *                     reads the token from there})
     */
    public SessionLauncher(SessionRegistry registry, SessionHost host,
                           Function<String, McpLink> mcpLinkFor, Path mcpConfigDir,
                           SessionLabeller labeller, EnvSessionStarter envStarter) {
        this.registry = Objects.requireNonNull(registry, "registry");
        this.host = Objects.requireNonNull(host, "host");
        this.mcpLinkFor = Objects.requireNonNull(mcpLinkFor, "mcpLinkFor");
        this.mcpConfigDir = Objects.requireNonNull(mcpConfigDir, "mcpConfigDir");
        this.labeller = Objects.requireNonNull(labeller, "labeller");
        this.envStarter = Objects.requireNonNull(envStarter, "envStarter");
    }

    /** A launcher that never injects MCP (so never writes a config file or passes an
     * environment): plain host sessions plus {@code labeller}'s labels. */
    public static SessionLauncher withoutMcp(SessionRegistry registry, SessionHost host,
                                             SessionLabeller labeller) {
        return new SessionLauncher(registry, host, session -> null,
                Path.of(System.getProperty("java.io.tmpdir"), "micro-harness-manager-unused-mcp"), labeller,
                (session, workdir, columns, rows, env) -> {
                    throw new IllegalStateException("no MCP, no environment to pass");
                });
    }

    /**
     * Creates and registers a new session; see {@link #create(Path, HarnessType,
     * Optional, Optional, Map, Runnable)}. A resume id the harness has no
     * syntax for silently falls back to a fresh launch (logged).
     */
    public String create(Path projectPath, HarnessType harness, Optional<String> harnessSessionId,
                         Optional<String> displayName, Map<String, String> labels) {
        return create(projectPath, harness, harnessSessionId, displayName, labels,
                () -> LOG.warn("'{}' has no known resume syntax — starting a fresh session instead",
                        harness.id()));
    }

    /**
     * Creates and registers a new session running {@code harness} in {@code projectPath}
     * and returns its session name. The caller validates the directory beforehand.
     * {@code labels} are extra daemon labels; {@code displayName}, when present and
     * non-blank, becomes the row's display-name override.
     *
     * @param onNoResumeSyntax runs (on this thread) when a resume id was given but the
     *                         harness has no resume syntax, just before the fresh launch
     * @throws RuntimeException whatever the host threw; a half-created session may be
     *                          left behind, exactly as the window's create always did
     */
    public String create(Path projectPath, HarnessType harness, Optional<String> harnessSessionId,
                         Optional<String> displayName, Map<String, String> labels,
                         Runnable onNoResumeSyntax) {
        String name = reserveName(projectPath);
        try {
            HarnessPlugin plugin = HarnessPlugins.of(harness);
            Optional<String> display = displayName.filter(d -> !d.isBlank());
            Map<String, String> all = new LinkedHashMap<>(labels);
            all.put(LABEL_HARNESS, harness.id());
            all.put(LABEL_PROJECT, projectPath.toString());
            display.ifPresent(d -> all.put(LABEL_DISPLAY, d));
            Optional<String> id = harnessSessionId;
            String command;
            String freshId = UUID.randomUUID().toString();
            Optional<String> withId = id.isEmpty() ? plugin.launchCommandWithId(freshId) : Optional.empty();
            if (withId.isPresent()) {
                // a fresh launch names its own conversation, so the row knows the id
                // (transcript, resume) from the start; other harnesses learn it at exit
                command = withId.get();
                id = Optional.of(freshId);
            } else {
                command = launchCommand(plugin, id, onNoResumeSyntax);
            }
            start(name, projectPath, plugin, mcpLinkFor.apply(name), command, all);
            SessionEntry entry = SessionEntry.newlyCreated(name, projectPath.toString(), harness, id.orElse(null));
            registry.put(display.map(entry::withDisplayName).orElse(entry));
            return name;
        } finally {
            synchronized (reserved) {
                reserved.remove(name);
            }
        }
    }

    /**
     * Starts a fresh daemon session under a dead registered row's name and relaunches its
     * harness — resuming its conversation when the row has an id. The row itself is
     * unchanged.
     *
     * @param onNoResumeSyntax as for {@link #create}
     */
    public void resume(SessionEntry entry, Runnable onNoResumeSyntax) {
        String name = entry.sessionName();
        HarnessPlugin plugin = HarnessPlugins.of(entry.harnessType());
        Map<String, String> all = new LinkedHashMap<>();
        all.put(LABEL_HARNESS, entry.harnessType().id());
        all.put(LABEL_PROJECT, entry.projectPath());
        if (entry.displayName() != null && !entry.displayName().isBlank()) {
            all.put(LABEL_DISPLAY, entry.displayName());
        }
        Optional<String> id = entry.harnessSessionIdOpt();
        Optional<String> fresh = id.isPresent() && !plugin.canResume(id.get(), Path.of(entry.projectPath()))
                ? Optional.of(plugin.launchCommandWithId(id.get()).orElse(plugin.launchCommand()))
                : Optional.empty();
        // an id given at launch whose conversation never got a message has nothing to
        // resume: start it fresh, under the same id when the harness allows
        start(name, Path.of(entry.projectPath()), plugin, mcpLinkFor.apply(name),
                fresh.orElseGet(() -> launchCommand(plugin, id, onNoResumeSyntax)), all);
    }

    /**
     * Starts the session, labels it, and launches {@code command} in it: typed into the
     * shell once it is up (the default), or, when the settings ask for one-step starts and
     * the session's shell supports it, as the shell's own command, so nothing is typed
     * while the shell's startup files run.
     */
    private void start(String name, Path workdir, HarnessPlugin plugin, McpLink mcp, String command,
                       Map<String, String> labels) {
        if (!command.isBlank() && AppSettings.directLaunch() && host instanceof DirectSessionStarter direct) {
            String line = mcp != null ? withMcpServer(name, plugin, command, mcp) : command;
            Optional<List<String>> argv = SessionShell.system().oneStep(AppSettings.sessionShell(), line);
            if (argv.isPresent()) {
                if (mcp == null) {
                    discardMcpConfig(name); // a stale token's file from an earlier lifecycle
                }
                Map<String, String> env = mcp != null && plugin.usesMcpTokenEnv()
                        ? Map.of(HarnessPlugin.MCP_TOKEN_ENV, mcp.token()) : Map.of();
                boolean envApplied = direct.newSession(name, workdir, SessionTerminal.COLUMNS,
                        SessionTerminal.ROWS, argv.get(), env);
                if (!env.isEmpty() && !envApplied) {
                    LOG.warn("the running daemon predates per-session environment variables, so {} started "
                            + "without its MCP token; restart the daemon for MCP in such sessions", name);
                }
                label(name, labels);
                return;
            }
        }
        McpLink link = newSession(name, workdir, plugin, mcp);
        label(name, labels);
        sendLaunch(name, plugin, command, link);
    }

    /**
     * The command a launch types: the resume command when an id is given and the
     * harness has resume syntax, otherwise the fresh launch command
     * ({@code onNoResumeSyntax} runs first when an id had to be dropped).
     */
    public static String launchCommand(HarnessPlugin plugin, Optional<String> harnessSessionId,
                                       Runnable onNoResumeSyntax) {
        if (harnessSessionId.isEmpty()) {
            return plugin.launchCommand();
        }
        Optional<String> resumeCommand = plugin.resumeCommand(harnessSessionId.get());
        if (resumeCommand.isPresent()) {
            return resumeCommand.get();
        }
        onNoResumeSyntax.run();
        return plugin.launchCommand();
    }

    /**
     * Starts the host session at the standard size and returns the MCP link the launch
     * may inject ({@code mcp}, or null for none). A plain {@code newSession} — except
     * while the MCP service runs for a harness that reads the token from the
     * environment: then with the token in the session's environment. When the
     * daemon predates per-session environments and starts the session without it, the
     * harness could not authenticate, so the session is launched without MCP (null).
     */
    private McpLink newSession(String name, Path workdir, HarnessPlugin plugin, McpLink mcp) {
        if (mcp == null || !plugin.usesMcpTokenEnv()) {
            host.newSession(name, workdir, SessionTerminal.COLUMNS, SessionTerminal.ROWS);
            return mcp;
        }
        boolean envApplied = envStarter.newSession(name, workdir, SessionTerminal.COLUMNS, SessionTerminal.ROWS,
                Map.of(HarnessPlugin.MCP_TOKEN_ENV, mcp.token()));
        if (envApplied) {
            return mcp;
        }
        LOG.warn("the running daemon predates per-session environment variables, so {} could not be given "
                + "its MCP token: launching its {} without the micro-harness-manager MCP server. MCP for such "
                + "sessions needs the daemon to be restarted (it is replaced once every session has ended)",
                name, plugin.type().id());
        return null;
    }

    /** Types {@code command} unless blank (the pane's shell is the harness), with the MCP
     * server injected while the service runs. */
    private void sendLaunch(String name, HarnessPlugin plugin, String command, McpLink mcp) {
        if (mcp == null) {
            discardMcpConfig(name); // a stale token's file from an earlier lifecycle
        }
        if (command.isBlank()) {
            return;
        }
        host.sendKeys(name, mcp != null ? withMcpServer(name, plugin, command, mcp) : command);
    }

    /** {@code command} with the MCP server injected, after writing the harness's config
     * file if it reads one; a file that cannot be written means launching without MCP. */
    private String withMcpServer(String name, HarnessPlugin plugin, String command, McpLink mcp) {
        McpEndpoint endpoint = new McpEndpoint(mcp.url(), mcp.token(), mcpConfigFile(name));
        Optional<String> config = plugin.mcpConfigFile(endpoint);
        if (config.isPresent()) {
            try {
                writeOwnerOnly(endpoint.configFile(), config.get());
            } catch (IOException | UncheckedIOException e) {
                LOG.warn("could not write the MCP config for {} — launching it without MCP: {}", name, e.toString());
                return command;
            }
        }
        return plugin.withMcpServer(command, endpoint);
    }

    /** The per-session MCP config file; the name is reduced to file-safe characters. */
    public Path mcpConfigFile(String session) {
        return mcpConfigDir.resolve(session.replaceAll("[^A-Za-z0-9._-]", "_") + ".json");
    }

    /** Deletes {@code session}'s MCP config file (and the token in it), best effort —
     * for when the session is killed or forgotten. Safe from any thread. */
    public void discardMcpConfig(String session) {
        try {
            Files.deleteIfExists(mcpConfigFile(session));
        } catch (IOException | RuntimeException e) {
            LOG.warn("could not delete the MCP config for {}: {}", session, e.toString());
        }
    }

    /** Writes {@code content} to {@code file} so it is never readable by anyone but the
     * owner, not even mid-write: a 0600 temp file in a 0700 directory, then an atomic
     * replace. On a file system without POSIX permissions the defaults apply. */
    private static void writeOwnerOnly(Path file, String content) throws IOException {
        Path dir = file.getParent();
        boolean posix = dir.getFileSystem().supportedFileAttributeViews().contains("posix");
        if (posix) {
            Files.createDirectories(dir, PosixFilePermissions.asFileAttribute(
                    PosixFilePermissions.fromString("rwx------")));
            Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("rwx------"));
        } else {
            Files.createDirectories(dir);
        }
        FileAttribute<?>[] attrs = posix
                ? new FileAttribute<?>[] {PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))}
                : new FileAttribute<?>[0];
        Path temp = Files.createTempFile(dir, ".mcp-", ".tmp", attrs);
        try {
            Files.writeString(temp, content);
            Files.move(temp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } finally {
            Files.deleteIfExists(temp);
        }
    }

    /** A name free in the registry, on the daemon, and among launches still in flight
     * here — two concurrent launches in the same folder (the window and an agent) must
     * not both derive {@code mhm-x-2}. The daemon probes run outside the lock, so a slow
     * round trip never stalls another launch; the lock only covers re-checking the one chosen candidate — still not
     * reserved and still not in the registry (a concurrent launch may have registered
     * and released it meanwhile; a launch registers before it releases) — and adding it.
     * A candidate that fails the re-check is re-derived, at most
     * {@value #MAX_NAME_ATTEMPTS} times. */
    private String reserveName(Path projectPath) {
        for (int attempt = 0; attempt < MAX_NAME_ATTEMPTS; attempt++) {
            Set<String> inFlight;
            synchronized (reserved) {
                inFlight = Set.copyOf(reserved);
            }
            String name = SessionNaming.deriveUnique(projectPath,
                    candidate -> inFlight.contains(candidate)
                            || registry.find(candidate).isPresent()
                            || host.hasSession(candidate));
            synchronized (reserved) {
                if (!reserved.contains(name) && registry.find(name).isEmpty()) {
                    reserved.add(name);
                    return name;
                }
            }
        }
        throw new IllegalStateException("could not reserve a session name for " + projectPath + " after "
                + MAX_NAME_ATTEMPTS + " attempts");
    }

    private void label(String name, Map<String, String> labels) {
        try {
            labeller.label(name, labels);
        } catch (RuntimeException e) {
            if (predatesLabels(e)) {
                // a daemon older than labels: the registry entry still names the session
                LOG.debug("not labelling session {}: {}", name, e.getMessage());
            } else {
                LOG.warn("could not label session {}: {}", name, e.toString());
            }
        }
    }

    /** Whether {@code e} (or what it wraps) is a daemon refusing an op it predates. */
    private static boolean predatesLabels(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (t instanceof SessionServerException s && s.isUnsupported()) {
                return true;
            }
        }
        return false;
    }
}
