import AppKit
import CoreText
import PDFKit

/// `nox --self-test`: checks of the parts that don't need a window (Markdown, the key list,
/// labels, notes stored in the PDF, the reference finder). Needs no test framework, so it runs
/// the same with only the Command Line Tools and on CI. Exits 1 if anything fails.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL  \(what)  (\(file):\(line))")
        }
    }

    static func run() -> Int32 {
        markdown()
        keymap()
        labels()
        notes()
        references()
        readingOrder()
        print(failures == 0 ? "ok: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Markdown

    private static func traits(_ text: NSAttributedString, of word: String) -> NSFontTraitMask {
        let range = (text.string as NSString).range(of: word)
        guard range.location != NSNotFound, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { return [] }
        return NSFontManager.shared.traits(of: font)
    }

    private static func markdown() {
        check(Markdown.plain("**bold** and *it*") == "bold and it", "markdown: markers removed")
        check(Markdown.plain("- one\n- two") == "• one\n• two", "markdown: list bullets")
        check(Markdown.plain("snake_case 2*3*4") == "snake_case 2*3*4", "markdown: no false italics")
        let rendered = Markdown.render("# Title\nSome **bold**, *italic* and `code`.")
        check(traits(rendered, of: "bold").contains(.boldFontMask), "markdown: bold is bold")
        check(!traits(rendered, of: "bold").contains(.italicFontMask), "markdown: bold is not italic")
        check(traits(rendered, of: "italic").contains(.italicFontMask), "markdown: italic is italic")
        check(traits(rendered, of: "Title").contains(.boldFontMask), "markdown: heading is bold")
        for partial in ["**bold*", "**bold **"] {
            let storage = NSTextStorage(string: partial)
            Markdown.style(storage)
            check(!traits(storage, of: "bold").contains(.italicFontMask), "markdown: \"\(partial)\" while typing is not italic")
            check(storage.string == partial, "markdown: styling never changes the text")
        }
    }

    // MARK: Keys

    private static func keymap() {
        var seen = Set<String>()
        for section in Keymap.sections {
            check(!section.keys.isEmpty, "keymap: section \(section.title) has keys")
            for (keys, text) in section.keys {
                check(!text.isEmpty, "keymap: \(keys) has a description")
                check(!seen.contains(section.title + keys), "keymap: \(keys) listed once in \(section.title)")
                seen.insert(section.title + keys)
            }
        }
        check(Keymap.plainText.contains("c{a-e}"), "keymap: highlight keys listed")
        for prefix in Keymap.continuations.keys { check(prefix.count == 1, "keymap: prefix \(prefix) is one key") }
    }

    private static func labels() {
        for n in [1, 5, 26, 27, 100, 400] {
            let labels = DocumentController.hintLabels(n)
            check(labels.count == n, "labels: \(n) labels")
            check(Set(labels).count == n, "labels: \(n) labels are distinct")
            let prefixFree = !labels.contains { a in labels.contains { b in a != b && b.hasPrefix(a) } }
            check(prefixFree, "labels: no label of \(n) starts another")
        }
    }

    // MARK: A PDF made here

    /// A PDF whose pages hold the given lines of text (real text, so PDFKit can read it).
    static func makePDF(pages: [[String]]) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let font = CTFontCreateWithName("Times-Roman" as CFString, 12, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 720
            for text in lines {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(line, context)
                y -= 16
            }
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    // MARK: Notes stored in the PDF

    private static func notes() {
        guard let doc = makePDF(pages: [["A first page with some text."], ["A second page."]]),
              let first = doc.page(at: 0), let second = doc.page(at: 1) else { check(false, "notes: test PDF"); return }
        let whole = PDFAnnotation(bounds: NSRect(x: 6, y: 760, width: 20, height: 20), forType: .text, withProperties: nil)
        whole.contents = "About the **whole** paper"
        NotesExport.markAsDocumentNote(whole)
        first.addAnnotation(whole)
        let sticky = PDFAnnotation(bounds: NSRect(x: 100, y: 400, width: 20, height: 20), forType: .text, withProperties: nil)
        sticky.contents = "a page note"
        second.addAnnotation(sticky)

        // what nox writes must come back the same
        guard let data = doc.dataRepresentation(), let back = PDFDocument(data: data) else { check(false, "notes: save"); return }
        check(NotesExport.documentNote(in: back) != nil, "notes: the whole-PDF note survives saving")
        let entries = NotesExport.entries(in: back)
        check(entries.count == 2, "notes: two entries")
        check(entries.first?.isDocumentNote == true, "notes: the whole-PDF note comes first")
        let markdown = NotesExport.markdown(back, pdf: URL(fileURLWithPath: "/tmp/test.pdf")).text
        check(markdown.contains("**About this PDF**"), "export: whole-PDF note heading")
        let about = markdown.range(of: "About this PDF"), page = markdown.range(of: "a page note")
        check(about != nil && page != nil && about!.lowerBound < page!.lowerBound, "export: whole-PDF note first")
    }

    // MARK: Reference finder

    /// Two columns whose text alternates left line, right line (as in some scanned PDFs).
    private static func readingOrder() {
        func page(interleaved: Bool, merged: Bool = false) -> (NSString, [CGRect]) {
            var text = "", rects: [CGRect] = []
            func add(_ line: String, x: CGFloat, y: CGFloat, newline: Bool = true) {
                for (k, c) in line.enumerated() { text.append(c); rects.append(CGRect(x: x + CGFloat(k) * 5, y: y, width: 5, height: 10)) }
                if newline { text.append("\n"); rects.append(CGRect(x: x + CGFloat(line.count) * 5, y: y, width: 5, height: 10)) }
            }
            let left = (0..<12).map { "left line number \(String(format: "%02d", $0)) text" }
            let right = (0..<12).map { "right line number \(String(format: "%02d", $0)) txt" }
            let y = { (i: Int) in CGFloat(700 - i * 14) }
            if interleaved {
                for i in 0..<12 {
                    add(left[i], x: 50, y: y(i), newline: !(merged && i == 5))
                    add(right[i], x: 300, y: y(i))
                }
            } else {
                for i in 0..<12 { add(left[i], x: 50, y: y(i)) }
                for i in 0..<12 { add(right[i], x: 300, y: y(i)) }
            }
            return (text as NSString, rects)
        }
        let (t, r) = page(interleaved: true, merged: true)
        guard let order = ReadingOrder.make(text: t, rects: r) else { check(false, "reading order: interleaved columns found"); return }
        let s = order.text as String
        let lastLeft = s.range(of: "left line number 11")?.lowerBound, firstRight = s.range(of: "right line number 00")?.lowerBound
        check(lastLeft != nil && firstRight != nil && lastLeft! < firstRight!, "reading order: left column before right")
        check(order.lines.count == 24, "reading order: 24 lines (got \(order.lines.count))")
        check(order.lines.allSatisfy { $0.rect.maxX < 280 || $0.rect.minX > 290 }, "reading order: merged line split at the column")
        check(order.toPDF.count == order.text.length && order.toPDF.allSatisfy { $0 < t.length }, "reading order: position map")
        let line3 = order.lines[3]
        let runs = order.pdfRanges(NSRange(location: line3.start, length: line3.end - line3.start + 1))
        check(runs.count == 1 && t.substring(with: runs[0]).hasPrefix("left line number 03"), "reading order: maps back to the PDF")
        let (u, q) = page(interleaved: false)
        check(ReadingOrder.make(text: u, rects: q) == nil, "reading order: ordered columns left alone")
    }

    private static func references() {
        guard let doc = makePDF(pages: [
            ["Behavioral strategy matters (Powell, 2011) and so do numbers [2].",
             "As Kahneman and Lovallo (1993) argued, forecasts are bold."],
            ["References",
             "[1] Adams B. 2001. Something else entirely.",
             "[2] Smith J. 2020. A numbered reference.",
             "Kahneman D, Lovallo D. 1993. Timid choices and bold forecasts.",
             "Powell TC. 2011. Behavioral strategy. Strategic Management Journal."],
        ]), let page = doc.page(at: 0) else { check(false, "references: test PDF"); return }
        let items = References.items(on: page)
        func find(_ match: (References.Target) -> Bool) -> References.Item? { items.first { match($0.target) } }
        func entryText(_ item: References.Item?) -> String {
            guard let item, let place = References.place(of: item.target, in: doc, citedFrom: page, at: item.rect) else { return "" }
            return place.page.selection(for: place.region)?.string ?? ""
        }
        let powell = find { if case .authorYear("Powell", "2011") = $0 { return true }; return false }
        check(powell != nil, "references: finds (Powell, 2011)")
        check(entryText(powell).contains("Powell TC. 2011"), "references: (Powell, 2011) → its entry")
        let numbered = find { if case .numbered(2) = $0 { return true }; return false }
        check(numbered != nil, "references: finds [2]")
        check(entryText(numbered).contains("Smith J."), "references: [2] → its entry")
        check(!entryText(numbered).contains("Adams"), "references: [2] → not the entry above")
        let lovallo = find { if case .authorYear(let name, "1993") = $0 { return name == "Kahneman" || name == "Lovallo" }; return false }
        check(entryText(lovallo).contains("Kahneman D, Lovallo D"), "references: Kahneman and Lovallo (1993) → its entry")
    }
}
