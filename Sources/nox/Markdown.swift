import AppKit

/// Light Markdown for notes. Notes are stored as plain Markdown in the PDF (readable in any app,
/// exported as is); nox styles it while you write and renders it when showing a note.
/// Handles: # headings, > quotes, - / * / 1. lists, **bold**, *italic* / _italic_, `code`, [links](url).
enum Markdown {
    struct Style {
        var font: NSFont = .systemFont(ofSize: 14)
        var color: NSColor = Theme.foreground
    }

    /// Ranges of syntax characters (#, **, `, …), dimmed while editing and removed when rendering.
    private typealias Markers = [NSRange]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static let heading = regex("^(#{1,6})[ \\t]+(.*)$", .anchorsMatchLines)
    private static let quote = regex("^(>[ \\t]?)(.*)$", .anchorsMatchLines)
    private static let list = regex("^([ \\t]*)([-*+]|\\d+[.)])[ \\t]+", .anchorsMatchLines)
    private static let bold = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    // a single * or _ only: never half of ** / __ (so "**bold*" while typing doesn't turn italic)
    private static let italic = regex("(?<![*_\\w])([*_])(?![*_\\s])(.+?)(?<![*_\\s])\\1(?![*_\\w])")
    private static let code = regex("(`)([^`\\n]+)(`)")
    private static let link = regex("(\\[)([^\\]\\n]+)(\\]\\([^)\\s]+\\))")

    /// Styles `storage` in place (attributes only; the text is untouched). For the editor.
    static func style(_ storage: NSTextStorage, _ style: Style = Style()) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: style.font, .foregroundColor: style.color], range: all)
        let markers = apply(to: storage, style)
        for range in markers { storage.addAttribute(.foregroundColor, value: Theme.comment, range: range) }
    }

    /// A rendered note: styled, with the syntax characters removed and list markers as bullets.
    static func render(_ text: String, _ style: Style = Style()) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: style.color])
        var markers = apply(to: result, style)
        // list markers become bullets rather than disappearing
        let s = result.string as NSString
        for match in list.matches(in: result.string, range: NSRange(location: 0, length: s.length)).reversed() {
            let marker = match.range(at: 2)
            markers.removeAll { NSIntersectionRange($0, marker).length > 0 }
            let isNumber = s.substring(with: marker).first?.isNumber == true
            if !isNumber { result.replaceCharacters(in: marker, with: "•") ; shift(&markers, after: marker.location, by: 1 - marker.length) }
        }
        for range in markers.sorted(by: { $0.location > $1.location }) where NSMaxRange(range) <= result.length {
            result.deleteCharacters(in: range)
        }
        return result
    }

    /// The note as plain text (syntax removed), for one-line lists.
    static func plain(_ text: String) -> String { render(text).string }

    private static func shift(_ ranges: inout Markers, after location: Int, by delta: Int) {
        ranges = ranges.map { $0.location > location ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
    }

    /// Adds the styles to `text` and returns the syntax-character ranges.
    private static func apply(to text: NSMutableAttributedString, _ style: Style) -> Markers {
        let s = text.string, ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        var markers: Markers = []
        let size = style.font.pointSize
        func font(_ traits: NSFontTraitMask, size: CGFloat? = nil, in range: NSRange) {
            text.enumerateAttribute(.font, in: range) { value, sub, _ in
                var f = (value as? NSFont) ?? style.font
                if let size { f = NSFont(descriptor: f.fontDescriptor, size: size) ?? f }
                f = NSFontManager.shared.convert(f, toHaveTrait: traits)
                text.addAttribute(.font, value: f, range: sub)
            }
        }

        for m in heading.matches(in: s, range: all) {
            let level = m.range(at: 1).length
            font(.boldFontMask, size: size + CGFloat(max(0, 4 - level)) * 2, in: m.range)
            markers.append(NSRange(location: m.range(at: 1).location, length: m.range(at: 2).location - m.range(at: 1).location))
        }
        for m in quote.matches(in: s, range: all) {
            font(.italicFontMask, in: m.range(at: 2))
            text.addAttribute(.foregroundColor, value: Theme.comment.blended(withFraction: 0.4, of: style.color) ?? Theme.comment, range: m.range(at: 2))
            markers.append(m.range(at: 1))
        }
        for m in list.matches(in: s, range: all) {
            text.addAttribute(.foregroundColor, value: Theme.accent, range: m.range(at: 2))
        }
        var codeRanges: [NSRange] = []
        for m in code.matches(in: s, range: all) {
            codeRanges.append(m.range)
            text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), range: m.range(at: 2))
            text.addAttribute(.backgroundColor, value: Theme.selection, range: m.range(at: 2))
            markers += [m.range(at: 1), m.range(at: 3)]
        }
        func outsideCode(_ r: NSRange) -> Bool { !codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }
        for m in bold.matches(in: s, range: all) where outsideCode(m.range) {
            font(.boldFontMask, in: m.range(at: 2))
            markers += [NSRange(location: m.range.location, length: 2), NSRange(location: NSMaxRange(m.range) - 2, length: 2)]
        }
        for m in italic.matches(in: s, range: all) where outsideCode(m.range) {
            // skip the inside of **bold** markers
            if markers.contains(where: { NSLocationInRange(m.range.location, $0) }) { continue }
            font(.italicFontMask, in: m.range(at: 2))
            markers += [NSRange(location: m.range.location, length: 1), NSRange(location: NSMaxRange(m.range) - 1, length: 1)]
        }
        for m in link.matches(in: s, range: all) where outsideCode(m.range) {
            text.addAttribute(.foregroundColor, value: Theme.accent, range: m.range(at: 2))
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            let target = ns.substring(with: m.range(at: 3)).dropFirst(2).dropLast()
            if let url = URL(string: String(target)) { text.addAttribute(.link, value: url, range: m.range(at: 2)) }
            markers += [m.range(at: 1), m.range(at: 3)]
        }
        return markers
    }
}
