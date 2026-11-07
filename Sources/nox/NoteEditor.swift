import AppKit

/// A small popover for writing or editing a note, placed next to the text it belongs to
/// (above or below, never on top of it). Cmd-Return saves, Esc cancels.
final class NoteEditor: NSObject, NSTextViewDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let textView = NSTextView()
    private var done: ((String?) -> Void)?

    init(heading: String, quote: String?, text: String, done: @escaping (String?) -> Void) {
        self.done = done
        super.init()
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self

        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = Theme.foreground

        let quoteLabel = NSTextField(wrappingLabelWithString: quote.map { "“\($0)”" } ?? "")
        quoteLabel.textColor = Theme.comment
        quoteLabel.maximumNumberOfLines = 2
        quoteLabel.lineBreakMode = .byTruncatingTail
        quoteLabel.isHidden = quote == nil
        quoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        textView.frame = NSRect(x: 0, y: 0, width: 440, height: 120)
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 250))
        content.addSubview(stack)
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            quoteLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    /// The popover's own window (for snapshots).
    var window: NSWindow? { popover.contentViewController?.view.window }

    /// Shows the editor next to `rect` (in `view`'s coordinates): below it when there is
    /// more room below, otherwise above.
    func show(next rect: NSRect, in view: NSView) {
        let target = rect.intersection(view.bounds.insetBy(dx: 1, dy: 1)).isNull
            ? NSRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1) : rect
        let flipped = view.isFlipped
        let below = flipped ? view.bounds.maxY - target.maxY : target.minY - view.bounds.minY
        let above = flipped ? target.minY - view.bounds.minY : view.bounds.maxY - target.maxY
        let downward: NSRectEdge = flipped ? .maxY : .minY, upward: NSRectEdge = flipped ? .minY : .maxY
        popover.show(relativeTo: target, of: view, preferredEdge: below >= above ? downward : upward)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func popoverDidClose(_ notification: Notification) { finish(nil) }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
        return false
    }

    @objc private func cancelPressed() { finish(nil) }
    @objc private func savePressed() { finish(textView.string) }

    private func finish(_ result: String?) {
        let done = self.done
        guard done != nil else { return }
        self.done = nil
        popover.close()
        done?(result)
    }
}
