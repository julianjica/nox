import AppKit
import PDFKit

/// One highlight or sticky note stored in the PDF.
struct NoteEntry {
    let annotation: PDFAnnotation
    let page: PDFPage
    let pageIndex: Int
    var note: String { annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    let quote: String
    var isSticky: Bool { annotation.type == "Text" }
    var isDocumentNote: Bool { NotesExport.isDocumentNote(annotation) }
}

/// A table that hands its keys to the list first (j/k, Return, e, d, Esc, q).
final class KeyTable: NSTableView {
    var keyHandler: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }
}

/// Sheet listing every highlight and note in the PDF.
final class NotesList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let sheet: NSWindow
    private let table = KeyTable()
    private let empty = NSTextField(labelWithString: "No highlights or notes yet.  Select text and press a (note) or c{a-e} (highlight); A notes the whole PDF.")
    private var entries: [NoteEntry]
    var onJump: ((NoteEntry) -> Void)?
    var onEdit: ((NoteEntry) -> Void)?
    var onDelete: ((NoteEntry) -> Void)?

    init(entries: [NoteEntry]) {
        self.entries = entries
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.backgroundColor = Theme.background

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 58
        table.backgroundColor = Theme.background
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(jumpToSelected)
        table.keyHandler = { [weak self] in self?.handleKey($0) ?? false }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "j/k move   ↩ go to   e edit note   d delete   Esc close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.comment
        hint.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = Theme.comment
        empty.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        sheet.contentView = content
        [scroll, hint, empty].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        refresh()
    }

    func show(on window: NSWindow, selecting index: Int) {
        window.beginSheet(sheet) { _ in }
        sheet.makeFirstResponder(table)
        select(index)
    }

    func update(_ entries: [NoteEntry]) {
        let row = table.selectedRow
        self.entries = entries
        refresh()
        select(min(row, entries.count - 1))
    }

    func close() { sheet.sheetParent?.endSheet(sheet) }

    private func refresh() {
        table.reloadData()
        empty.isHidden = !entries.isEmpty
    }

    private func select(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private var selected: NoteEntry? {
        table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow] : nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }                 // Esc
        if event.keyCode == 36 || event.keyCode == 76 { jumpToSelected(); return true }  // Return
        switch event.charactersIgnoringModifiers {
        case "j": select(table.selectedRow + 1)
        case "k": select(max(0, table.selectedRow - 1))
        case "g": select(0)
        case "G": select(entries.count - 1)
        case "q": close()
        case "e": if let entry = selected { close(); onEdit?(entry) }
        case "d": if let entry = selected { onDelete?(entry) }
        default: return false
        }
        return true
    }

    @objc private func jumpToSelected() {
        guard let entry = selected else { return }
        close()
        onJump?(entry)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let label = NSTextField(wrappingLabelWithString: "")
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true

        let text = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: 11), body = NSFont.systemFont(ofSize: 13)
        func add(_ s: String, _ color: NSColor, _ font: NSFont) {
            text.append(NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font]))
        }
        add(entry.isSticky ? "✎ " : "● ", entry.isSticky ? Theme.accent : entry.annotation.color.withAlphaComponent(1), body)
        add(entry.isDocumentNote ? "whole PDF   " : "p. \(entry.pageIndex + 1)   ", Theme.comment, small)
        if !entry.note.isEmpty { add(Markdown.plain(entry.note).replacingOccurrences(of: "\n", with: " "), Theme.foreground, .boldSystemFont(ofSize: 13)) }
        if !entry.quote.isEmpty {
            if !entry.note.isEmpty { add("\n", Theme.comment, small) }
            add("“\(entry.quote)”", Theme.comment, entry.note.isEmpty ? body : small)
        }
        label.attributedStringValue = text

        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
