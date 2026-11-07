import AppKit
import PDFKit

/// Reference preview: what a citation, a "Figure 3" link or an equation link points to,
/// shown as a picture of that part of the page without leaving your place.
///
/// Two sources: the PDF's own internal links (LaTeX hyperref), and, for journal PDFs without
/// links, citations found in the text ("[12]", "(Powell, 2011)", "Kahneman and Tversky (1979)"),
/// looked up in the reference list.
enum References {
    /// Something on a page that can be previewed.
    struct Item {
        let rect: NSRect            // on its page
        let target: Target
    }

    enum Target {
        case destination(PDFDestination)              // an internal link
        case numbered(Int)                            // [12]
        case authorYear(name: String, year: String)  // Powell, 2011
    }

    /// Where a target is: a page and a region of it.
    struct Place {
        let page: PDFPage
        let region: NSRect
        var top: NSPoint { NSPoint(x: region.minX, y: region.maxY) }
    }

    // MARK: Finding citations on a page

    private static let numbered = try! NSRegularExpression(pattern: "\\[(\\d{1,3})((?:\\s*[,–-]\\s*\\d{1,3})*)\\]")
    private static let name = "[A-Z][\\p{L}'’\\-]+"
    private static let authorYear = try! NSRegularExpression(pattern:
        "(\(name))(?:\\s+et\\s+al\\.?|\\s+(?:and|&)\\s+\(name)|(?:,\\s+\(name))*,?\\s+(?:and|&)\\s+\(name))?,?\\s*\\(?((?:19|20)\\d{2})[a-z]?\\b")

    /// Words that look like names at the start of a citation match but aren't.
    private static let notNames: Set<String> = ["In", "See", "The", "And", "Also", "Since", "From", "Figure", "Table",
                                                "Section", "Fig", "Eq", "Equation", "Chapter", "Appendix", "Vol", "No"]

    static func items(on page: PDFPage) -> [Item] {
        var result: [Item] = []
        for annotation in page.annotations where annotation.type == "Link" {
            if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
               destination.page != nil {
                result.append(Item(rect: annotation.bounds, target: .destination(destination)))
            }
        }
        let linked = result.map(\.rect)
        let text = page.string ?? ""
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        func add(_ range: NSRange, _ target: Target) {
            guard let rect = page.selection(for: range)?.bounds(for: page), rect.width > 0, rect.minX.isFinite,
                  !linked.contains(where: { $0.intersects(rect) }) else { return }
            result.append(Item(rect: rect, target: target))
        }
        for m in numbered.matches(in: text, range: all) {
            if let n = Int(ns.substring(with: m.range(at: 1))) { add(m.range, .numbered(n)) }
        }
        for m in authorYear.matches(in: text, range: all) {
            let who = ns.substring(with: m.range(at: 1))
            guard !notNames.contains(who) else { continue }
            add(m.range, .authorYear(name: who, year: ns.substring(with: m.range(at: 2))))
        }
        return result
    }

    // MARK: Finding what they point to

    /// `citation` is the citing text's rectangle on `page`, so the citation itself never counts as its entry.
    static func place(of target: Target, in document: PDFDocument, citedFrom page: PDFPage, at citation: NSRect = .null) -> Place? {
        let citing = (page: page, rect: citation)
        switch target {
        case .destination(let destination):
            guard let page = destination.page else { return nil }
            let box = page.bounds(for: .cropBox)
            var top = destination.point.y
            if !top.isFinite || top > box.maxY || top <= box.minY { top = box.maxY }
            if let entry = referenceEntry(on: page, below: top, in: document) { return entry }
            let height = min(240, top - box.minY)
            return Place(page: page, region: NSRect(x: box.minX, y: top - height, width: box.width, height: height + 6))
        case .numbered(let n):
            return entry(in: document, citing: citing) { text, i in
                // "[12]" or "12." at the start of a line in the reference list
                for label in ["[\(n)]", "\(n). ", "\(n) "] where text.length >= i + label.count {
                    if text.substring(with: NSRange(location: i, length: label.count)) == label { return true }
                }
                return false
            }
        case let .authorYear(name, year):
            func has(_ text: NSString, _ i: Int, _ length: Int, _ s: String) -> Bool {
                text.substring(with: NSRange(location: i, length: min(length, text.length - i))).contains(s)
            }
            // The entry starting with the name; failing that (a second author, or a name hyphenated
            // across lines in the citation), an entry with the name among its first words.
            return entry(in: document, citing: citing) { text, i in
                text.length >= i + name.count && text.substring(with: NSRange(location: i, length: name.count)) == name
                    && has(text, i, 300, year)
            } ?? entry(in: document, citing: citing) { text, i in
                has(text, i, 90, name) && has(text, i, 300, year)
            }
        }
    }

    /// When a link lands on a reference-list entry ("[8] Hsu, …", or a line with a year near the
    /// end of the PDF), just that entry; nil for figures, sections, equations.
    private static func referenceEntry(on page: PDFPage, below top: CGFloat, in document: PDFDocument) -> Place? {
        let box = page.bounds(for: .cropBox)
        guard let strip = page.selection(for: NSRect(x: box.minX, y: top - 24, width: box.width, height: 26)),
              let line = strip.selectionsByLine().first, line.numberOfTextRanges(on: page) > 0 else { return nil }
        let start = line.range(at: 0, on: page).location
        guard start != NSNotFound, let text = page.string as NSString? else { return nil }
        let head = text.substring(with: NSRange(location: start, length: min(200, text.length - start)))
        let labelled = head.range(of: "^\\s*\\[?\\d{1,3}[\\].]", options: .regularExpression) != nil
        let nearEnd = document.index(for: page) >= document.pageCount * 2 / 3
        let dated = head.range(of: "(19|20)\\d{2}", options: .regularExpression) != nil
        guard labelled || (nearEnd && dated) else { return nil }
        return region(of: start, on: page, text: text)
    }

    /// The reference-list entry whose first line satisfies `matches`: searched from the end of
    /// the document backwards (reference lists come last), not before the citing page.
    private static func entry(in document: PDFDocument, citing: (page: PDFPage, rect: NSRect),
                              matches: (NSString, Int) -> Bool) -> Place? {
        for index in stride(from: document.pageCount - 1, through: max(0, document.index(for: citing.page)), by: -1) {
            guard let page = document.page(at: index), let string = page.string else { continue }
            let text = string as NSString
            var i = text.length - 1
            while i >= 0 {
                let atLineStart = i == 0 || text.character(at: i - 1) == 10 || text.character(at: i - 1) == 13
                if atLineStart, matches(text, i), let place = region(of: i, on: page, text: text),
                   !(page == citing.page && place.region.intersects(citing.rect)) { return place }
                i -= 1
            }
        }
        return nil
    }

    /// A few lines of the column starting at character `i`.
    private static func region(of i: Int, on page: PDFPage, text: NSString) -> Place? {
        let length = min(400, text.length - i)
        guard length > 0, let lines = page.selection(for: NSRange(location: i, length: length))?.selectionsByLine(),
              let first = lines.first?.bounds(for: page), first.minX.isFinite else { return nil }
        // The entry's lines: the same column, going down, until a gap or a line starting back at
        // the entry's left edge (reference lists indent the lines after an entry's first).
        var rect = first
        for line in lines.dropFirst().prefix(6) {
            let r = line.bounds(for: page)
            guard r.minX.isFinite, r.maxY <= rect.minY + 2, rect.minY - r.maxY < first.height * 1.2,
                  r.minX > first.minX - first.height, r.minX < first.minX + first.height * 3 else { break }
            if abs(r.minX - first.minX) < 1.5 && lines.count > 1 && rect.height > first.height * 1.5 { break }
            if abs(r.minX - first.minX) < 1.5, hangingIndent(lines, first: first, page: page) { break }
            rect = rect.union(r)
        }
        let box = page.bounds(for: .cropBox)
        let region = NSRect(x: max(box.minX, rect.minX - 4), y: max(box.minY, rect.minY - 3),
                            width: min(max(rect.width, 120) + 8, box.maxX - rect.minX + 4), height: rect.height + 5)
        return Place(page: page, region: region)
    }

    /// Whether the list indents the lines after an entry's first (then a line back at the left starts a new entry).
    private static func hangingIndent(_ lines: [PDFSelection], first: NSRect, page: PDFPage) -> Bool {
        lines.dropFirst().prefix(6).contains { $0.bounds(for: page).minX > first.minX + 3 }
    }

    // MARK: Picture

    /// The region drawn as an image, `scale` times its size in points (dark mode included).
    static func image(of place: Place, scale: CGFloat) -> NSImage {
        let r = place.region
        let size = NSSize(width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
        return NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor((Theme.recolor ? Theme.background : .white).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            let box = place.page.bounds(for: .cropBox)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: box.minX - r.minX, y: box.minY - r.minY)
            place.page.draw(with: .cropBox, to: context)
            return true
        }
    }
}
