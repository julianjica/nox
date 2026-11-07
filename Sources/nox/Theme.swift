import AppKit

/// Colors for dark mode and the interface, plus the page-recolor setting.
///
/// The defaults are nox's own dark palette. Any of them can be overridden in
/// `~/.config/nox/theme.json`, e.g. `{"background": "#1E1E2E", "foreground": "#CDD6F4"}`.
/// Keys: background, darker, selection, comment, foreground, accent, green, red,
/// highlight_a … highlight_e (the five highlight colors).
enum Theme {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    private static let overrides: [String: NSColor] = {
        let url = URL(fileURLWithPath: NSString(string: "~/.config/nox/theme.json").expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return json.compactMapValues { text in
            let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            return hex(value)
        }
    }()

    private static func color(_ key: String, _ fallback: UInt32) -> NSColor { overrides[key] ?? hex(fallback) }

    static let background = color("background", 0x141414)  // page paper in dark mode
    static let darker = color("darker", 0x0B0B0B)          // around the pages, status bar
    static let selection = color("selection", 0x3A3A3A)
    static let comment = color("comment", 0x8C8C8C)        // secondary text
    static let foreground = color("foreground", 0xE6E4DF)  // page ink in dark mode
    static let accent = color("accent", 0x8C9EFF)
    static let green = color("green", 0x7CE38B)
    static let red = color("red", 0xFF6B6B)

    /// Highlight colors for `ha` … `he`: yellow, green, cyan, pink, orange.
    static let highlightColors: [Character: NSColor] = [
        "a": color("highlight_a", 0xFFE45C), "b": color("highlight_b", 0x7CE38B), "c": color("highlight_c", 0x6CD4FF),
        "d": color("highlight_d", 0xFF7AB6), "e": color("highlight_e", 0xFFAE57),
    ]

    /// Whether pages are drawn in dark mode. Read from PDFKit's render threads.
    nonisolated(unsafe) static var recolor: Bool = UserDefaults.standard.object(forKey: "recolor") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recolor, forKey: "recolor") }
    }
}
