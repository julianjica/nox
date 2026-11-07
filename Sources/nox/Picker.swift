import AppKit

/// A keyboard-driven list sheet (used for the table of contents).
final class PickerSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item { let title: String; let detail: String; let indent: Int }
    let sheet: NSWindow
    private let table = KeyTable()
    private let items: [Item]
    private let onPick: (Int) -> Void

    init(heading: String, items: [Item], onPick: @escaping (Int) -> Void) {
        self.items = items
        self.onPick = onPick
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.backgroundColor = Theme.background
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 26
        table.backgroundColor = Theme.background
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)
        table.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: 13)
        title.textColor = Theme.accent
        let hint = NSTextField(labelWithString: "j/k move   ↩ go   g/G top/bottom   Esc close")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.comment
        for v in [title, hint] { v.translatesAutoresizingMaskIntoConstraints = false }
        let content = NSView()
        sheet.contentView = content
        [title, scroll, hint].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    func show(on window: NSWindow, selecting row: Int) {
        window.beginSheet(sheet) { _ in }
        sheet.makeFirstResponder(table)
        select(row)
    }

    func close() { sheet.sheetParent?.endSheet(sheet) }

    private func select(_ row: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(row, items.count - 1))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        if event.keyCode == 36 || event.keyCode == 76 { pickSelected(); return true }
        switch event.charactersIgnoringModifiers {
        case "j": select(table.selectedRow + 1)
        case "k": select(table.selectedRow - 1)
        case "g": select(0)
        case "G": select(items.count - 1)
        case "q", "t": close()
        default: return false
        }
        return true
    }

    /// Test hook: pick a row as if Return was pressed on it.
    func pick(row: Int) { select(row); pickSelected() }

    @objc private func pickSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        close()
        onPick(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let text = NSMutableAttributedString(string: item.title, attributes: [
            .foregroundColor: item.indent == 0 ? Theme.foreground : Theme.foreground.withAlphaComponent(0.85),
            .font: item.indent == 0 ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)])
        text.append(NSAttributedString(string: "   " + item.detail, attributes: [
            .foregroundColor: Theme.comment, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6 + CGFloat(item.indent) * 18),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
