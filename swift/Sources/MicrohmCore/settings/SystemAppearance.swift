import Foundation

/// Asks the OS whether it is in dark or light mode. Nil when the query fails, so callers
/// fall back to their own default. macOS only: the global `AppleInterfaceStyle` default
/// exists (as "Dark") only in dark mode — the same key `defaults read -g
/// AppleInterfaceStyle` reads, without forking `defaults`.
enum SystemAppearance {

    /// Queried once per launch: terminal attaches read the theme repeatedly.
    private static let cached: AppSettings.UiTheme? = detect(ProcessInfo.processInfo.operatingSystemVersionString,
                                                            mac: true)

    static func detected() -> AppSettings.UiTheme? {
        cached
    }

    /// `osName` as Java's `os.name` would read; only macOS has a detector here.
    static func detect(_ osName: String) -> AppSettings.UiTheme? {
        detect(osName, mac: osName.lowercased().contains("mac"))
    }

    private static func detect(_ osName: String, mac: Bool) -> AppSettings.UiTheme? {
        guard mac else {
            return nil
        }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let style = global?["AppleInterfaceStyle"] as? String {
            return parseMac(0, style)
        }
        if global != nil {
            // the key is absent: light mode ("does not exist", exit 1, from `defaults`)
            return parseMac(1, "")
        }
        return nil
    }

    /// `defaults read -g AppleInterfaceStyle`'s answer: exit 0 with "Dark" is dark,
    /// anything else (the key "does not exist", exit 1) is light.
    static func parseMac(_ exitCode: Int32, _ output: String) -> AppSettings.UiTheme {
        exitCode == 0 && JavaText.trim(output).caseInsensitiveCompare("dark") == .orderedSame ? .dark : .light
    }
}
