import AppKit
import PDFKit

/// A borderless window that can still take keys.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Presentation mode: slides full screen (on the second display when there is one), and a
/// presenter view with current slide, next slide, timer and clock on the laptop screen.
final class PresentationController: NSObject {
    private let document: PDFDocument
    private let slideWindow: KeyWindow
    private let slideView = PDFView()
    private var presenterWindow: KeyWindow?
    private let currentView = PDFView()
    private let nextView = PDFView()
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let clockLabel = NSTextField(labelWithString: "")
    private let counterLabel = NSTextField(labelWithString: "")
    private let endLabel = NSTextField(labelWithString: "End of presentation")
    private let blackout = NSView()
    private var index: Int
    private var started = Date()
    private var paused: Date?
    private var timer: Timer?
    private var monitors: [Any] = []
    private var count = "", pending = ""
    private let savedRecolor: Bool
    var onEnd: ((Int) -> Void)?

    init(document: PDFDocument, page: Int, from window: NSWindow) {
        self.document = document
        index = page
        savedRecolor = Theme.recolor
        let home = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let projector = NSScreen.screens.first { $0 != home }
        let slideScreen = projector ?? home
        slideWindow = KeyWindow(contentRect: slideScreen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()

        // The audience sees the slides as designed.
        if Theme.recolor { Theme.recolor = false; (NSApp.delegate as? AppDelegate)?.themeChanged() }

        configure(slideView, background: .black)
        slideWindow.setFrame(slideScreen.frame, display: true)
        slideWindow.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        slideWindow.backgroundColor = .black
        slideWindow.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: slideScreen.frame.size))
        slideView.frame = content.bounds
        slideView.autoresizingMask = [.width, .height]
        content.addSubview(slideView)
        blackout.frame = content.bounds
        blackout.autoresizingMask = [.width, .height]
        blackout.wantsLayer = true
        blackout.layer?.backgroundColor = NSColor.black.cgColor
        blackout.isHidden = true
        content.addSubview(blackout)
        slideWindow.contentView = content

        if projector != nil { buildPresenter(on: home) }

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        presenterWindow?.makeKeyAndOrderFront(nil)
        slideWindow.orderFrontRegardless()
        if presenterWindow == nil { slideWindow.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.setHiddenUntilMouseMoves(true)

        installMonitors()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.async { self.show(self.index) }
    }

    private func configure(_ view: PDFView, background: NSColor) {
        view.document = document
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.pageShadowsEnabled = false
        view.autoScales = true
        view.backgroundColor = background
        view.displayBox = .cropBox
    }

    private func buildPresenter(on screen: NSScreen) {
        let window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: true)
        window.backgroundColor = Theme.darker
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        configure(currentView, background: Theme.darker)
        configure(nextView, background: Theme.darker)
        for view in [currentView, nextView] { view.translatesAutoresizingMaskIntoConstraints = false }

        let nextTitle = NSTextField(labelWithString: "NEXT")
        for (label, size, color) in [(timerLabel, 64.0, Theme.foreground), (clockLabel, 28.0, Theme.comment),
                                     (counterLabel, 28.0, Theme.accent), (nextTitle, 13.0, Theme.comment),
                                     (endLabel, 20.0, Theme.comment)] {
            label.font = .monospacedDigitSystemFont(ofSize: size, weight: size > 40 ? .light : .regular)
            label.textColor = color
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        let hint = NSTextField(labelWithString: "→ / Space next   ← previous   b blank   12⏎ go to slide   r restart timer   t pause   Esc end")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Theme.comment
        hint.translatesAutoresizingMaskIntoConstraints = false
        endLabel.isHidden = true

        let content = NSView()
        window.contentView = content
        [currentView, nextView, timerLabel, clockLabel, counterLabel, nextTitle, endLabel, hint].forEach(content.addSubview)
        let margin: CGFloat = 32
        NSLayoutConstraint.activate([
            currentView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            currentView.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            currentView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -16),
            currentView.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.62),

            nextTitle.leadingAnchor.constraint(equalTo: currentView.trailingAnchor, constant: margin),
            nextTitle.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            nextView.leadingAnchor.constraint(equalTo: nextTitle.leadingAnchor),
            nextView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            nextView.topAnchor.constraint(equalTo: nextTitle.bottomAnchor, constant: 8),
            nextView.heightAnchor.constraint(equalTo: content.heightAnchor, multiplier: 0.36),
            endLabel.centerXAnchor.constraint(equalTo: nextView.centerXAnchor),
            endLabel.centerYAnchor.constraint(equalTo: nextView.centerYAnchor),

            counterLabel.leadingAnchor.constraint(equalTo: nextTitle.leadingAnchor),
            counterLabel.topAnchor.constraint(equalTo: nextView.bottomAnchor, constant: 28),
            timerLabel.leadingAnchor.constraint(equalTo: nextTitle.leadingAnchor),
            timerLabel.topAnchor.constraint(equalTo: counterLabel.bottomAnchor, constant: 12),
            clockLabel.leadingAnchor.constraint(equalTo: nextTitle.leadingAnchor),
            clockLabel.topAnchor.constraint(equalTo: timerLabel.bottomAnchor, constant: 6),

            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        presenterWindow = window
    }

    // MARK: - Slides

    private func show(_ newIndex: Int) {
        index = max(0, min(newIndex, document.pageCount - 1))
        if let page = document.page(at: index) {
            slideView.go(to: page)
            currentView.go(to: page)
        }
        if let next = document.page(at: index + 1) {
            nextView.isHidden = false
            endLabel.isHidden = true
            nextView.go(to: next)
        } else {
            nextView.isHidden = true
            endLabel.isHidden = false
        }
        counterLabel.stringValue = "\(index + 1) / \(document.pageCount)"
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func tick() {
        let elapsed = Int((paused ?? Date()).timeIntervalSince(started))
        timerLabel.stringValue = String(format: elapsed >= 3600 ? "%d:%02d:%02d" : "%3$02d:%2$02d",
                                        elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
        if elapsed < 3600 { timerLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }
        timerLabel.textColor = paused == nil ? Theme.foreground : Theme.comment
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        clockLabel.stringValue = formatter.string(from: Date())
    }

    private func redraw() {
        for view in [slideView, currentView, nextView] {
            view.document = nil
            view.document = document
        }
        show(index)
    }

    // MARK: - Keys and clicks

    private var windows: [NSWindow] { [slideWindow] + (presenterWindow.map { [$0] } ?? []) }

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.windows.contains(where: { $0 === event.window }) else { return event }
            if event.modifierFlags.contains(.command) { return event }
            self.handle(event)
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.slideWindow else { return event }
            let point = self.slideView.convert(event.locationInWindow, from: nil)
            if let page = self.slideView.page(for: point, nearest: false),
               page.annotation(at: self.slideView.convert(point, to: page))?.type == "Link" { return event }
            self.show(self.index + (event.type == .rightMouseDown ? -1 : 1))
            return nil
        } as Any)
    }

    func handle(_ event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?, .downArrow?, .pageDown?: step(1); return
        case .leftArrow?, .upArrow?, .pageUp?, .delete?, .backspace?: step(-1); return
        case .home?: show(0); return
        case .end?: show(document.pageCount - 1); return
        case .carriageReturn?, .enter?, .newline?:
            if let n = Int(count) { show(n - 1) } else { step(1) }
            count = ""; return
        default: break
        }
        if event.keyCode == 53 { if !count.isEmpty || !pending.isEmpty { count = ""; pending = "" } else { end() }; return }
        guard let key = event.characters, key.count == 1 else { return }
        type(key)
    }

    /// Typed keys (also used by `nox --keys` while presenting).
    func type(_ key: String) {
        if pending.isEmpty, let c = key.first, c.isNumber { count += key; return }
        let sequence = pending + key
        if pending.isEmpty, sequence == "g" || sequence == "," { pending = sequence; return }
        pending = ""
        let n = Int(count); count = ""
        switch sequence {
        case " ", "j", "l", "n": step(n ?? 1)
        case "k", "h", "N": step(-(n ?? 1))
        case "G": show((n ?? document.pageCount) - 1)
        case "gg": show((n ?? 1) - 1)
        case "\r": if let n { show(n - 1) } else { step(1) }
        case "b", ".", "B": blackout.isHidden.toggle()
        case "r": started = Date(); paused = nil; tick()
        case "t":
            if let p = paused { started = started.addingTimeInterval(Date().timeIntervalSince(p)); paused = nil }
            else { paused = Date() }
            tick()
        case ",c": Theme.recolor.toggle(); (NSApp.delegate as? AppDelegate)?.themeChanged(); redraw()
        case "q", "p": end()
        default: break
        }
    }

    private func step(_ delta: Int) {
        if !blackout.isHidden { blackout.isHidden = true; return }   // first key after blanking just unblanks
        show(index + delta)
    }

    var state: [String: Any] {
        ["presenting": true, "slide": index + 1, "presenter": presenterWindow != nil, "blank": !blackout.isHidden,
         "timer": timerLabel.stringValue, "recolor": Theme.recolor]
    }

    /// Test hook: pictures of the slide and presenter windows.
    func snapshot(to path: String) {
        for (window, suffix) in [(slideWindow as NSWindow, "-slides"), (presenterWindow as NSWindow?, "-presenter")] {
            guard let window, let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                                  [.boundsIgnoreFraming, .nominalResolution]) else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: suffix + ".png")))
        }
    }

    func end() {
        timer?.invalidate()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        slideWindow.orderOut(nil)
        presenterWindow?.orderOut(nil)
        NSApp.presentationOptions = []
        if Theme.recolor != savedRecolor { Theme.recolor = savedRecolor; (NSApp.delegate as? AppDelegate)?.themeChanged() }
        onEnd?(index)
        onEnd = nil
    }
}
