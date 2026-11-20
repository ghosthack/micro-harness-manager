import Foundation
import MicrohmShared

/// Where the app's state lives. The Java app used `~/.micro-harness-manager` (or the
/// `microhm.registry` system property); this port resolves everything through
/// `MicrohmPaths` (`~/.micro-harness-manager-swift`, or `MICROHM_HOME` /
/// `MicrohmPaths.homeOverride`), so it never touches the Java app's state.
public enum RegistryPaths {

    /// The session registry file, `<home>/sessions.json`.
    public static func resolve() -> URL {
        MicrohmPaths.registryFile
    }

    /// Where per-session MCP config files live (owner-only): an `mcp` directory beside
    /// `resolve()`, so a scratch home gets an isolated one too.
    public static func resolveMcpConfigDir() -> URL {
        MicrohmPaths.mcpConfigDir
    }
}
