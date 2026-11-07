import AppKit

/// A small popover for writing or editing a note, placed next to the text it belongs to (in the
/// margin, or above / below it). The note is saved as you type; ⌘↩ or Esc closes it,
/// Discard closes it and takes back everything typed since it opened.
final class NoteEditor: NSObject, NSTextViewDelegate, NSPopoverDelegate, NSTextStorageDelegate {
    private let popover = NSPopover()
    // AppKit's ready-made scrolling text view: its width follows the popover, so lines wrap.
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    enum Outcome { case keep(String), discard }
    private var done: ((Outcome) -> Void)?
    /// Called with the text a moment after typing pauses.
    var onChange: ((String) -> Void)?
    private var pause: Timer?
    private let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    private var scrollHeight: NSLayoutConstraint!
    /// The editor grows with its text between these heights (the text area, not the whole popover).
    private let minTextHeight: CGFloat = 200
    private var maxTextHeight: CGFloat = 400

    init(heading: String, quote: String?, text: String, done: @escaping (Outcome) -> Void) {
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

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
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
        textView.textStorage?.delegate = self
        if let storage = textView.textStorage { Markdown.style(storage) }

        let hint = NSTextField(labelWithString: "saved as you type  ·  ⌘↩ / Esc close  ·  **bold** *italic* `code` # - list")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.comment
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Discard", target: self, action: #selector(cancelPressed))
        cancel.toolTip = "Close and take back what was typed since the note opened"
        let save = NSButton(title: "Done", target: self, action: #selector(savePressed))
        let buttons = NSStackView(views: [hint, NSView(), cancel, save])

        let stack = NSStackView(views: [title, quoteLabel, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
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
        ])
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: minTextHeight)
        scrollHeight.isActive = true
    }

    /// The popover's own window (for snapshots).
    var window: NSWindow? { popover.contentViewController?.view.window }

    /// Shows the editor next to `rect` (in `view`'s coordinates): in the empty margin beside the
    /// page (`page`) at the same height when one is wide enough, else below or above the text.
    func show(next rect: NSRect, page: NSRect, in view: NSView) {
        // As tall as the text needs, up to nearly the whole window.
        maxTextHeight = max(minTextHeight, view.bounds.height - 170)
        let target = rect.intersection(view.bounds.insetBy(dx: 1, dy: 1)).isNull
            ? NSRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1) : rect
        if !page.isNull {
            let right = view.bounds.maxX - page.maxX, left = page.minX - view.bounds.minX
            let room = max(left, right), minimum: CGFloat = 300
            if room >= minimum + 24 {
                let width = min(560, room - 24)
                fit(width: width)
                let onRight = right >= left
                let x = onRight ? max(page.maxX, view.bounds.minX) : min(page.minX, view.bounds.maxX) - 1
                // A thin anchor on the page edge, level with the text; the arrow points at it.
                let y = min(max(target.minY, view.bounds.minY + 10), view.bounds.maxY - 10)
                let height = max(1, min(target.height, view.bounds.maxY - 10 - y))
                popover.show(relativeTo: NSRect(x: x, y: y, width: 1, height: height), of: view,
                             preferredEdge: onRight ? .maxX : .minX)
                focus()
                return
            }
        }
        let flipped = view.isFlipped
        let below = flipped ? view.bounds.maxY - target.maxY : target.minY - view.bounds.minY
        let above = flipped ? target.minY - view.bounds.minY : view.bounds.maxY - target.maxY
        let downward: NSRectEdge = flipped ? .maxY : .minY, upward: NSRectEdge = flipped ? .minY : .maxY
        maxTextHeight = max(120, min(maxTextHeight, max(below, above) - 150))
        fit(width: 480)
        popover.show(relativeTo: target, of: view, preferredEdge: below >= above ? downward : upward)
        focus()
    }

    /// Every key while the editor is open, from either window. ⌘↩ and Esc close it; a key that
    /// reached the document window instead of the editor is passed to the editor.
    /// Returns true when the key was used here.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76) && flags.contains(.command) { savePressed(); return true }
        if event.keyCode == 53 { savePressed(); return true }
        if event.window === window { return false }
        if flags.contains(.command) { return false }          // menus (⌘Q, ⌘W …) keep working
        focus(keepSelection: true)
        textView.keyDown(with: event)
        return true
    }

    private func focus(keepSelection: Bool = false) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        if keepSelection { return }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func popoverDidClose(_ notification: Notification) { finish(.keep(textView.string)) }

    /// Sizes the popover to its text: from `minTextHeight` up to `maxTextHeight`, then it scrolls.
    private func fit(width: CGFloat? = nil) {
        let width = width ?? popover.contentSize.width
        content.setFrameSize(NSSize(width: width, height: content.frame.height))
        content.layoutSubtreeIfNeeded()
        var needed = minTextHeight
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            needed = layout.usedRect(for: container).height + textView.textContainerInset.height * 2 + 24
        }
        scrollHeight.constant = min(max(needed, minTextHeight), maxTextHeight)
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        if popover.contentSize != NSSize(width: width, height: height) {
            popover.contentSize = NSSize(width: width, height: height)
        }
    }

    func textDidChange(_ notification: Notification) {
        fit()
        pause?.invalidate()
        pause = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, self.done != nil else { return }
            self.onChange?(self.textView.string)
        }
    }

    /// Restyles the Markdown after every edit (notes are short).
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        Markdown.style(textStorage)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { savePressed(); return true }
        return false
    }

    /// Test hooks (`nox --type`, `--close-note`): type as if from the keyboard / press a button.
    func type(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }
    func close(discarding: Bool) { discarding ? cancelPressed() : savePressed() }

    @objc private func cancelPressed() { finish(.discard) }
    @objc private func savePressed() { finish(.keep(textView.string)) }

    private func finish(_ outcome: Outcome) {
        pause?.invalidate()
        guard let done = self.done else { return }
        self.done = nil
        popover.close()
        done(outcome)
    }
}
