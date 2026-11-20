/// The 16 base ANSI colours (`0xRRGGBB`) behind each palette choice. A palette covers only
/// those slots — indexes 16-255 (the xterm cube and grey ramp) and truecolor look the same
/// under every choice. The macOS Terminal and iTerm2 values are the stock profile colours of
/// the terminal they're named after, which is what makes plain ANSI output (prompts, ls, TUI
/// accents) match that terminal; `xterm` is the xterm-style palette the app's earlier
/// JediTerm-based widget shipped (its blues are lightened from xterm's for legibility on
/// black), kept value for value.
public enum AnsiPalettes {

    /// The palette choices (Java's `AppSettings.TerminalPalette`; the app maps its setting
    /// onto this).
    public enum Palette: String, CaseIterable, Sendable {
        case macosTerminal = "MACOS_TERMINAL"
        case iterm2 = "ITERM2"
        case xterm = "XTERM"
    }

    /// The 16 colours of `palette` as `0xRRGGBB`.
    public static func forSetting(_ palette: Palette) -> [Int] {
        switch palette {
        case .macosTerminal: return macosTerminal
        case .iterm2: return iterm2
        case .xterm: return xterm
        }
    }

    private static let macosTerminal = [
        0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
        0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB]

    private static let iterm2 = [
        0x000000, 0xC91B00, 0x00C200, 0xC7C400, 0x0225C7, 0xCA30C7, 0x00C5C7, 0xC7C7C7,
        0x686868, 0xFF6E67, 0x5FFA68, 0xFFFC67, 0x6871FF, 0xFF77FF, 0x60FDFF, 0xFFFFFF]

    private static let xterm = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x1E90FF, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x4C4C4C, 0xFF0000, 0x00FF00, 0xFFFF00, 0x4682B4, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
}
