import Foundation
import MicrohmMux

/// The shell new sessions start in. The `session.shell` setting is empty for the user's
/// default (what the daemon picks: `$SHELL`), a well-known name (`zsh`, `bash`, `fish`,
/// `sh`; `pwsh`, `powershell`, `cmd` on Windows), or a path to any shell. Unix shells start
/// as login shells (`-l`) so they read the user's profile, as the default does.
public final class SessionShell: @unchecked Sendable {

    /// The default: let the daemon choose, exactly as before this setting existed.
    public static let DEFAULT = ""

    static let UNIX_NAMES = ["zsh", "bash", "fish", "sh"]
    static let WINDOWS_NAMES = ["pwsh", "powershell", "cmd"]

    /// Where Unix shells live when PATH (often minimal for an app started from the Dock)
    /// does not list them.
    private static let UNIX_DIRS = ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin"]

    /// Shells that take `-l -i -c COMMAND` and `exec`, so an agent can start in one step:
    /// the shell loads the user's setup, runs the agent, then becomes a login shell again.
    static let ONE_STEP_SHELLS: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]

    private let windows: Bool
    private let env: [String: String]
    private let executable: (String) -> Bool
    /// The daemon's default shell program (`ShellCommand.forSession`'s first word).
    private let defaultProgram: () -> String

    init(windows: Bool, env: [String: String], executable: @escaping (String) -> Bool,
         defaultProgram: @escaping () -> String = { ShellCommand.forSession("probe", nil).command.first ?? "/bin/sh" }) {
        self.windows = windows
        self.env = env
        self.executable = executable
        self.defaultProgram = defaultProgram
    }

    public static func system() -> SessionShell {
        SessionShell(windows: false, env: ProcessInfo.processInfo.environment, executable: { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        })
    }

    /// The command a session with `setting` starts, or nil for the daemon's default (also
    /// when the chosen shell cannot be found, so a session always starts).
    public func command(_ setting: String?) -> [String]? {
        guard let setting, !JavaText.isBlank(setting) else {
            return nil
        }
        return resolve(JavaText.trim(setting)).map { windows ? [$0] : [$0, "-l"] }
    }

    /// The argv that starts `agentCommand` in one step inside the shell `setting` picks
    /// (the default shell when empty), leaving a login shell when the agent exits; nil when
    /// that shell cannot do it (Windows shells, unknown ones), so the caller types the
    /// command instead.
    public func oneStep(_ setting: String?, _ agentCommand: String?) -> [String]? {
        guard !windows, let agentCommand, !JavaText.isBlank(agentCommand) else {
            return nil
        }
        let shell: String?
        if let setting, !JavaText.isBlank(setting) {
            shell = resolve(JavaText.trim(setting))
        } else {
            shell = defaultProgram()
        }
        guard let shell, SessionShell.ONE_STEP_SHELLS.contains(SessionShell.baseName(shell).lowercased()) else {
            return nil
        }
        return [shell, "-l", "-i", "-c", agentCommand + "; exec " + SessionShell.quote(shell) + " -l"]
    }

    /// `value` as one single-quoted word, for the shells in `ONE_STEP_SHELLS`.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The installed choices, in menu order: the well-known shells found on this machine.
    public func installedNames() -> [String] {
        (windows ? SessionShell.WINDOWS_NAMES : SessionShell.UNIX_NAMES).filter { resolve($0) != nil }
    }

    /// What the user's default is called, e.g. `zsh`.
    public func defaultName() -> String {
        displayName(defaultProgram())
    }

    /// How `setting` reads in the UI: "zsh (your default)", "bash", "fish (not found; your
    /// default is used)".
    public func describe(_ setting: String?) -> String {
        guard let setting, !JavaText.isBlank(setting) else {
            return defaultName() + " (your default)"
        }
        let trimmed = JavaText.trim(setting)
        let name = displayName(trimmed)
        return resolve(trimmed) != nil ? name : name + " (not found; your default is used)"
    }

    /// A friendly name for a shell name or path.
    public func displayName(_ nameOrPath: String) -> String {
        var base = SessionShell.baseName(nameOrPath).lowercased()
        if base.hasSuffix(".exe") {
            base = String(base.dropLast(4))
        }
        switch base {
        case "pwsh": return "PowerShell 7"
        case "powershell": return "Windows PowerShell"
        case "cmd": return "Command Prompt"
        // a well-known shell reads as its name wherever it lives; anything else as its path
        default:
            return SessionShell.isPath(nameOrPath) && !SessionShell.ONE_STEP_SHELLS.contains(base) ? nameOrPath : base
        }
    }

    private func resolve(_ nameOrPath: String) -> String? {
        if SessionShell.isPath(nameOrPath) {
            return executable(nameOrPath) ? nameOrPath : nil
        }
        let file = windows && !nameOrPath.lowercased().hasSuffix(".exe") ? nameOrPath + ".exe" : nameOrPath
        for dir in searchDirs() {
            let candidate = (dir as NSString).appendingPathComponent(file)
            if executable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func searchDirs() -> [String] {
        var dirs: [String] = []
        func add(_ dir: String) {
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        let key = windows ? (env.keys.first { $0.caseInsensitiveCompare("PATH") == .orderedSame } ?? "PATH") : "PATH"
        if let path = env[key] {
            for dir in path.split(separator: windows ? ";" : ":", omittingEmptySubsequences: true)
            where !JavaText.isBlank(String(dir)) {
                add(String(dir))
            }
        }
        if !windows {
            SessionShell.UNIX_DIRS.forEach(add)
        }
        return dirs
    }

    private static func isPath(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\")
    }

    private static func baseName(_ value: String) -> String {
        guard let cut = value.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return value }
        return String(value[value.index(after: cut)...])
    }
}
