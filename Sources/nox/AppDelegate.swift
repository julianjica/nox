import AppKit
import PDFKit

/// Owns the document windows and receives requests from the `nox` command.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let commandNotification = Notification.Name("com.jujimenez.nox.command")
    private var controllers: [DocumentController] = []
    private let launchArguments: [String]

    init(arguments: [String]) {
        launchArguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Self.commandNotification, object: nil)
        if !launchArguments.isEmpty { handle(arguments: launchArguments) }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if self.controllers.isEmpty { self.openPanel() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    @objc private func received(_ notification: Notification) {
        guard let arguments = notification.userInfo?["args"] as? [String] else { return }
        handle(arguments: arguments)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Arguments: [--page N] [--forward LINE TEXFILE] [--search TEXT] [--keys KEYS] [--state OUT] file.pdf
    func handle(arguments: [String]) {
        var page: Int?, forward: (Int, String)?, keys: String?, query: String?, stateFile: String?, file: String?
        var note: String?, pdfNote: String?, typeText: String?, closeNote: String?, clickNote: (Int, Bool)?, menu: String?, snapshot: String?, pick: Int?
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--page" where i + 1 < arguments.count:
                page = Int(arguments[i + 1]); i += 1
            case "--forward" where i + 2 < arguments.count:
                forward = (Int(arguments[i + 1]) ?? 1, arguments[i + 2]); i += 2
            case "--keys" where i + 1 < arguments.count:
                keys = arguments[i + 1]; i += 1
            case "--search" where i + 1 < arguments.count:
                query = arguments[i + 1]; i += 1
            case "--click-note" where i + 1 < arguments.count:
                clickNote = (Int(arguments[i + 1]) ?? 1, false); i += 1
            case "--right-click-note" where i + 1 < arguments.count:
                clickNote = (Int(arguments[i + 1]) ?? 1, true); i += 1
            case "--pick" where i + 1 < arguments.count:
                pick = Int(arguments[i + 1]); i += 1
            case "--snapshot" where i + 1 < arguments.count:
                snapshot = arguments[i + 1]; i += 1
            case "--menu" where i + 1 < arguments.count:
                menu = arguments[i + 1]; i += 1
            case "--note" where i + 1 < arguments.count:
                note = arguments[i + 1]; i += 1
            case "--pdf-note" where i + 1 < arguments.count:
                pdfNote = arguments[i + 1]; i += 1
            case "--type" where i + 1 < arguments.count:
                typeText = arguments[i + 1]; i += 1
            case "--close-note" where i + 1 < arguments.count:
                closeNote = arguments[i + 1]; i += 1
            case "--state" where i + 1 < arguments.count:
                stateFile = arguments[i + 1]; i += 1
            default:
                file = arg
            }
            i += 1
        }
        let wasOpen = Set(controllers.map { ObjectIdentifier($0) })
        let controller = file.flatMap { open(URL(fileURLWithPath: $0)) } ?? frontController
        guard let controller else { return }
        // A window that just opened needs its layout before it can scroll anywhere.
        let delay = wasOpen.contains(ObjectIdentifier(controller)) ? 0 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let page { controller.goToPage(page) }
            if let forward { controller.forwardSearch(line: forward.0, tex: forward.1) }
            if let query { controller.search(query) }
            if let keys { controller.type(keys) }
            if let note { controller.annotate(note: note) }
            if let pdfNote { controller.editDocumentNote(note: pdfNote) }
            if let typeText { controller.typeInNote(typeText) }
            if let closeNote { controller.closeNote(discarding: closeNote == "discard") }
            if let clickNote { controller.clickNote(clickNote.0, right: clickNote.1) }
            if let menu { controller.menuAction(menu) }
            if let pick { controller.pickRow(pick) }
            if let snapshot { controller.snapshot(to: snapshot) }
            if let stateFile {
                let data = try? JSONSerialization.data(withJSONObject: controller.state(), options: [.prettyPrinted])
                try? data?.write(to: URL(fileURLWithPath: stateFile))
            }
        }
    }

    private var frontController: DocumentController? {
        // The key window, else the frontmost visible one (the selected tab of the front window).
        controllers.first { $0.window.isKeyWindow }
            ?? NSApp.orderedWindows.lazy.compactMap { w in self.controllers.first { $0.window === w } }.first
            ?? controllers.last
    }

    @discardableResult
    func open(_ url: URL) -> DocumentController? {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = controllers.first(where: { $0.url == url }) {
            existing.window.makeKeyAndOrderFront(nil)
            return existing
        }
        let host = frontController?.window
        guard let controller = DocumentController(url: url) else {
            let alert = NSAlert()
            alert.messageText = "Could not open \(url.lastPathComponent)"
            alert.runModal()
            return nil
        }
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        // New PDFs join the front window as a tab.
        if let host, host !== controller.window, host.isVisible {
            host.addTabbedWindow(controller.window, ordered: .above)
            controller.window.makeKeyAndOrderFront(nil)
        }
        controllers.append(controller)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return controller
    }

    /// Opens (or focuses) a PDF at a page and height, e.g. for a global mark.
    func open(_ url: URL, page: Int, y: CGFloat) {
        let wasOpen = controllers.contains { $0.url == url.standardizedFileURL.resolvingSymlinksInPath() }
        guard let controller = open(url) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasOpen ? 0 : 0.3)) {
            controller.rememberSpot()
            controller.go(toPage: page, y: y)
        }
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            panel.urls.forEach { open($0) }
        } else if controllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    @objc func showKeys() { frontController?.showHelp() }
    @objc func printFront() { frontController?.printPDF() }
    @objc func selectTab(_ sender: NSMenuItem) { frontController?.selectTab(sender.tag) }

    func themeChanged() {
        controllers.forEach { $0.applyTheme() }
    }

    // MARK: - Menu (gives Cmd+C, Cmd+A, Cmd+W, Cmd+Q their usual meaning)

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide nox", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit nox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openPanel), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(printFront), keyEquivalent: "p").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showKeys), keyEquivalent: "/").target = self
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control]
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control, .shift]
        for n in 1...9 {
            let item = windowMenu.addItem(withTitle: n == 9 ? "Show Last Tab" : "Show Tab \(n)", action: #selector(selectTab(_:)),
                                          keyEquivalent: "\(n)")
            item.target = self
            item.tag = n
        }
        windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        main.addItem(helpItem)
        NSApp.mainMenu = main
    }
}
