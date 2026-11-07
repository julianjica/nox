import AppKit

/// A small sheet for writing or editing a note. Cmd-Return saves, Esc cancels.
final class NoteEditor: NSObject, NSTextViewDelegate {
    let sheet: NSWindow
    private let textView = NSTextView()
    private var done: ((String?) -> Void)?

    init(heading: String, quote: String?, text: String, done: @escaping (String?) -> Void) {
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.done = done
        super.init()
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.backgroundColor = Theme.background

        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = Theme.foreground

        let quoteLabel = NSTextField(wrappingLabelWithString: quote.map { "“\($0)”" } ?? "")
        quoteLabel.textColor = Theme.comment
        quoteLabel.maximumNumberOfLines = 4
        quoteLabel.lineBreakMode = .byTruncatingTail
        quoteLabel.isHidden = quote == nil
        quoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.frame = NSRect(x: 0, y: 0, width: 520, height: 160)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = Theme.foreground
        textView.backgroundColor = Theme.darker
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = text
        textView.delegate = self
        scroll.documentView = textView

        let hint = NSTextField(labelWithString: "⌘↩ save    Esc cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.comment
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let save = NSButton(title: "Save", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        let buttons = NSStackView(views: [hint, NSView(), cancel, save])

        let stack = NSStackView(views: [title, quoteLabel, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView = NSView()
        sheet.contentView?.addSubview(stack)
        let content = sheet.contentView!
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            quoteLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    func show(on window: NSWindow) {
        window.beginSheet(sheet) { _ in }
        sheet.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
        return false
    }

    @objc private func cancelPressed() { finish(nil) }
    @objc private func savePressed() { finish(textView.string) }

    private func finish(_ result: String?) {
        sheet.sheetParent?.endSheet(sheet)
        let done = self.done
        self.done = nil
        done?(result)
    }
}
