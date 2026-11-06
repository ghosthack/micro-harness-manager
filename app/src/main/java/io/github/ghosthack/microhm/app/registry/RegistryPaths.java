package io.github.ghosthack.microhm.app.registry;

import java.nio.file.Path;

/** Where the app's state lives: {@code ~/.micro-harness-manager}, never shared with
 * harness-manager's {@code ~/.harness-manager}. */
public final class RegistryPaths {

    /** Overridable for tests/smoke-checks: {@code -Dmicrohm.registry=/path/to/sessions.json}. */
    public static final String OVERRIDE_PROPERTY = "microhm.registry";

    public static Path resolve() {
        String override = System.getProperty(OVERRIDE_PROPERTY);
        if (override != null && !override.isBlank()) {
            return Path.of(override);
        }
        return Path.of(System.getProperty("user.home"), ".micro-harness-manager", "sessions.json");
    }

    /** Where per-session MCP config files live (owner-only): an {@code mcp} directory
     * beside {@link #resolve()}, so a scratch registry gets an isolated one too. */
    public static Path resolveMcpConfigDir() {
        return resolve().toAbsolutePath().resolveSibling("mcp");
    }

    private RegistryPaths() {
    }
}
