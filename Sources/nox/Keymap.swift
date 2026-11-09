import AppKit

/// Every key nox understands, in one place: used by the `?` sheet, `nox --help`,
/// and the hints shown while a multi-key command is pending.
enum Keymap {
    static let sections: [(title: String, keys: [(String, String)])] = [
        ("Move", [
            ("j / k", "scroll down / up (counts work: 5j)"),
            ("Ctrl-d / Ctrl-u", "half a screen down / up"),
            ("Space, Ctrl-f / Ctrl-b", "a screen down / up"),
            ("J / K", "next / previous page"),
            ("gg / G / 12G", "first page / last page / page 12"),
            (":", "go to a page (type its number)"),
            ("Ctrl-o / Ctrl-i", "back / forward after following a link"),
            ("m{a-z} / '{a-z}", "set a mark in this PDF / jump to it (kept across sessions; ` works like ')"),
            ("m{A-Z} / '{A-Z}", "global mark: 'A opens that PDF at that place from any PDF"),
            ("''", "back to where you were before the last jump (again: forth)"),
            ("t", "table of contents (j/k, ↩ go)"),
            ("f", "label the links on screen; type one to follow it (Ctrl-o back)"),
            ("F", "label citations / links on screen; type one to preview what it cites (↩ go there)"),
            ("hover", "a citation or link: preview of the reference, figure or equation it points to"),
        ]),
        ("Search", [
            ("/", "search"),
            ("n / N", "next / previous match"),
            ("Esc", "clear search highlights"),
        ]),
        ("Select text without the mouse", [
            ("v", "label the visible lines; pick one, then pick the word to start at (or start at the search match)"),
            ("V", "label the visible lines; pick one to select whole lines"),
            ("w / b / e", "next word / previous word / end of word"),
            ("h j k l", "character left / line down / line up / character right"),
            ("f{c} / F{c}", "to the next / previous c, past the line too (t{c} / T{c}: just before it)"),
            ("; / ,", "repeat the last f F t T / the same backwards"),
            ("0 / $", "start / end of the line"),
            ("o", "move the other end of the selection"),
            ("then", "ca–ce highlight · a note · y copy · ,q quote · Esc cancel"),
        ]),
        ("Highlights and notes (saved in the PDF)", [
            ("c{a-e}", "highlight (color) the selection: a yellow, b green, c cyan, d pink, e orange"),
            ("a", "note on the selection, or a sticky note where you last clicked"),
            ("A", "note on the whole PDF (first in gn and the export; empty deletes it)"),
            ("e", "edit the note you last clicked"),
            ("dh", "delete the highlight / note you last clicked"),
            ("gn", "list all highlights and notes (↩ go, e edit, d delete)"),
            ("u / Ctrl-r", "undo / redo the last highlight or note change"),
            (",e", "export highlights and notes into <file>.notes.md"),
            ("click / right-click", "a highlight: its note and actions / menu"),
        ]),
        ("View", [
            ("+ / - / w", "zoom in / out / fit the page width to the window"),
            ("W", "fit the text width to the window (margins cut; stays fitted when the window resizes)"),
            (",c or F8", "dark mode on / off"),
            (",f", "full screen"),
            (",2", "visual mode and two columns: auto / on / off (if a selection runs across the columns)"),
            ("s", "two-page spread on / off"),
            ("T", "page thumbnails on / off (click one to go there)"),
            ("y or Cmd-C", "copy the selection"),
        ]),
        ("Presentation", [
            ("p", "present from this page: full screen; presenter view on a second display"),
            ("→ Space j / ← k", "next / previous slide (clickers work); click / right-click too"),
            ("b or .", "blank the screen"),
            ("F8 or ,c", "dark mode on / off for the slides"),
            ("12 ↩", "go to slide 12"),
            ("r / t", "restart / pause the timer"),
            ("x", "swap slides and presenter view (switch screens; on one display, show the presenter view)"),
            ("Esc or q", "stop presenting (back to the slide you were on)"),
        ]),
        ("LaTeX and the notes file", [
            ("Shift-click", "jump to the LaTeX source in Neovim (SyncTeX)"),
            (",q", "quote the selection into <file>.notes.md"),
            (",n", "open <file>.notes.md in Neovim"),
        ]),
        ("Files and tabs", [
            ("r / o / q", "reload / open another PDF (in a new tab) / close this tab"),
            ("gt / gT / 3gt", "next tab / previous tab / tab 3 (Ctrl-Tab works too)"),
            ("?", "this list"),
        ]),
    ]

    /// What can follow a pending prefix key.
    static let continuations: [String: String] = [
        "g": "gg first page   gn list of highlights and notes   gt / gT next / previous tab",
        "c": "ca yellow   cb green   cc cyan   cd pink   ce orange",
        "d": "dh delete the highlight / note you last clicked",
        "m": "m + a letter: set a mark (a–z this PDF, A–Z across files)",
        ",": ",c dark mode   ,f full screen   ,q quote to notes file   ,n open notes file   ,e export highlights/notes   ,2 columns auto/on/off",
    ]

    static var plainText: String {
        sections.map { section in
            "\(section.title)\n" + section.keys.map { "  \($0.0.padding(toLength: 22, withPad: " ", startingAt: 0)) \($0.1)" }
                .joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static var attributedText: NSAttributedString {
        let result = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 190)]
        style.headIndent = 190
        style.paragraphSpacing = 3
        let keyFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        let textFont = NSFont.systemFont(ofSize: 13)
        for (i, section) in sections.enumerated() {
            result.append(NSAttributedString(string: (i == 0 ? "" : "\n") + section.title + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: Theme.accent]))
            for (keys, text) in section.keys {
                result.append(NSAttributedString(string: keys, attributes: [
                    .font: keyFont, .foregroundColor: Theme.green, .paragraphStyle: style]))
                result.append(NSAttributedString(string: "\t" + text + "\n", attributes: [
                    .font: textFont, .foregroundColor: Theme.foreground, .paragraphStyle: style]))
            }
        }
        return result
    }
}

/// The `?` cheat sheet: Esc, q or ? closes it; j/k scroll.
final class HelpSheet: NSObject {
    let sheet: NSWindow
    private let textView = NSTextView()
    private var monitor: Any?

    override init() {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.backgroundColor = Theme.background
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(Keymap.attributedText)
        scroll.documentView = textView
        let hint = NSTextField(labelWithString: "Esc, q or ? to close    j / k to scroll")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.comment
        hint.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        sheet.contentView = content
        content.addSubview(scroll)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    func show(on window: NSWindow) {
        window.beginSheet(sheet) { _ in }
        textView.frame.size.width = sheet.contentView?.bounds.width ?? 720
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.sheet else { return event }
            switch event.charactersIgnoringModifiers {
            case "q", "?": self.close()
            case "j": self.textView.enclosingScrollView?.contentView.scroll(by: 60)
            case "k": self.textView.enclosingScrollView?.contentView.scroll(by: -60)
            default: if event.keyCode == 53 { self.close() } else { return event }
            }
            return nil
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        sheet.sheetParent?.endSheet(sheet)
    }
}

private extension NSClipView {
    func scroll(by dy: CGFloat) {
        guard let doc = documentView else { return }
        var origin = bounds.origin
        origin.y = max(0, min(origin.y + (doc.isFlipped ? dy : -dy), doc.frame.height - bounds.height))
        scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(self)
    }
}
