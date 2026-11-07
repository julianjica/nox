import PDFKit

/// Turns the highlights and notes stored in a PDF into Markdown, and keeps them in the
/// PDF's `<name>.notes.md` (the file `,q` / `,n` use) inside a marked block that each
/// export replaces, so anything you wrote around it stays.
enum NotesExport {
    static let startMarker = "<!-- nox: highlights and notes from the PDF (replaced on each export with ,e) -->"
    static let endMarker = "<!-- nox: end -->"

    /// The text under a highlight.
    static func quote(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        NoxPage.highlightRects(annotation)
            .compactMap { page.selection(for: $0.insetBy(dx: 0, dy: $0.height * 0.2))?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Every highlight and sticky note, in reading order.
    static func entries(in document: PDFDocument) -> [NoteEntry] {
        var result: [NoteEntry] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let found = page.annotations.filter { $0.type == "Highlight" || $0.type == "Text" }
                .sorted { $0.bounds.maxY > $1.bounds.maxY }
            for annotation in found {
                let text = annotation.type == "Highlight" ? quote(of: annotation, on: page) : ""
                result.append(NoteEntry(annotation: annotation, page: page, pageIndex: index, quote: text))
            }
        }
        return result
    }

    static func notesURL(for pdf: URL) -> URL {
        pdf.deletingPathExtension().appendingPathExtension("notes.md")
    }

    /// The Markdown block for a document.
    static func markdown(_ document: PDFDocument, pdf: URL) -> (text: String, count: Int) {
        let stem = pdf.deletingPathExtension().lastPathComponent
        let items = entries(in: document)
        var lines = [startMarker, "## From the PDF", ""]
        if items.isEmpty { lines += ["_No highlights or notes yet._", ""] }
        for entry in items {
            let page = entry.pageIndex + 1
            let link = "[\(stem), p. \(page)](<sioyek://\(pdf.path)#\(page)>)"
            if entry.isSticky {
                lines.append("**Note** — \(link)")
            } else {
                lines.append("> \(entry.quote.isEmpty ? "…" : entry.quote)")
                lines.append("> — \(link)")
            }
            if !entry.note.isEmpty { lines += [""] + entry.note.components(separatedBy: "\n") }
            lines.append("")
        }
        lines.append(endMarker)
        return (lines.joined(separator: "\n") + "\n", items.count)
    }

    /// Writes (or replaces) the block in `<name>.notes.md`. Returns the number of entries.
    @discardableResult
    static func write(_ document: PDFDocument, pdf: URL) throws -> Int {
        let (block, count) = markdown(document, pdf: pdf)
        let url = notesURL(for: pdf)
        var text = (try? String(contentsOf: url, encoding: .utf8))
            ?? "# Notes: \(pdf.deletingPathExtension().lastPathComponent)\n\nSource: [\(pdf.lastPathComponent)](<sioyek://\(pdf.path)#1>)\n"
        if let start = text.range(of: startMarker), let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) {
            var upper = end.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            text.replaceSubrange(start.lowerBound..<upper, with: block)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + block
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return count
    }
}
