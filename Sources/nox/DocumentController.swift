import AppKit
import PDFKit

/// One PDF window: vim-style keys, search, highlights, auto-reload and SyncTeX.
final class DocumentController: NSObject, NSWindowDelegate, NSTextFieldDelegate, PDFDocumentDelegate {
    enum InputMode { case none, search, page }

    let url: URL
    let window: NSWindow
    let pdfView = PDFView()
    /// `T`: page thumbnails down the left side.
    private let thumbnails = PDFThumbnailView()
    private var thumbnailsWidth: NSLayoutConstraint!
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let input = NSTextField()
    private var inputMode = InputMode.none

    private var pending = ""      // multi-key prefix such as "g", "c", ","
    private var count = ""        // numeric prefix such as "12" in 12G
    private var searchResults: [PDFSelection] = []
    private var searchIndex = 0
    /// Where `''` goes back to: the place before the last jump.
    private var previousSpot: (page: Int, point: NSPoint)?
    private var lastClick: (page: PDFPage, point: NSPoint)?
    private var fileStamp: [String] = []
    private var changedStamp: [String] = []
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastColor: Character = "a"
    private var editor: NoteEditor?
    private var notesList: NotesList?
    private var dirtyPages = Set<Int>()
    private let overlays = OverlayProvider()
    private var help: HelpSheet?

    /// Keyboard selection ("visual mode"): character positions on a page's text.
    struct TextPos: Equatable { var page: Int; var index: Int }
    private var visual: (anchor: TextPos, head: TextPos)?
    /// Visual mode: the selection before a `,` move (find backwards), restored if the key turns out to start ,q ,c ….
    private var tentative: (anchor: TextPos, head: TextPos)?
    /// The last f / F / t / T, for ; and ,
    private var lastFind: (char: unichar, forward: Bool, till: Bool)?
    private var hints: [String: TextPos] = [:]
    private var hintViews: [NSView] = []
    private var hintTyped = ""
    private var hintLinewise = false
    /// Second step of `v`: the labels are on the words of the chosen line.
    private var hintWords = false
    private var linkHints: [String: (annotation: PDFAnnotation, page: PDFPage)] = [:]
    /// `F`: labels on the citations and links that can be previewed.
    private var previewHints: [String: (item: References.Item, page: PDFPage)] = [:]
    /// Citations and links found on each page (for hover previews).
    private var referenceItems: [Int: [References.Item]] = [:]
    private var preview: NSPopover?
    private var previewPlace: References.Place?
    private var hovered: (page: Int, rect: NSRect)?
    private var hoverTimer: Timer?
    var presentation: PresentationController?
    private var picker: PickerSheet?
    private var pageTexts: [Int: NSString] = [:]
    /// A line as it appears on the page, with its character range in the page's text.
    struct VisualLine { let rect: NSRect; let start: Int; let end: Int }
    private var pageLines: [Int: [VisualLine]] = [:]   // pages whose annotations changed since the last save
    var onClose: ((DocumentController) -> Void)?

    var path: String { url.path }
    var document: PDFDocument? { pdfView.document }

    init?(url: URL) {
        self.url = url
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1100),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        guard let doc = makeDocument() else { return nil }
        buildWindow()
        pdfView.pageOverlayViewProvider = overlays
        pdfView.document = doc
        restorePosition()
        applyTheme()
        fileStamp = stamp()
        startWatching()
        installMonitors()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pdfView)
        updateStatus()
        message("? keys")
    }

    // MARK: - Setup

    private func makeDocument() -> PDFDocument? {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        doc.delegate = self
        return doc
    }

    func classForPage() -> AnyClass { NoxPage.self }

    private func buildWindow() {
        window.title = url.lastPathComponent
        window.representedURL = url
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("nox-document")
        window.tabbingMode = .preferred           // PDFs open as tabs of one window
        window.tabbingIdentifier = "nox-documents"

        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.darker.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        for label in [statusLabel, messageLabel] {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            bar.addSubview(label)
        }
        statusLabel.textColor = Theme.foreground
        messageLabel.textColor = Theme.comment
        messageLabel.alignment = .right

        input.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.textColor = Theme.foreground
        input.delegate = self
        input.isHidden = true
        input.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(input)

        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnails.backgroundColor = Theme.darker
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.allowsDragging = false
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(thumbnails)
        content.addSubview(pdfView)
        content.addSubview(bar)
        window.contentView = content

        NSLayoutConstraint.activate([
            thumbnails.topAnchor.constraint(equalTo: content.topAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: bar.topAnchor),
            pdfView.topAnchor.constraint(equalTo: content.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            input.trailingAnchor.constraint(equalTo: messageLabel.leadingAnchor, constant: -8),
            input.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            messageLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
        ])

        thumbnailsWidth = thumbnails.widthAnchor.constraint(equalToConstant: 0)
        thumbnailsWidth.isActive = true
        thumbnails.isHidden = true
        if UserDefaults.standard.bool(forKey: "thumbnails") { toggleThumbnails(saying: false) }

        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged),
                                               name: .PDFViewScaleChanged, object: pdfView)
    }

    /// Keys and Shift+click are caught here, before PDFKit's own views see them.
    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // While a note is being written, its keys are text, never commands.
            if let editor = self.editor, event.window === self.window || event.window === editor.window {
                return editor.handleKey(event) ? nil : event
            }
            guard event.window === self.window, self.inputMode == .none else { return event }
            return self.handleKey(event) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.pdfView.convert(event.locationInWindow, from: nil)
            return self.mouseDown(at: point, shift: event.modifierFlags.contains(.shift)) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let self, event.window === self.window { DispatchQueue.main.async { self.mouseUp() } }
            return event
        } as Any)
        window.acceptsMouseMovedEvents = true
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            if let self, event.window === self.window { self.hover(at: self.pdfView.convert(event.locationInWindow, from: nil)) }
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.pdfView.convert(event.locationInWindow, from: nil)
            return self.showContextMenu(at: point, event: event) ? nil : event
        } as Any)
    }

    // MARK: - Clicks on highlights and notes

    private var clickedAnnotation: (annotation: PDFAnnotation, page: PDFPage)?
    private var popover: NSPopover?
    private var popoverTarget: (annotation: PDFAnnotation, page: PDFPage)?

    /// Returns true when the click was used up (Shift-click, sticky note).
    func mouseDown(at point: NSPoint, shift: Bool) -> Bool {
        popover?.close()
        clickedAnnotation = nil
        guard pdfView.bounds.contains(point), let page = pdfView.page(for: point, nearest: true) else { return false }
        let click = (page: page, point: pdfView.convert(point, to: page))
        lastClick = click
        if shift { inverseSearch(); return true }
        guard window.attachedSheet == nil, editor == nil, let annotation = noteAnnotation(at: click) else { return false }
        if annotation.type == "Text" {           // sticky note: open it
            editNote(annotation, on: page)
            return true
        }
        clickedAnnotation = (annotation, page)
        // PDFKit may track the drag itself and swallow the mouse-up; check once it's done.
        DispatchQueue.main.async { if NSEvent.pressedMouseButtons & 1 == 0 { self.mouseUp() } }
        return false
    }

    /// A plain click (not a drag) on a highlight opens its pop-up.
    func mouseUp() {
        guard let target = clickedAnnotation else { return }
        clickedAnnotation = nil
        if selectedText != nil { return }        // the user was selecting text
        showPopover(for: target.annotation, on: target.page)
    }

    private func showPopover(for annotation: PDFAnnotation, on page: PDFPage) {
        popover?.close()
        let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = NSTextField(wrappingLabelWithString: note.isEmpty ? "No note on this highlight." : note)
        label.textColor = note.isEmpty ? Theme.comment : Theme.foreground
        label.font = .systemFont(ofSize: 13)
        if !note.isEmpty {
            label.allowsEditingTextAttributes = true   // keeps the rendered styles and links
            label.attributedStringValue = Markdown.render(note, .init(font: .systemFont(ofSize: 13)))
        }
        label.preferredMaxLayoutWidth = 340
        label.isSelectable = true
        let edit = NSButton(title: note.isEmpty ? "Add note" : "Edit note", target: self, action: #selector(popoverEdit))
        let delete = NSButton(title: "Delete highlight", target: self, action: #selector(popoverDelete))
        let hint = NSTextField(labelWithString: "e  ·  dh")
        hint.textColor = Theme.comment
        hint.font = .systemFont(ofSize: 11)
        let buttons = NSStackView(views: [edit, delete, hint])
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let controller = NSViewController()
        controller.view = stack
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        let rect = NoxPage.highlightRects(annotation).max { $0.maxY < $1.maxY } ?? annotation.bounds
        pop.show(relativeTo: pdfView.convert(rect, from: page), of: pdfView, preferredEdge: .maxY)
        popover = pop
        popoverTarget = (annotation, page)
        lastClick = (page, NSPoint(x: rect.midX, y: rect.midY))
    }

    @objc private func popoverEdit() {
        popover?.close()
        guard let target = popoverTarget else { return }
        editNote(target.annotation, on: target.page)
    }

    @objc private func popoverDelete() {
        popover?.close()
        guard let target = popoverTarget else { return }
        remove(target.annotation, from: target.page)
    }

    private func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
        let sticky = annotation.type == "Text"
        change(.remove(annotation, page))
        if lastClick?.page === page { lastClick = nil }
        popoverTarget = nil
        save(saying: sticky ? "note deleted" : "highlight deleted")
    }

    // Right-click menu on a highlight or sticky note.
    private var menuTarget: (annotation: PDFAnnotation, page: PDFPage)?

    private func showContextMenu(at point: NSPoint, event: NSEvent) -> Bool {
        guard window.attachedSheet == nil, pdfView.bounds.contains(point),
              let page = pdfView.page(for: point, nearest: true) else { return false }
        let click = (page: page, point: pdfView.convert(point, to: page))
        guard let annotation = noteAnnotation(at: click) else { return false }
        popover?.close()
        lastClick = click
        menuTarget = (annotation, page)
        let hasNote = !(annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let menu = NSMenu()
        menu.addItem(withTitle: hasNote ? "Edit Note…" : "Add Note…", action: #selector(menuEdit), keyEquivalent: "").target = self
        if annotation.type == "Highlight" {
            let colors = NSMenu()
            for (letter, name) in [("a", "Yellow"), ("b", "Green"), ("c", "Cyan"), ("d", "Pink"), ("e", "Orange")] {
                let item = colors.addItem(withTitle: "\(name)  (h\(letter))", action: #selector(menuColor(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = letter
                let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                    Theme.highlightColors[Character(letter)]?.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                    return true
                }
                item.image = swatch
            }
            let colorItem = menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: annotation.type == "Text" ? "Delete Note" : "Delete Highlight",
                     action: #selector(menuDelete), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: pdfView)
        return true
    }

    @objc private func menuEdit() {
        guard let target = menuTarget else { return }
        editNote(target.annotation, on: target.page)
    }

    @objc private func menuDelete() {
        guard let target = menuTarget else { return }
        remove(target.annotation, from: target.page)
    }

    @objc private func menuColor(_ sender: NSMenuItem) {
        guard let target = menuTarget, let letter = (sender.representedObject as? String)?.first,
              let color = Theme.highlightColors[letter] else { return }
        change(.color(target.annotation, target.page, old: target.annotation.color, new: color))
        lastColor = letter
        save(saying: "color changed")
    }

    // MARK: - Status bar

    @objc private func viewChanged() {
        updateStatus()
        savePosition()
    }

    func updateStatus() {
        guard let doc = document else { return }
        let number = topPageIndex + 1
        let zoom = Int((pdfView.scaleFactor * 100).rounded())
        var parts = ["\(number)/\(doc.pageCount)", "\(zoom)%"]
        if visual != nil { parts.insert("-- VISUAL --", at: 0) }
        if !linkHints.isEmpty { parts.insert("-- pick a link --", at: 0) }
        if !previewHints.isEmpty { parts.insert("-- pick a citation to preview --", at: 0) }
        if !hints.isEmpty { parts.insert(hintWords ? "-- pick a word --" : hintLinewise ? "-- pick a line (whole lines) --" : "-- pick a line --", at: 0) }
        if !Theme.recolor { parts.append("original colors") }
        if NotesExport.documentNote(in: doc) != nil { parts.append("✎ PDF note (A)") }
        let keys = count + pending
        if !keys.isEmpty { parts.append(keys) }
        statusLabel.stringValue = parts.joined(separator: "   ")
    }

    func message(_ text: String, error: Bool = false) {
        messageLabel.textColor = error ? Theme.red : Theme.comment
        messageLabel.stringValue = text
    }

    // MARK: - Keys

    private static let prefixes: Set<String> = ["g", "c", "d", "m", "'", "`", ","]

    /// Returns true when the key was handled.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        if let preview, preview.isShown {
            if event.keyCode == 36 || event.keyCode == 76 { goToPreview(); return true }   // Return
            closePreview()
            if event.keyCode == 53 { return true }
        }
        if event.keyCode == 53 {  // Esc
            pending = ""; count = ""; tentative = nil
            if !hints.isEmpty || !linkHints.isEmpty || !previewHints.isEmpty || visual != nil {
                clearHints(); exitVisual(clear: true)
            } else {
                pdfView.highlightedSelections = nil
            }
            message("")
            updateStatus()
            return true
        }
        if event.specialKey == .f8 { toggleColors(); return true }
        if event.specialKey != nil { return false }

        if flags.contains(.control) {
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
            return handleControl(key)
        }
        guard let key = event.characters, key.count == 1 else { return false }
        return handle(key: key)
    }

    /// Runs a typed key sequence, e.g. "12G" or "ca" (also used by `nox --keys`).
    func type(_ keys: String) {
        if let presentation { keys.forEach { presentation.type(String($0)) }; return }
        for key in keys {
            // Control characters (e.g. $'\x12' for Ctrl-r) go to the Ctrl-key handler.
            if let value = key.unicodeScalars.first?.value, value >= 1, value <= 26, value != 13 {
                _ = handleControl(String(UnicodeScalar(value + 96)!))
            } else {
                _ = handle(key: String(key))
            }
        }
    }

    private func handle(key: String) -> Bool {
        if !hints.isEmpty || !linkHints.isEmpty || !previewHints.isEmpty { typeHint(key); return true }
        if pending.isEmpty, let digit = key.first, digit.isNumber, !(digit == "0" && count.isEmpty) {
            count += key
            updateStatus()
            return true
        }
        var sequence = pending + key
        if visual != nil, let before = tentative, !pending.isEmpty {
            // `,` already moved (repeat find backwards); ,q ,c … take the move back and run instead.
            tentative = nil
            let completes = "qcnef".contains(key)
            if !completes {
                pending = ""; count = ""; message("")
                return handle(key: key)
            }
            visual = before
            showVisual()
        } else if visual != nil, pending.isEmpty, key == "," {
            let times = Int(count) ?? 1
            let before = visual
            _ = performVisual("rev", times: times)
            tentative = before
            pending = key; count = ""
            message(Keymap.continuations[key] ?? "")
            updateStatus()
            return true
        } else if visual != nil, pending.isEmpty, "fFtT".contains(key) {
            pending = key
            message("\(key) + a character: \(key == "f" || key == "t" ? "forward" : "backward") to \(key.lowercased() == "f" ? "it" : "just before it") (past the line too)   ; repeat   , back")
            updateStatus()
            return true
        }
        if visual != nil, sequence.count == 2, "fFtT".contains(sequence.prefix(1)) { message("") }
        sequence = pending + key
        if pending.isEmpty, Self.prefixes.contains(sequence) {
            pending = sequence
            message(sequence == "'" || sequence == "`" ? marksSummary()
                    : Keymap.continuations[sequence] ?? "")
            updateStatus()
            return true
        }
        let times = Int(count) ?? 1
        let explicitCount = count.isEmpty ? nil : Int(count)
        if sequence.count > 1, Keymap.continuations[String(sequence.prefix(1))] == messageLabel.stringValue
            || ((pending == "'" || pending == "`") && messageLabel.stringValue == marksSummary()) { message("") }
        pending = ""; count = ""
        if visual != nil, let handled = performVisual(sequence, times: times) {
            updateStatus()
            return handled
        }
        let handled = perform(sequence, times: times, number: explicitCount)
        updateStatus()
        return handled
    }

    private func perform(_ sequence: String, times: Int, number: Int?) -> Bool {
        let step: CGFloat = 60
        switch sequence {
        case "j": scroll(by: step * CGFloat(times))
        case "k": scroll(by: -step * CGFloat(times))
        case " ": scroll(by: visibleHeight * 0.9)
        case "J": goToPage(topPageIndex + 1 + times)
        case "K": goToPage(topPageIndex + 1 - times)
        case "G": rememberSpot(); number.map(goToPage) ?? pdfView.goToLastPage(nil)
        case "gg": rememberSpot(); goToPage(number ?? 1)
        case "''", "``": jumpBack()
        case "gt": switchTab(to: number)
        case "gT": switchTab(by: -times)
        case "+", "=": zoom(by: 1.1)
        case "-": zoom(by: 1 / 1.1)
        case "w": pdfView.autoScales = true
        case "/": beginInput(.search)
        case ":": beginInput(.page)
        case "n": stepSearch(by: times)
        case "N": stepSearch(by: -times)
        case "y": yank()
        case "r": reload(force: true)
        case "u": undo()
        case "o": (NSApp.delegate as? AppDelegate)?.openPanel()
        case "q": window.performClose(nil)
        case "?": showHelp()
        case "v": startVisual(linewise: false)
        case "p": startPresentation()
        case "t": showOutline()
        case "f": showLinkHints()
        case "F": showPreviewHints()
        case "s": toggleSpread()
        case "T": toggleThumbnails()
        case "V": startVisual(linewise: true)
        case "dh": deleteHighlight()
        case "a": annotate()
        case "A": editDocumentNote()
        case "e": editNoteUnderClick()
        case "gn": showNotesList()
        case ",c": toggleColors()
        case ",q": quoteSelection()
        case ",n": Notes.open(pdf: path); message("opening notes")
        case ",e": exportNotes()
        case ",f": window.toggleFullScreen(nil)
        default:
            if sequence.count == 2, let mode = sequence.first, let letter = sequence.last {
                switch mode {
                case "c": highlight(letter); return true
                case "m": setMark(letter); return true
                case "'", "`": jumpToMark(letter); return true
                default: break
                }
            }
            if sequence.count > 1 { message("unknown keys: \(sequence)", error: true); return true }
            return false
        }
        return true
    }

    private func handleControl(_ key: String) -> Bool {
        switch key {
        case "d": scroll(by: visibleHeight / 2)
        case "u": scroll(by: -visibleHeight / 2)
        case "r": redo()
        case "f": scroll(by: visibleHeight * 0.9)
        case "b": scroll(by: -visibleHeight * 0.9)
        case "o": if pdfView.canGoBack { pdfView.goBack(nil) }
        case "i": if pdfView.canGoForward { pdfView.goForward(nil) }
        default: return false
        }
        updateStatus()
        return true
    }

    // MARK: - Navigation

    /// The page and point at the top of the window. PDFKit's own "current page" is the
    /// one in the middle, which is misleading when several slides fit on screen.
    var topDestination: PDFDestination? {
        let y = pdfView.isFlipped ? pdfView.bounds.minY + 2 : pdfView.bounds.maxY - 2
        let viewPoint = NSPoint(x: pdfView.bounds.midX, y: y)
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        var point = pdfView.convert(viewPoint, to: page)
        point.x = page.bounds(for: .mediaBox).minX
        return PDFDestination(page: page, at: point)
    }

    var topPageIndex: Int {
        topDestination?.page.flatMap { document?.index(for: $0) } ?? 0
    }

    private var scrollView: NSScrollView? { pdfView.documentView?.enclosingScrollView }
    private var visibleHeight: CGFloat { scrollView?.contentView.bounds.height ?? 600 }

    func scroll(by dy: CGFloat) {
        guard let scrollView, let docView = pdfView.documentView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += docView.isFlipped ? dy : -dy
        origin.y = max(0, min(origin.y, docView.frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func goToPage(_ number: Int) {
        guard let doc = document else { return }
        let index = max(0, min(number - 1, doc.pageCount - 1))
        if let page = doc.page(at: index) { pdfView.go(to: page) }
    }

    /// Zooms while keeping the top of the window in place.
    private func zoom(by factor: CGFloat) {
        let top = topDestination
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.2, min(pdfView.scaleFactor * factor, 8))
        if let top { pdfView.go(to: top) }
    }

    // MARK: - Marks (as in Vim)
    //
    // ma … mz: marks in this PDF, remembered across sessions.
    // mA … mZ: global marks; 'A opens that PDF at that place from anywhere.
    // '' (or ``): back to where you were before the last jump.

    private static let localMarksKey = "marks", globalMarksKey = "globalMarks"

    private var localMarks: [String: [String: Double]] {
        get { (UserDefaults.standard.dictionary(forKey: Self.localMarksKey)?[path] as? [String: [String: Double]]) ?? [:] }
        set {
            var all = UserDefaults.standard.dictionary(forKey: Self.localMarksKey) ?? [:]
            all[path] = newValue
            UserDefaults.standard.set(all, forKey: Self.localMarksKey)
        }
    }

    private static var globalMarks: [String: [String: Any]] {
        get { (UserDefaults.standard.dictionary(forKey: globalMarksKey) as? [String: [String: Any]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: globalMarksKey) }
    }

    private var currentSpot: (page: Int, point: NSPoint)? {
        guard let dest = topDestination, let page = dest.page, let doc = document else { return nil }
        return (doc.index(for: page), dest.point)
    }

    // MARK: - Tabs

    /// `gt` next tab, `3gt` tab 3, `gT` previous tab.
    private func switchTab(to number: Int? = nil, by delta: Int = 1) {
        guard let tabs = window.tabbedWindows, tabs.count > 1 else { message("only one tab (o opens another PDF)"); return }
        let current = tabs.firstIndex { $0 === window } ?? 0
        let target = number.map { $0 - 1 } ?? current + delta
        guard number == nil || (0..<tabs.count).contains(target) else { message("no tab \(number!)", error: true); return }
        tabs[((target % tabs.count) + tabs.count) % tabs.count].makeKeyAndOrderFront(nil)
    }

    /// Call before any jump, so `''` can come back.
    func rememberSpot() {
        if let spot = currentSpot { previousSpot = spot }
    }

    func go(toPage page: Int, y: CGFloat) {
        guard let doc = document, let target = doc.page(at: max(0, min(page, doc.pageCount - 1))) else { return }
        pdfView.go(to: PDFDestination(page: target, at: NSPoint(x: target.bounds(for: .mediaBox).minX, y: y)))
        updateStatus()
    }

    private func setMark(_ letter: Character) {
        guard letter.isLetter, let spot = currentSpot else { message("marks are letters: a–z here, A–Z across files", error: true); return }
        let entry: [String: Double] = ["page": Double(spot.page), "y": Double(spot.point.y)]
        if letter.isUppercase {
            Self.globalMarks[String(letter)] = ["file": path, "page": spot.page, "y": Double(spot.point.y)]
            message("mark \(letter) set (all files): p. \(spot.page + 1)")
        } else {
            localMarks[String(letter)] = entry
            message("mark \(letter) set: p. \(spot.page + 1)")
        }
    }

    private func jumpToMark(_ letter: Character) {
        if letter.isUppercase {
            guard let mark = Self.globalMarks[String(letter)], let file = mark["file"] as? String,
                  let page = mark["page"] as? Int, let y = mark["y"] as? Double else {
                message("no mark \(letter)", error: true); return
            }
            if file == path {
                rememberSpot()
                go(toPage: page, y: CGFloat(y))
            } else if FileManager.default.fileExists(atPath: file) {
                (NSApp.delegate as? AppDelegate)?.open(URL(fileURLWithPath: file), page: page, y: CGFloat(y))
            } else {
                message("mark \(letter): \((file as NSString).lastPathComponent) no longer exists", error: true)
            }
            return
        }
        guard let mark = localMarks[String(letter)], let page = mark["page"], let y = mark["y"] else {
            message("no mark \(letter)", error: true); return
        }
        rememberSpot()
        go(toPage: Int(page), y: CGFloat(y))
    }

    /// `''`: back to the place before the last jump (again: forth).
    private func jumpBack() {
        guard let back = previousSpot else { message("no previous jump", error: true); return }
        rememberSpot()
        go(toPage: back.page, y: back.point.y)
    }

    /// Shown after `'`: the marks you can jump to.
    private func marksSummary() -> String {
        let local = localMarks.sorted { $0.key < $1.key }.map { "'\($0.key) p.\(Int($0.value["page"] ?? 0) + 1)" }
        let global = Self.globalMarks.sorted { $0.key < $1.key }.map { key, mark -> String in
            let file = ((mark["file"] as? String ?? "") as NSString).lastPathComponent
            let page = (mark["page"] as? Int ?? 0) + 1
            return file == url.lastPathComponent ? "'\(key) p.\(page)" : "'\(key) \(file) p.\(page)"
        }
        let all = local + global + (previousSpot.map { ["'' p.\($0.page + 1)"] } ?? [])
        return all.isEmpty ? "no marks yet: ma sets mark a (mA: across files)" : all.joined(separator: "   ")
    }

    // MARK: - Search and page prompt

    private func beginInput(_ mode: InputMode) {
        inputMode = mode
        input.stringValue = ""
        input.placeholderString = mode == .search ? "/ search" : ": page number"
        input.isHidden = false
        statusLabel.isHidden = true
        window.makeFirstResponder(input)
    }

    private func endInput() {
        inputMode = .none
        input.isHidden = true
        statusLabel.isHidden = false
        window.makeFirstResponder(pdfView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endInput()
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = input.stringValue.trimmingCharacters(in: .whitespaces)
            let mode = inputMode
            endInput()
            if mode == .search, !text.isEmpty { search(text) }
            if mode == .page, let number = Int(text) { rememberSpot(); goToPage(number) }
            updateStatus()
            return true
        }
        return false
    }

    func search(_ query: String) {
        guard let doc = document else { return }
        searchResults = doc.findString(query, withOptions: [.caseInsensitive])
        guard !searchResults.isEmpty else {
            pdfView.highlightedSelections = nil
            message("not found: \(query)", error: true)
            return
        }
        for result in searchResults { result.color = Theme.accent.withAlphaComponent(0.45) }
        pdfView.highlightedSelections = searchResults
        let current = topPageIndex
        searchIndex = searchResults.firstIndex { sel in
            sel.pages.first.map { doc.index(for: $0) >= current } ?? false
        } ?? 0
        showSearchResult()
    }

    private func stepSearch(by delta: Int) {
        guard !searchResults.isEmpty else { message("no search", error: true); return }
        searchIndex = ((searchIndex + delta) % searchResults.count + searchResults.count) % searchResults.count
        showSearchResult()
    }

    private func showSearchResult() {
        rememberSpot()
        let result = searchResults[searchIndex]
        pdfView.setCurrentSelection(result, animate: false)
        pdfView.go(to: result)
        message("match \(searchIndex + 1)/\(searchResults.count)")
    }

    // MARK: - Selection, highlights, notes

    private var selectedText: String? {
        guard let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private func yank() {
        guard let text = selectedText else { message("nothing selected", error: true); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message("copied \(text.count) characters")
    }

    private func highlight(_ letter: Character) {
        guard let color = Theme.highlightColors[letter] else { message("highlight colors: a–e", error: true); return }
        guard let selection = pdfView.currentSelection, selectedText != nil else {
            message("select text first", error: true); return
        }
        lastColor = letter
        guard addHighlight(selection, color: color, note: nil) != nil else {
            message("could not place a highlight on that selection", error: true); return
        }
        pdfView.clearSelection()
        save(saying: "highlighted (\(letter))")
    }

    /// One highlight annotation per page, with a rectangle per line. The note, if any,
    /// goes in the annotation's contents, where Preview, Acrobat and Zotero show it too.
    @discardableResult
    private func addHighlight(_ selection: PDFSelection, color: NSColor, note: String?) -> PDFAnnotation? {
        var first: PDFAnnotation?
        let lines = selection.selectionsByLine()
        func valid(_ r: NSRect) -> Bool { r.width > 0 && r.height > 0 && r.minX.isFinite && r.minY.isFinite }
        for page in selection.pages {
            let index = document?.index(for: page)
            // Ask each line about its own page object: PDFKit returns infinite bounds when the
            // page is a different (but equal) object, as happens with search results.
            var rects = lines.compactMap { line -> NSRect? in
                guard let own = line.pages.first(where: { $0 === page || document?.index(for: $0) == index }) else { return nil }
                let r = line.bounds(for: own)
                return valid(r) ? r : nil
            }
            if rects.isEmpty {
                let whole = selection.bounds(for: page)
                if valid(whole) { rects = [whole] }
            }
            guard let firstRect = rects.first else { continue }
            let bounds = rects.dropFirst().reduce(firstRect) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
            annotation.userName = "nox"
            annotation.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let x0 = r.minX - bounds.minX, x1 = r.maxX - bounds.minX
                let y0 = r.minY - bounds.minY, y1 = r.maxY - bounds.minY
                return [NSPoint(x: x0, y: y1), NSPoint(x: x1, y: y1), NSPoint(x: x0, y: y0), NSPoint(x: x1, y: y0)]
                    .map { NSValue(point: $0) }
            }
            if first == nil, let note, !note.isEmpty { annotation.contents = note }
            first = first ?? annotation
            change(.add(annotation, page))
        }
        return first
    }

    // MARK: - Notes stored in the PDF

    /// `a`: with a selection, highlight it and attach a note; otherwise put a sticky note
    /// where you last clicked. `note` skips the editor (used by `nox --note`).
    func annotate(note given: String? = nil) {
        if let selection = pdfView.currentSelection, let quote = selectedText {
            let color = Theme.highlightColors[lastColor] ?? Theme.highlightColors["a"]!
            let create: (String) -> (PDFAnnotation, PDFPage)? = { [weak self] note in
                guard let self else { return nil }
                guard let added = self.addHighlight(selection, color: color, note: note), let page = added.page else {
                    self.message("could not place a highlight on that selection", error: true); return nil
                }
                self.pdfView.clearSelection()
                return (added, page)
            }
            noteSession(heading: "Note on highlight", quote: quote, near: viewRect(of: selection), box: NoteBox(),
                        deleteWhenEmpty: false, given: given, create: create)
            return
        }
        guard let (page, point) = stickyLocation() else { return }
        let bounds = NSRect(x: point.x, y: point.y - 20, width: 20, height: 20)
        let create: (String) -> (PDFAnnotation, PDFPage)? = { [weak self] note in
            guard let self else { return nil }
            let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.iconType = .comment
            annotation.color = Theme.highlightColors["a"]!
            annotation.userName = "nox"
            annotation.contents = note
            self.change(.add(annotation, page))
            return (annotation, page)
        }
        noteSession(heading: "Note on page \((document?.index(for: page) ?? 0) + 1)", quote: nil,
                    near: pdfView.convert(bounds, from: page), box: NoteBox(), deleteWhenEmpty: true, given: given, create: create)
    }

    /// `A`: the note on the whole PDF: kept inside it (a note in the first page's corner),
    /// listed first in `gn` and in the export. Emptying it deletes it.
    func editDocumentNote(note given: String? = nil) {
        guard let doc = document, let first = doc.page(at: 0) else { return }
        let box = NoteBox()
        if let (annotation, page) = NotesExport.documentNote(in: doc) { box.annotation = annotation; box.page = page }
        let create: (String) -> (PDFAnnotation, PDFPage)? = { [weak self] note in
            guard let self else { return nil }
            let crop = first.bounds(for: .cropBox)
            let annotation = PDFAnnotation(bounds: NSRect(x: crop.minX + 6, y: crop.maxY - 26, width: 20, height: 20),
                                           forType: .text, withProperties: nil)
            annotation.iconType = .note
            annotation.color = Theme.highlightColors["a"]!
            annotation.userName = "nox"
            annotation.contents = note
            NotesExport.markAsDocumentNote(annotation)
            self.change(.add(annotation, first))
            return (annotation, first)
        }
        noteSession(heading: "Note on this PDF", quote: nil, near: .null, box: box, deleteWhenEmpty: true,
                    given: given, create: create)
    }

    /// The note an editor is working on; empty until its annotation exists.
    final class NoteBox {
        var annotation: PDFAnnotation?
        var page: PDFPage?
    }

    /// Brings a note to `text`: creates its annotation the first time, updates its text, or (for
    /// sticky notes, once the editor closes) removes it when emptied. Returns a status message,
    /// or nil when nothing changed.
    private func setNote(_ box: NoteBox, to text: String, final: Bool, deleteWhenEmpty: Bool,
                         create: (String) -> (PDFAnnotation, PDFPage)?) -> String? {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let annotation = box.annotation, let page = box.page {
            if note.isEmpty && deleteWhenEmpty {
                guard final else { return nil }
                change(.remove(annotation, page))
                box.annotation = nil
                return "note deleted"
            }
            let new: String? = note.isEmpty ? nil : note
            guard (annotation.contents ?? "") != (new ?? "") else { return nil }
            change(.contents(annotation, page, old: annotation.contents, new: new))
            return note.isEmpty ? "note removed (highlight kept)" : "note saved in the PDF"
        }
        guard !note.isEmpty || (final && !deleteWhenEmpty) else { return nil }
        guard let (annotation, page) = create(note) else { return nil }
        box.annotation = annotation
        box.page = page
        return note.isEmpty ? "highlighted" : "note saved in the PDF"
    }

    /// Opens the note editor and keeps the note saved as it is typed. Closing keeps it (one undo
    /// step for the whole session); Discard takes back everything since it opened.
    /// `given` skips the editor (used by `nox --note` / `--pdf-note`).
    private func noteSession(heading: String, quote: String?, near rect: NSRect, box: NoteBox, deleteWhenEmpty: Bool,
                             given: String?, create: @escaping (String) -> (PDFAnnotation, PDFPage)?) {
        if let given {
            let label = setNote(box, to: given, final: true, deleteWhenEmpty: deleteWhenEmpty, create: create)
            if let label { save(saying: label) }
            updateStatus()
            return
        }
        guard window.attachedSheet == nil, editor == nil else { return }
        let editor = NoteEditor(heading: heading, quote: quote, text: box.annotation?.contents ?? "") { [weak self] outcome in
            guard let self else { return }
            self.editor = nil
            self.window.makeFirstResponder(self.pdfView)
            switch outcome {
            case .keep(let text):
                let label = self.setNote(box, to: text, final: true, deleteWhenEmpty: deleteWhenEmpty, create: create)
                if !self.pendingEdits.isEmpty { self.save(saying: label ?? "note saved in the PDF") }
            case .discard:
                if !self.pendingEdits.isEmpty {
                    for edit in self.pendingEdits.reversed() { self.apply(edit, backwards: true) }
                    self.pendingEdits = []
                    self.save(saying: "note discarded", recording: false)
                } else {
                    self.message("")
                }
            }
            self.updateStatus()
        }
        editor.onChange = { [weak self] text in
            guard let self else { return }
            if self.setNote(box, to: text, final: false, deleteWhenEmpty: deleteWhenEmpty, create: create) != nil {
                self.save(saying: "saved", live: true)
                self.updateStatus()
            }
        }
        self.editor = editor
        // The page the note belongs to, so the editor can sit in the margin beside it.
        let visible = pdfView.bounds
        var target = rect
        if target.isNull || !target.intersects(visible) {
            target = NSRect(x: visible.midX, y: pdfView.isFlipped ? visible.minY + 60 : visible.maxY - 60, width: 1, height: 1)
        }
        let page = pdfView.page(for: NSPoint(x: target.midX, y: target.midY), nearest: true) ?? pdfView.currentPage
        let pageRect = page.map { pdfView.convert($0.bounds(for: .cropBox), from: $0) } ?? .null
        editor.show(next: target, page: pageRect, in: pdfView)
    }

    /// Where a sticky note goes: the last click, or the top-left of the visible page.
    private func stickyLocation() -> (PDFPage, NSPoint)? {
        if let click = lastClick { return (click.page, click.point) }
        guard let dest = topDestination, let page = dest.page else { return nil }
        let box = page.bounds(for: .mediaBox)
        return (page, NSPoint(x: box.minX + 24, y: min(dest.point.y - 24, box.maxY - 24)))
    }

    /// Where a selection is on screen (its part on the first page shown).
    /// Test hooks for the note editor.
    func typeInNote(_ text: String) { editor?.type(text) }
    func closeNote(discarding: Bool) { editor?.close(discarding: discarding) }

    private func viewRect(of selection: PDFSelection) -> NSRect {
        let pages = selection.pages
        let page = pages.first { pdfView.visiblePages.contains($0) } ?? pages.first
        guard let page else { return .null }
        let r = selection.bounds(for: page)
        return r.minX.isFinite && r.minY.isFinite ? pdfView.convert(r, from: page) : .null
    }

    /// The highlight or sticky note under a click, topmost first.
    private func noteAnnotation(at click: (page: PDFPage, point: NSPoint)) -> PDFAnnotation? {
        click.page.annotations.reversed().first { annotation in
            if annotation.type == "Text" { return annotation.bounds.insetBy(dx: -4, dy: -4).contains(click.point) }
            guard annotation.type == "Highlight" else { return false }
            return NoxPage.highlightRects(annotation).contains { $0.contains(click.point) }
        }
    }

    private func editNoteUnderClick() {
        popover?.close()
        guard let click = lastClick, let annotation = noteAnnotation(at: click) else {
            message("click a highlight or note first", error: true); return
        }
        editNote(annotation, on: click.page)
    }

    private func editNote(_ annotation: PDFAnnotation, on page: PDFPage) {
        let quote = annotation.type == "Highlight" ? quoteText(of: annotation, on: page) : nil
        let heading = NotesExport.isDocumentNote(annotation) ? "Note on this PDF"
            : annotation.type == "Text" ? "Note on page \((document?.index(for: page) ?? 0) + 1)" : "Note on highlight"
        let rect = annotation.type == "Highlight"
            ? NoxPage.highlightRects(annotation).map { pdfView.convert($0, from: page) }
                .reduce(NSRect.null) { $0.union($1) }
            : pdfView.convert(annotation.bounds, from: page)
        let box = NoteBox()
        box.annotation = annotation
        box.page = page
        noteSession(heading: heading, quote: quote, near: rect, box: box, deleteWhenEmpty: annotation.type == "Text",
                    given: nil, create: { _ in nil })
    }

    private func quoteText(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        NotesExport.quote(of: annotation, on: page)
    }

    func noteEntries() -> [NoteEntry] {
        document.map { NotesExport.entries(in: $0) } ?? []
    }

    /// `,e`: write the PDF's highlights and notes into <name>.notes.md.
    func exportNotes() {
        guard let doc = document else { return }
        do {
            let count = try NotesExport.write(doc, pdf: url)
            message("exported \(count) highlight\(count == 1 ? "" : "s")/notes to \(NotesExport.notesURL(for: url).lastPathComponent)")
        } catch {
            message("could not export: \(error.localizedDescription)", error: true)
        }
    }

    /// `gn`: list of highlights and notes; Return jumps, e edits, d deletes.
    private func showNotesList() {
        guard window.attachedSheet == nil else { return }
        let entries = noteEntries()
        let current = topPageIndex
        let list = NotesList(entries: entries)
        list.onJump = { [weak self] entry in
            self?.notesList = nil
            self?.jump(to: entry)
        }
        list.onEdit = { [weak self] entry in
            self?.notesList = nil
            DispatchQueue.main.async { self?.editNote(entry.annotation, on: entry.page) }
        }
        list.onDelete = { [weak self, weak list] entry in
            guard let self else { return }
            self.change(.remove(entry.annotation, entry.page))
            self.save(saying: "deleted")
            list?.update(self.noteEntries())
        }
        notesList = list
        list.show(on: window, selecting: entries.firstIndex { $0.pageIndex >= current } ?? 0)
    }

    private func jump(to entry: NoteEntry) {
        rememberSpot()
        let bounds = entry.annotation.bounds
        let box = entry.page.bounds(for: .mediaBox)
        pdfView.go(to: PDFDestination(page: entry.page, at: NSPoint(x: box.minX, y: min(bounds.maxY + 80, box.maxY))))
        flash(at: NSPoint(x: bounds.minX, y: bounds.maxY - 12), on: entry.page)
        window.makeFirstResponder(pdfView)
        if !entry.note.isEmpty { message("✎ " + entry.note.replacingOccurrences(of: "\n", with: " ")) }
        lastClick = (entry.page, NSPoint(x: bounds.midX, y: bounds.midY))
        updateStatus()
    }

    private func deleteHighlight() {
        popover?.close()
        if let click = lastClick, let annotation = noteAnnotation(at: click) {
            remove(annotation, from: click.page)
            return
        }
        var removed = 0
        if let selection = pdfView.currentSelection, selectedText != nil {
            for page in selection.pages {
                let area = selection.bounds(for: page)
                guard area.minX.isFinite, area.minY.isFinite else { continue }
                for annotation in page.annotations where annotation.type == "Highlight"
                    && NoxPage.highlightRects(annotation).contains(where: { $0.intersects(area) }) {
                    change(.remove(annotation, page)); removed += 1
                }
            }
        }
        if removed == 0 { message("click a highlight or note first (or select over it)", error: true); return }
        pdfView.clearSelection()
        save(saying: "removed \(removed) highlight\(removed == 1 ? "" : "s")")
    }

    /// Writes annotations into the PDF itself. PDFKit's output has sloppy cross-reference
    /// tables, so it's cleaned with qpdf when available; the original is replaced only at the end.
    private func markDirty(_ page: PDFPage) {
        if let index = document?.index(for: page) { dirtyPages.insert(index) }
    }

    /// The PDF to write: a fresh copy of the file on disk with the changed pages' annotations
    /// replaced by ours. The displayed document can't be written directly, because PDFKit
    /// would render its recolored NoxPages into the file.
    private func dataForSaving() -> Data? {
        guard let shown = document, let fresh = PDFDocument(url: url), fresh.pageCount == shown.pageCount else { return nil }
        for index in dirtyPages {
            guard let source = shown.page(at: index), let target = fresh.page(at: index) else { return nil }
            target.annotations.forEach { target.removeAnnotation($0) }
            // Pop-ups are left out: without them PDFKit writes each note once, cleanly.
            for annotation in source.annotations where annotation.type != "Popup" {
                guard let copy = annotation.copy() as? PDFAnnotation else { return nil }
                copy.popup = nil
                copy.contents = annotation.contents  // dropping the pop-up drops the text; put it back
                copy.shouldDisplay = true              // nox may hide it on screen; never in the file
                target.addAnnotation(copy)
            }
        }
        return fresh.dataRepresentation()
    }

    // MARK: - Undo

    /// One change to the PDF's annotations; undo applies it backwards.
    enum Edit {
        case add(PDFAnnotation, PDFPage)
        case remove(PDFAnnotation, PDFPage)
        case contents(PDFAnnotation, PDFPage, old: String?, new: String?)
        case color(PDFAnnotation, PDFPage, old: NSColor, new: NSColor)
    }
    private var pendingEdits: [Edit] = []
    private var undoStack: [(label: String, edits: [Edit])] = []
    private var redoStack: [(label: String, edits: [Edit])] = []

    /// Applies a change and records it; the next save() closes it as one undo step.
    private func change(_ edit: Edit) {
        apply(edit, backwards: false)
        pendingEdits.append(edit)
    }

    private func apply(_ edit: Edit, backwards: Bool) {
        switch edit {
        case let .add(annotation, page):
            if backwards { page.removeAnnotation(annotation) } else { page.addAnnotation(annotation) }
            markDirty(page)
        case let .remove(annotation, page):
            if backwards { page.addAnnotation(annotation) } else { page.removeAnnotation(annotation) }
            markDirty(page)
        case let .contents(annotation, page, old, new):
            annotation.contents = backwards ? old : new
            markDirty(page)
        case let .color(annotation, page, old, new):
            annotation.color = backwards ? old : new
            markDirty(page)
        }
    }

    /// `u`: undo the last change to highlights and notes (saved to the file right away).
    func undo() {
        guard let step = undoStack.popLast() else { message("nothing to undo"); return }
        popover?.close()
        step.edits.reversed().forEach { apply($0, backwards: true) }
        redoStack.append(step)
        save(saying: "undone: \(step.label)", recording: false)
    }

    /// `Ctrl-r`: redo.
    func redo() {
        guard let step = redoStack.popLast() else { message("nothing to redo"); return }
        popover?.close()
        step.edits.forEach { apply($0, backwards: false) }
        undoStack.append(step)
        save(saying: "redone: \(step.label)", recording: false)
    }

    /// Writes the changed pages to the file. `live` (a note being typed) writes without closing
    /// the undo step, so the whole editing session becomes one step when the note closes.
    private func save(saying text: String, recording: Bool = true, live: Bool = false) {
        if !live {
            if recording, !pendingEdits.isEmpty {
                undoStack.append((text, pendingEdits))
                if undoStack.count > 200 { undoStack.removeFirst() }
                redoStack = []
            }
            pendingEdits = []
        }
        // Pages are drawn (and cached) with their highlights baked in; redraw the changed ones.
        refreshNotes()
        guard stamp() == fileStamp else {
            message("the file changed on disk; press r to reload, then redo this", error: true); return
        }
        guard let data = dataForSaving() else { message("could not save", error: true); return }
        let folder = url.deletingLastPathComponent()
        let raw = folder.appendingPathComponent(".\(url.lastPathComponent).nox-raw")
        let clean = folder.appendingPathComponent(".\(url.lastPathComponent).nox-clean")
        defer { try? FileManager.default.removeItem(at: raw); try? FileManager.default.removeItem(at: clean) }
        do {
            try data.write(to: raw)
            let qpdf = "/opt/homebrew/bin/qpdf"
            let cleaned = FileManager.default.isExecutableFile(atPath: qpdf)
                && run(qpdf, ["--warning-exit-0", raw.path, clean.path]) != nil
                && FileManager.default.fileExists(atPath: clean.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: cleaned ? clean : raw)
            fileStamp = stamp()
            dirtyPages = []
            message(text)
        } catch {
            message("could not save: \(error.localizedDescription)", error: true)
        }
    }

    private func quoteSelection() {
        guard let selection = pdfView.currentSelection, let text = selectedText,
              let page = selection.pages.first, let doc = document else {
            message("select text first", error: true); return
        }
        Notes.quote(pdf: path, pageIndex: doc.index(for: page), text: text)
        message("quote sent to notes")
    }

    // MARK: - Keyboard selection (visual mode)

    private func text(_ page: Int) -> NSString {
        if let cached = pageTexts[page] { return cached }
        let text = (document?.page(at: page)?.string ?? "") as NSString
        pageTexts[page] = text
        return text
    }

    /// Lines in reading order, as PDFKit groups them for selection.
    private func lines(_ pageIndex: Int) -> [VisualLine] {
        if let cached = pageLines[pageIndex] { return cached }
        var result: [VisualLine] = []
        if let page = document?.page(at: pageIndex), let all = page.selection(for: page.bounds(for: .cropBox)) {
            for line in all.selectionsByLine() {
                guard let own = line.pages.first else { continue }
                let n = line.numberOfTextRanges(on: own)
                guard n > 0 else { continue }
                let first = line.range(at: 0, on: own), last = line.range(at: n - 1, on: own)
                let rect = line.bounds(for: own)
                guard first.location != NSNotFound, last.location != NSNotFound, rect.width > 0,
                      rect.minX.isFinite, rect.minY.isFinite else { continue }
                result.append(VisualLine(rect: rect, start: first.location,
                                         end: max(first.location, last.location + max(last.length, 1) - 1)))
            }
        }
        pageLines[pageIndex] = result
        return result
    }

    private func lineNumber(_ p: TextPos) -> Int? {
        let all = lines(p.page)
        if let exact = all.firstIndex(where: { $0.start <= p.index && p.index <= $0.end }) { return exact }
        return all.indices.min { abs(all[$0].start - p.index) < abs(all[$1].start - p.index) }
    }

    private func isSpace(_ c: unichar) -> Bool { CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(c) ?? " ") }
    private func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 }

    /// `v` / `V`: start at the current (search) selection, or label the visible lines to pick one.
    private func startVisual(linewise: Bool) {
        if !linewise, let selection = pdfView.currentSelection, selectedText != nil, let range = textRange(of: selection) {
            visual = range
            showVisual()
            message("h j k l  w b e  0 $  f t ; ,  o  ·  ca–ce highlight  a note  y copy  Esc cancel")
            return
        }
        showHints(linewise: linewise)
    }

    /// Character range of a selection (used to start from a search match).
    private func textRange(of selection: PDFSelection) -> (anchor: TextPos, head: TextPos)? {
        guard let doc = document, let first = selection.pages.first, let last = selection.pages.last else { return nil }
        let n = selection.numberOfTextRanges(on: last)
        guard selection.numberOfTextRanges(on: first) > 0, n > 0 else { return nil }
        let a = selection.range(at: 0, on: first), b = selection.range(at: n - 1, on: last)
        guard a.location != NSNotFound, b.location != NSNotFound else { return nil }
        return (TextPos(page: doc.index(for: first), index: a.location),
                TextPos(page: doc.index(for: last), index: b.location + max(b.length, 1) - 1))
    }

    private func showHints(linewise: Bool) {
        guard let doc = document else { return }
        clearHints()
        var targets: [(TextPos, NSRect)] = []
        for page in pdfView.visiblePages {
            let index = doc.index(for: page), s = text(index)
            for line in lines(index) {
                var first = line.start
                while first < min(line.end, s.length - 1), isSpace(s.character(at: first)) { first += 1 }
                let r = pdfView.convert(line.rect, from: page)
                guard pdfView.bounds.insetBy(dx: 0, dy: 4).contains(NSPoint(x: r.minX + 1, y: r.midY)) else { continue }
                targets.append((TextPos(page: index, index: first), r))
            }
        }
        guard !targets.isEmpty else { message("no text on screen", error: true); return }
        for ((pos, _), label) in zip(targets, placeTags(at: targets.map { $0.1 }, leftOf: true)) { hints[label] = pos }
        hintLinewise = linewise
        message("type a line's label  ·  Esc cancel")
        updateStatus()
    }

    /// Second step of `v`: label every word of the chosen line. False when there is nothing to choose.
    private func showWordHints(on pos: TextPos) -> Bool {
        guard let doc = document, let page = doc.page(at: pos.page), let n = lineNumber(pos) else { return false }
        let line = lines(pos.page)[n], s = text(pos.page)
        let last = min(line.end, s.length - 1)
        var targets: [(TextPos, NSRect)] = []
        var i = line.start
        while i <= last {
            while i <= last, isSpace(s.character(at: i)) { i += 1 }
            guard i <= last else { break }
            let start = i
            while i <= last, !isSpace(s.character(at: i)) { i += 1 }
            let rect = textRect(page, NSRange(location: start, length: i - start))
            // PDFKit's character range for a line can spill into its neighbours: keep only words on it.
            if rect.width > 0, rect.minX.isFinite, abs(rect.midY - line.rect.midY) < line.rect.height / 2 {
                targets.append((TextPos(page: pos.page, index: start), pdfView.convert(rect, from: page)))
            }
        }
        targets.sort { $0.1.minX < $1.1.minX }
        guard targets.count > 1 else { return false }
        for ((p, _), label) in zip(targets, placeTags(at: targets.map { $0.1 }, leftOf: false, above: true)) { hints[label] = p }
        hintWords = true
        hintLinewise = false
        message("type a word's label to start there  ·  Esc cancel")
        return true
    }

    static func hintLabels(_ count: Int) -> [String] {
        let alphabet = Array("asdfjklghqwertyuiopzxcvbnm").map(String.init)
        return count <= alphabet.count ? Array(alphabet.prefix(count))
            : Array(alphabet.flatMap { a in alphabet.map { a + $0 } }.prefix(count))
    }

    /// Draws a yellow label for each rectangle (view coordinates) and returns the labels.
    private func placeTags(at rects: [NSRect], leftOf: Bool, above: Bool = false) -> [String] {
        hintTyped = ""
        let labels = Self.hintLabels(rects.count)
        for (rect, label) in zip(rects, labels) {
            let tag = NSTextField(labelWithString: label)
            tag.font = .monospacedSystemFont(ofSize: above ? 11 : 13, weight: .bold)
            tag.textColor = Theme.darker
            tag.drawsBackground = true
            tag.backgroundColor = Theme.highlightColors["a"]!
            tag.wantsLayer = true
            tag.layer?.cornerRadius = 3
            tag.stringValue = " \(label) "
            tag.sizeToFit()
            tag.frame.origin = above
                ? NSPoint(x: rect.minX, y: pdfView.isFlipped ? rect.minY - tag.frame.height : rect.maxY)
                : leftOf
                ? NSPoint(x: max(2, rect.minX - tag.frame.width - 4), y: rect.midY - tag.frame.height / 2)
                : NSPoint(x: rect.minX, y: rect.maxY - tag.frame.height / 2)
            if leftOf && !above {
                // Two columns: a label left of a right-column line would cover the end of the line beside it.
                // Then it goes after the line, unless that covers text too.
                let covers = { (frame: NSRect) in rects.contains { $0 != rect && $0.insetBy(dx: 0, dy: 2).intersects(frame) } }
                if covers(tag.frame) {
                    let right = NSRect(origin: NSPoint(x: rect.maxX + 4, y: tag.frame.minY), size: tag.frame.size)
                    if !covers(right) && right.maxX <= pdfView.bounds.maxX - 2 { tag.frame = right }
                }
            }
            pdfView.addSubview(tag)
            hintViews.append(tag)
        }
        return labels
    }

    // MARK: - Links, outline, spreads, presentation

    /// `f`: label every visible link; typing a label follows it (Ctrl-o comes back).
    private func showLinkHints() {
        clearHints()
        var targets: [(PDFAnnotation, PDFPage, NSRect)] = []
        for page in pdfView.visiblePages {
            for annotation in page.annotations where annotation.type == "Link" {
                let r = pdfView.convert(annotation.bounds, from: page)
                if pdfView.bounds.intersects(r) { targets.append((annotation, page, r)) }
            }
        }
        guard !targets.isEmpty else { message("no links on screen", error: true); return }
        for (target, label) in zip(targets, placeTags(at: targets.map { $0.2 }, leftOf: false)) {
            linkHints[label] = (target.0, target.1)
        }
        message("type a link's label  ·  Esc cancel")
        updateStatus()
    }

    private func follow(_ annotation: PDFAnnotation) {
        if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination {
            rememberSpot()
            pdfView.go(to: destination)
            message("'' or Ctrl-o to come back")
        } else if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
            NSWorkspace.shared.open(url)
            message("opened \(url.absoluteString)")
        } else if let action = annotation.action {
            pdfView.perform(action)
        }
    }

    // MARK: - Reference preview

    private func referenceItems(on page: PDFPage) -> [References.Item] {
        guard let index = document?.index(for: page) else { return [] }
        if let cached = referenceItems[index] { return cached }
        let found = References.items(on: page)
        referenceItems[index] = found
        return found
    }

    /// Mouse over a citation or internal link: its preview after a short pause.
    private func hover(at point: NSPoint) {
        guard editor == nil, window.attachedSheet == nil, presentation == nil, pdfView.bounds.contains(point),
              let page = pdfView.page(for: point, nearest: false), let index = document?.index(for: page) else {
            hoverTimer?.invalidate(); hovered = nil; return
        }
        let at = pdfView.convert(point, to: page)
        let item = referenceItems(on: page).first { $0.rect.insetBy(dx: -1, dy: -1).contains(at) }
        if let item, let hovered, hovered.page == index, hovered.rect == item.rect { return }
        hoverTimer?.invalidate()
        guard let item else {
            hovered = nil
            if preview?.isShown == true, previewFromHover { closePreview() }
            return
        }
        hovered = (index, item.rect)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.showPreview(of: item, on: page, fromKeyboard: false)
        }
    }

    private var previewFromHover = false

    /// `F`: label every citation and link on screen; typing a label previews it.
    private func showPreviewHints() {
        clearHints()
        var targets: [(References.Item, PDFPage, NSRect)] = []
        for page in pdfView.visiblePages {
            for item in referenceItems(on: page) {
                let r = pdfView.convert(item.rect, from: page)
                if pdfView.bounds.intersects(r) { targets.append((item, page, r)) }
            }
        }
        guard !targets.isEmpty else { message("no citations or links on screen", error: true); return }
        for (target, label) in zip(targets, placeTags(at: targets.map { $0.2 }, leftOf: false)) {
            previewHints[label] = (target.0, target.1)
        }
        message("type a label to preview what it cites  ·  Esc cancel")
        updateStatus()
    }

    /// Shows what a citation / link points to, next to it.
    private func showPreview(of item: References.Item, on page: PDFPage, fromKeyboard: Bool) {
        guard let doc = document else { return }
        closePreview()
        guard let place = References.place(of: item.target, in: doc, citedFrom: page, at: item.rect) else {
            if fromKeyboard { message("could not find what this cites", error: true) }
            return
        }
        let region = place.region
        let shown = min(2.2, max(1.0, 640 / max(region.width, 1)))       // display scale
        let image = References.image(of: place, scale: shown * (window.backingScaleFactor))
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        let size = NSSize(width: region.width * shown, height: min(region.height * shown, 520))
        let page = NSTextField(labelWithString: "p. \(doc.index(for: place.page) + 1)   ↩ or click: go there   Esc: close")
        page.font = .systemFont(ofSize: 11)
        page.textColor = Theme.comment
        let stack = NSStackView(views: [view, page])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: size.width),
                                     view.heightAnchor.constraint(equalToConstant: size.height)])
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(goToPreview)))
        let controller = NSViewController()
        controller.view = stack
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.behavior = .semitransient
        pop.animates = false
        pop.appearance = NSAppearance(named: .darkAqua)
        let anchor = pdfView.convert(item.rect, from: page)
        let below = pdfView.isFlipped ? pdfView.bounds.maxY - anchor.maxY : anchor.minY - pdfView.bounds.minY
        let above = pdfView.isFlipped ? anchor.minY : pdfView.bounds.maxY - anchor.maxY
        let down: NSRectEdge = pdfView.isFlipped ? .maxY : .minY, up: NSRectEdge = pdfView.isFlipped ? .minY : .maxY
        pop.show(relativeTo: anchor, of: pdfView, preferredEdge: below >= above ? down : up)
        preview = pop
        previewPlace = place
        previewFromHover = !fromKeyboard
        window.makeKey()        // keys (↩, Esc) stay with the document
    }

    @objc private func goToPreview() {
        guard let place = previewPlace else { return }
        closePreview()
        rememberSpot()
        pdfView.go(to: PDFDestination(page: place.page, at: NSPoint(x: place.region.minX, y: place.region.maxY + 20)))
        message("'' or Ctrl-o to come back")
        updateStatus()
    }

    private func closePreview() {
        preview?.close()
        preview = nil
        previewPlace = nil
    }

    /// `t`: the PDF's table of contents.
    private func showOutline() {
        guard window.attachedSheet == nil, let doc = document else { return }
        guard let root = doc.outlineRoot, root.numberOfChildren > 0 else { message("this PDF has no table of contents", error: true); return }
        var items: [PickerSheet.Item] = [], pages: [Int] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let page = (child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page).map { doc.index(for: $0) }
                items.append(.init(title: child.label ?? "—", detail: page.map { "p. \($0 + 1)" } ?? "", indent: depth))
                pages.append(page ?? -1)
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        let current = topPageIndex
        let sheet = PickerSheet(heading: "Contents", items: items) { [weak self] row in
            guard let self, let doc = self.document else { return }
            self.picker = nil
            let node = self.outlineNode(root, row)
            self.rememberSpot()
            if let dest = node?.destination ?? (node?.action as? PDFActionGoTo)?.destination { self.pdfView.go(to: dest) }
            else if pages[row] >= 0, let page = doc.page(at: pages[row]) { self.pdfView.go(to: page) }
            self.window.makeFirstResponder(self.pdfView)
            self.updateStatus()
        }
        picker = sheet
        sheet.show(on: window, selecting: max(0, (pages.lastIndex { $0 >= 0 && $0 <= current }) ?? 0))
    }

    /// The outline node shown in a given row (depth-first order, as listed).
    private func outlineNode(_ root: PDFOutline, _ row: Int) -> PDFOutline? {
        var n = -1
        func walk(_ node: PDFOutline) -> PDFOutline? {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                n += 1
                if n == row { return child }
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(root)
    }

    /// `T`: show or hide the page thumbnails (remembered for next time).
    func toggleThumbnails(saying: Bool = true) {
        let show = thumbnails.isHidden
        let top = topDestination
        thumbnails.isHidden = !show
        thumbnailsWidth.constant = show ? 150 : 0
        window.contentView?.layoutSubtreeIfNeeded()
        if pdfView.autoScales { pdfView.autoScales = true }
        if let top { pdfView.go(to: top) }
        UserDefaults.standard.set(show, forKey: "thumbnails")
        if saying { message(show ? "thumbnails (T to hide; click a page to go there)" : "") }
    }

    /// `s`: two pages side by side (book layout) or one.
    private func toggleSpread() {
        let top = topDestination
        if pdfView.displayMode == .twoUpContinuous {
            pdfView.displayMode = .singlePageContinuous
            message("single pages")
        } else {
            pdfView.displayMode = .twoUpContinuous
            pdfView.displaysAsBook = true
            message("two-page spread")
        }
        pdfView.autoScales = true
        if let top { pdfView.go(to: top) }
    }

    /// `p`: presentation mode from the current page.
    func startPresentation() {
        guard presentation == nil, let doc = document else { return }
        let show = PresentationController(document: doc, page: topPageIndex, from: window)
        show.onEnd = { [weak self] last in
            guard let self else { return }
            self.presentation = nil
            self.goToPage(last + 1)
            self.window.makeKeyAndOrderFront(nil)
        }
        presentation = show
    }

    private func typeHint(_ key: String) {
        hintTyped += key
        if !previewHints.isEmpty {
            if let target = previewHints[hintTyped] {
                clearHints()
                showPreview(of: target.item, on: target.page, fromKeyboard: true)
            } else if !previewHints.keys.contains(where: { $0.hasPrefix(hintTyped) }) {
                clearHints()
                message("no such label", error: true)
            } else {
                dimTags()
            }
            updateStatus()
            return
        }
        if !linkHints.isEmpty {
            if let target = linkHints[hintTyped] {
                clearHints()
                follow(target.annotation)
            } else if !linkHints.keys.contains(where: { $0.hasPrefix(hintTyped) }) {
                clearHints()
                message("no such label", error: true)
            } else {
                dimTags()
            }
            updateStatus()
            return
        }
        let matches = hints.filter { $0.key.hasPrefix(hintTyped) }
        if let pos = hints[hintTyped] {
            let linewise = hintLinewise, words = hintWords
            clearHints()
            if !linewise && !words && showWordHints(on: pos) {
                updateStatus()
                return
            }
            if linewise {
                visual = (TextPos(page: pos.page, index: lineStart(pos)), TextPos(page: pos.page, index: lineEnd(pos)))
            } else {
                let end = wordEnd(pos)
                visual = (pos, end)
            }
            showVisual()
            message("h j k l  w b e  0 $  f t ; ,  o  ·  ca–ce highlight  a note  y copy  Esc cancel")
        } else if matches.isEmpty {
            clearHints()
            message("no such label", error: true)
        } else {
            dimTags()
        }
        updateStatus()
    }

    private func dimTags() {
        for view in hintViews {
            if let tag = view as? NSTextField {
                tag.alphaValue = tag.stringValue.trimmingCharacters(in: .whitespaces).hasPrefix(hintTyped) ? 1 : 0.25
            }
        }
    }

    private func clearHints() {
        hintViews.forEach { $0.removeFromSuperview() }
        hintViews = []
        hints = [:]
        hintWords = false
        linkHints = [:]
        previewHints = [:]
        hintTyped = ""
    }

    private func exitVisual(clear: Bool) {
        tentative = nil
        guard visual != nil else { return }
        visual = nil
        if clear { pdfView.clearSelection() }
        updateStatus()
    }

    /// Moves or acts in visual mode; nil means "not a visual-mode key".
    private func performVisual(_ sequence: String, times: Int) -> Bool? {
        guard var (anchor, head) = visual else { return nil }
        func repeatMove(_ f: (TextPos) -> TextPos) { for _ in 0..<times { head = f(head) } }
        switch sequence {
        case "w": repeatMove(nextWordStart)
        case "b": repeatMove(previousWordStart)
        case "e": repeatMove { self.wordEnd(TextPos(page: $0.page, index: $0.index + 1)) }
        case "j": repeatMove { self.verticalMove($0, down: true) }
        case "k": repeatMove { self.verticalMove($0, down: false) }
        case "h": repeatMove { self.characterMove($0, by: -1) }
        case "l": repeatMove { self.characterMove($0, by: 1) }
        case ";", "rev":
            guard let last = lastFind else { return true }
            let forward = sequence == ";" ? last.forward : !last.forward
            repeatMove { self.find(last.char, from: $0, forward: forward, till: last.till, again: true) }
        case _ where sequence.count == 2 && "fFtT".contains(sequence.prefix(1)):
            guard let c = sequence.dropFirst().utf16.first else { return true }
            let kind = sequence.first!
            lastFind = (c, kind == "f" || kind == "t", kind == "t" || kind == "T")
            repeatMove { self.find(c, from: $0, forward: kind == "f" || kind == "t", till: kind == "t" || kind == "T", again: false) }
        case "0": head = TextPos(page: head.page, index: lineStart(head))
        case "$": head = TextPos(page: head.page, index: lineEnd(head))
        case "o": swap(&anchor, &head)
        case "v", "V": exitVisual(clear: true); message(""); return true
        case "y": yank(); exitVisual(clear: true); return true
        case "a": annotate(); visual = nil; return true
        case ",q": quoteSelection(); exitVisual(clear: true); return true
        default:
            if sequence.count == 2, sequence.first == "c", let letter = sequence.last {
                highlight(letter)
                visual = nil
                return true
            }
            return nil
        }
        visual = (anchor, head)
        showVisual()
        return true
    }

    private func showVisual() {
        guard let (anchor, head) = visual, let doc = document else { return }
        let (a, b) = (anchor.page, anchor.index) <= (head.page, head.index) ? (anchor, head) : (head, anchor)
        guard let pa = doc.page(at: a.page), let pb = doc.page(at: b.page),
              let selection = doc.selection(from: pa, atCharacterIndex: a.index, to: pb, atCharacterIndex: b.index) else { return }
        pdfView.setCurrentSelection(selection, animate: false)
        // keep the moving end on screen
        if let page = doc.page(at: head.page) {
            let r = textRect(page, NSRange(location: head.index, length: 1))
            let inView = pdfView.convert(r, from: page)
            if !pdfView.bounds.insetBy(dx: 0, dy: 30).contains(inView) {
                pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: page.bounds(for: .mediaBox).minX, y: r.maxY + visibleHeight / 3 / max(pdfView.scaleFactor, 0.1))))
            }
        }
        updateStatus()
    }

    // Text motions (words are runs of non-space characters, as in Vim's W/B/E).

    private func nextWordStart(_ p: TextPos) -> TextPos {
        let s = text(p.page)
        var i = p.index
        while i < s.length, !isSpace(s.character(at: i)) { i += 1 }
        while i < s.length, isSpace(s.character(at: i)) { i += 1 }
        if i < s.length { return TextPos(page: p.page, index: i) }
        guard p.page + 1 < (document?.pageCount ?? 0) else { return p }
        return firstWord(page: p.page + 1) ?? p
    }

    private func firstWord(page: Int) -> TextPos? {
        let s = text(page)
        var i = 0
        while i < s.length, isSpace(s.character(at: i)) { i += 1 }
        return i < s.length ? TextPos(page: page, index: i) : nil
    }

    private func previousWordStart(_ p: TextPos) -> TextPos {
        let s = text(p.page)
        var i = p.index - 1
        while i >= 0, isSpace(s.character(at: i)) { i -= 1 }
        if i < 0 {
            guard p.page > 0 else { return p }
            let prev = text(p.page - 1)
            return prev.length > 0 ? previousWordStart(TextPos(page: p.page - 1, index: prev.length)) : p
        }
        while i > 0, !isSpace(s.character(at: i - 1)) { i -= 1 }
        return TextPos(page: p.page, index: i)
    }

    private func wordEnd(_ p: TextPos) -> TextPos {
        let s = text(p.page)
        var i = min(p.index, s.length - 1)
        guard i >= 0 else { return p }
        while i < s.length, isSpace(s.character(at: i)) { i += 1 }
        while i + 1 < s.length, !isSpace(s.character(at: i + 1)) { i += 1 }
        return TextPos(page: p.page, index: min(i, s.length - 1))
    }

    private func lineStart(_ p: TextPos) -> Int {
        guard let n = lineNumber(p) else { return p.index }
        let s = text(p.page), line = lines(p.page)[n]
        var i = line.start
        while i < min(line.end, s.length - 1), isSpace(s.character(at: i)) { i += 1 }
        return i
    }

    private func lineEnd(_ p: TextPos) -> Int {
        guard let n = lineNumber(p) else { return p.index }
        let s = text(p.page), line = lines(p.page)[n]
        var i = min(line.end, s.length - 1)
        while i > line.start, isSpace(s.character(at: i)) { i -= 1 }
        return i
    }

    /// h / l: one character left / right, staying on the line (as in Vim).
    private func characterMove(_ p: TextPos, by step: Int) -> TextPos {
        guard let n = lineNumber(p) else { return p }
        let line = lines(p.page)[n]
        let s = text(p.page)
        let i = min(max(p.index + step, line.start), min(line.end, s.length - 1))
        return TextPos(page: p.page, index: max(i, 0))
    }

    /// f / F / t / T: the next / previous `c` (t / T: the character next to it). Unlike Vim it
    /// doesn't stop at the end of the line, since PDF lines are short: it reads on through the
    /// page and the next few pages. `again` (for ; and ,) skips a match right next to the cursor.
    private func find(_ c: unichar, from p: TextPos, forward: Bool, till: Bool, again: Bool) -> TextPos {
        let step = forward ? 1 : -1
        let pageCount = document?.pageCount ?? 0
        var page = p.page
        var i = p.index + step + (till && again ? step : 0)
        for _ in 0..<4 {                                    // this page and up to three more
            let s = text(page)
            if !forward && i >= s.length { i = s.length - 1 }
            while i >= 0 && i < s.length {
                if s.character(at: i) == c {
                    let index = till ? i - step : i
                    // t / T at the very start of a page: stay on the match's page
                    return TextPos(page: page, index: max(0, min(index, s.length - 1)))
                }
                i += step
            }
            page += step
            guard page >= 0, page < pageCount else { break }
            i = forward ? 0 : Int.max
        }
        message("not found: \(Character(UnicodeScalar(c) ?? " "))", error: true)
        return p
    }

    /// j / k: the line below / above, keeping the horizontal position.
    private func verticalMove(_ p: TextPos, down: Bool) -> TextPos {
        guard let doc = document, let page = doc.page(at: p.page), let n = lineNumber(p) else { return p }
        var target = (page: p.page, line: n + (down ? 1 : -1))
        if target.line < 0 || target.line >= lines(p.page).count {
            let next = p.page + (down ? 1 : -1)
            guard next >= 0, next < doc.pageCount, !lines(next).isEmpty else { return p }
            target = (next, down ? 0 : lines(next).count - 1)
        }
        let line = lines(target.page)[target.line]
        guard let targetPage = doc.page(at: target.page) else { return p }
        let x = textRect(page, NSRange(location: p.index, length: 1)).midX
        // The character on the target line closest to the same horizontal position.
        var best: (index: Int, distance: CGFloat)?
        let s = text(target.page)
        for i in line.start...min(line.end, s.length - 1) where !isSpace(s.character(at: i)) {
            let r = textRect(targetPage, NSRange(location: i, length: 1))
            guard r.width > 0, r.midX.isFinite else { continue }
            let d = abs(r.midX - x)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        if let best { return TextPos(page: target.page, index: best.index) }
        let probe = TextPos(page: target.page, index: line.start)
        return TextPos(page: target.page, index: x < line.rect.midX ? lineStart(probe) : lineEnd(probe))
    }

    /// Where a stretch of a page's text is on the page. PDFPage.characterBounds(at:) and
    /// characterIndex(at:) disagree with the page's text on some PDFs (journal papers, two
    /// columns), so the geometry comes from a selection of the same characters instead.
    private func textRect(_ page: PDFPage, _ range: NSRange) -> NSRect {
        guard range.length > 0, let r = page.selection(for: range)?.bounds(for: page),
              r.minX.isFinite, r.minY.isFinite else { return .null }
        return r
    }

    // MARK: - Colors

    func toggleColors() {
        Theme.recolor.toggle()
        (NSApp.delegate as? AppDelegate)?.themeChanged()
    }

    /// Redraws highlights and note dots after any change.
    func refreshNotes() {
        document?.showNativeHighlights(!Theme.recolor)
        overlays.refresh()
    }

    func applyTheme() {
        let top = topDestination
        pdfView.backgroundColor = Theme.recolor ? Theme.darker : NSColor(white: 0.25, alpha: 1)
        // PDFKit caches rendered pages; handing it the document again forces a redraw.
        if let doc = document {
            let autoScales = pdfView.autoScales, scale = pdfView.scaleFactor
            overlays.reset()
            pdfView.document = nil
            pdfView.document = doc
            if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        }
        refreshNotes()
        if let top { pdfView.go(to: top) }
        updateStatus()
    }

    // MARK: - SyncTeX

    func forwardSearch(line: Int, tex: String) {
        guard let hit = SyncTeX.forward(line: line, tex: tex, pdf: path),
              let page = document?.page(at: hit.page - 1) else {
            message("synctex: no match for line \(line)", error: true); return
        }
        rememberSpot()
        let box = page.bounds(for: .mediaBox)
        let point = NSPoint(x: box.minX + hit.x, y: box.maxY - hit.y)
        pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: box.minX, y: point.y + 120)))
        flash(at: point, on: page)
    }

    /// Briefly marks a line after a forward search.
    private func flash(at point: NSPoint, on page: PDFPage) {
        pdfView.layoutDocumentView()
        let viewPoint = pdfView.convert(point, from: page)
        let marker = NSView(frame: NSRect(x: 4, y: viewPoint.y - 3, width: pdfView.bounds.width - 8, height: 16))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.35).cgColor
        marker.layer?.cornerRadius = 3
        pdfView.addSubview(marker)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { marker.removeFromSuperview() }
    }

    private func inverseSearch() {
        guard let click = lastClick, let doc = document else { return }
        let box = click.page.bounds(for: .mediaBox)
        let x = click.point.x - box.minX
        let y = box.maxY - click.point.y
        guard let hit = SyncTeX.inverse(page: doc.index(for: click.page) + 1, x: x, y: y, pdf: path) else {
            message("synctex: no source here (is there a .synctex.gz?)", error: true); return
        }
        SyncTeX.openInEditor(file: hit.file, line: hit.line)
        message("→ \((hit.file as NSString).lastPathComponent):\(hit.line)")
    }

    // MARK: - Auto-reload

    private func stamp() -> [String] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return [] }
        return ["\(attrs[.modificationDate] ?? "")", "\(attrs[.size] ?? "")"]
    }

    private func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkFile()
        }
    }

    /// Reloads once the file has changed and stayed the same for one tick (LaTeX writes in pieces).
    private func checkFile() {
        let now = stamp()
        guard !now.isEmpty, now != fileStamp else { changedStamp = []; return }
        if now == changedStamp {
            reload(force: false)
        } else {
            changedStamp = now
        }
    }

    func reload(force: Bool) {
        let destination = topDestination
        let pageIndex = destination?.page.flatMap { document?.index(for: $0) } ?? 0
        let point = destination?.point ?? .zero
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor
        guard let doc = makeDocument() else {
            if force { message("could not reload", error: true) }
            return
        }
        overlays.reset()
        pdfView.document = doc
        refreshNotes()
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        if let page = doc.page(at: min(pageIndex, doc.pageCount - 1)) {
            pdfView.go(to: PDFDestination(page: page, at: point))
        }
        fileStamp = stamp()
        changedStamp = []
        searchResults = []
        dirtyPages = []
        pageTexts = [:]
        referenceItems = [:]
        pageLines = [:]
        clearHints(); visual = nil
        undoStack = []; redoStack = []; pendingEdits = []
        message("reloaded")
        updateStatus()
    }

    // MARK: - Remembered positions

    private static let positionsKey = "positions"

    /// Positions are only saved once the window is up and the saved one restored: while a
    /// window is being set up PDFKit reports "page 1", which would overwrite the real place.
    private var positionReady = false

    private func savePosition() {
        guard positionReady, window.isVisible, pdfView.bounds.height > 0 else { return }
        guard let dest = topDestination, let page = dest.page, let doc = document else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.positionsKey) ?? [:]
        all[path] = ["page": doc.index(for: page), "y": dest.point.y,
                     "scale": pdfView.scaleFactor, "auto": pdfView.autoScales]
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
    }

    private func restorePosition() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.positionsKey)?[path] as? [String: Any],
              let index = saved["page"] as? Int, let page = document?.page(at: index) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.positionReady = true }
            return
        }
        if saved["auto"] as? Bool == false, let scale = saved["scale"] as? CGFloat {
            pdfView.autoScales = false
            pdfView.scaleFactor = scale
        }
        let y = saved["y"] as? CGFloat ?? page.bounds(for: .mediaBox).maxY
        // The window needs its layout before PDFKit will scroll, and a fresh launch can lay it
        // out again afterwards; so go there once, then check again (unless you've moved on).
        let destination = PDFDestination(page: page, at: NSPoint(x: page.bounds(for: .mediaBox).minX, y: y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.pdfView.go(to: destination)
            self.updateStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if self.topPageIndex == 0, index != 0 { self.pdfView.go(to: destination); self.updateStatus() }
                self.positionReady = true
            }
        }
    }

    // MARK: - Help and closing

    func showHelp() {
        guard window.attachedSheet == nil else { return }
        let sheet = HelpSheet()
        help = sheet
        sheet.show(on: window)
    }

    func windowWillClose(_ notification: Notification) {
        savePosition()
        presentation?.end()
        timer?.invalidate()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }

    /// Centre of a note's first rectangle in global screen coordinates, top-left origin (for tests).
    private func screenPoint(of entry: NoteEntry) -> [CGFloat] {
        guard let rect = NoxPage.highlightRects(entry.annotation).first else { return [] }
        let inView = pdfView.convert(NSPoint(x: rect.midX, y: rect.midY), from: entry.page)
        guard pdfView.bounds.contains(inView) else { return [] }
        let onScreen = window.convertPoint(toScreen: pdfView.convert(inView, to: nil))
        let height = NSScreen.screens.first?.frame.height ?? 0
        return [onScreen.x, height - onScreen.y]
    }

    /// Test hook (`nox --click-note N [right]`): clicks the middle of note N as the mouse would.
    func clickNote(_ number: Int, right: Bool) {
        let entries = noteEntries()
        guard number >= 1, number <= entries.count,
              let rect = NoxPage.highlightRects(entries[number - 1].annotation).first else { return }
        let point = pdfView.convert(NSPoint(x: rect.midX, y: rect.midY), from: entries[number - 1].page)
        if right {
            lastClick = (entries[number - 1].page, NSPoint(x: rect.midX, y: rect.midY))
            menuTarget = (entries[number - 1].annotation, entries[number - 1].page)
            return
        }
        if !mouseDown(at: point, shift: false) { mouseUp() }
    }

    /// Test hook: choose a row in the open list (contents).
    func pickRow(_ row: Int) { picker?.pick(row: row) }

    /// Test hook for the right-click menu's items: "edit", "delete" or a color letter.
    func menuAction(_ name: String) {
        switch name {
        case "edit": menuEdit()
        case "delete": menuDelete()
        default:
            let item = NSMenuItem(); item.representedObject = name; menuColor(item)
        }
    }

    /// Test hook (`nox --snapshot out.png`): a picture of this window as drawn on screen.
    func snapshot(to path: String) {
        if let presentation { presentation.snapshot(to: path); return }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        if let sheet = window.attachedSheet ?? editor?.window ?? preview?.contentViewController?.view.window,
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(sheet.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-sheet.png")))
        }
    }

    /// Snapshot for `nox --state`.
    func state() -> [String: Any] {
        return ["file": path, "page": topPageIndex + 1, "pages": document?.pageCount ?? 0,
                "scale": pdfView.scaleFactor, "recolor": Theme.recolor, "window": window.windowNumber,
                "status": statusLabel.stringValue, "message": messageLabel.stringValue,
                "notes": noteEntries().map { ["page": $0.pageIndex + 1, "type": $0.annotation.type ?? "",
                                              "note": $0.note, "quote": $0.quote,
                                              "rects": NoxPage.highlightRects($0.annotation).count,
                                              "screen": screenPoint(of: $0)] },
                "sheet": window.attachedSheet != nil, "editor": editor != nil, "preview": preview?.isShown ?? false, "previewPage": previewPlace.map { (document?.index(for: $0.page) ?? -1) + 1 } ?? 0,
                "previewable": pdfView.visiblePages.reduce(0) { $0 + referenceItems(on: $1).count }, "editorKey": editor?.window?.isKeyWindow ?? false,
                "popover": popover?.isShown ?? false,
                "tabs": window.tabbedWindows?.count ?? 1, "tabIndex": (window.tabbedWindows?.firstIndex { $0 === window } ?? 0) + 1,
                "visual": visual != nil, "hints": hints.count, "links": linkHints.count,
                "presentation": presentation?.state ?? [:], "spread": pdfView.displayMode == .twoUpContinuous, "thumbnails": !thumbnails.isHidden,
                "selection": pdfView.currentSelection?.string ?? "",
                "selectionPages": pdfView.currentSelection?.pages.compactMap { document?.index(for: $0) } ?? []]
    }
}


