import AppKit
import PDFKit

/// The text of a two-column page in reading order (left column, then right), for PDFs whose
/// text runs across the columns line by line (scans with OCR text, some journal PDFs).
/// Visual mode then works in reading positions and maps back to the PDF's characters.
/// Pages whose text is already in reading order get no `ReadingOrder` (nil): nothing changes.
struct ReadingOrder {
    struct Line { let rect: CGRect; let start: Int; let end: Int }
    let text: NSString
    let toPDF: [Int]          // reading position → PDF character index
    let fromPDF: [Int]        // PDF character index → reading position
    let lines: [Line]         // in reading positions

    /// Reading positions [start, start+length) as runs of consecutive PDF characters.
    func pdfRanges(_ range: NSRange) -> [NSRange] {
        let lo = max(0, range.location), hi = min(toPDF.count, range.location + range.length)
        guard lo < hi else { return [] }
        var runs: [NSRange] = []
        var start = toPDF[lo], last = toPDF[lo]
        for r in (lo + 1)..<max(lo + 1, hi) {
            let i = toPDF[r]
            if i == last || i == last + 1 { last = i; continue }
            runs.append(NSRange(location: start, length: last - start + 1))
            start = i; last = i
        }
        runs.append(NSRange(location: start, length: last - start + 1))
        return runs
    }

    /// `force` (the `,2` switch set to "on"): take any two columns found, even where the text
    /// doesn't seem to need it.
    static func make(page: PDFPage, force: Bool = false) -> ReadingOrder? {
        let s = (page.string ?? "") as NSString
        guard s.length > 0 else { return nil }
        let rects = (0..<s.length).map { page.selection(for: NSRange(location: $0, length: 1))?.bounds(for: page) ?? .null }
        return make(text: s, rects: rects, force: force)
    }

    /// The layout analysis itself, from each character's rectangle (testable without a PDF).
    static func make(text s: NSString, rects: [CGRect], force: Bool = false) -> ReadingOrder? {
        let n = s.length
        guard n > 0, rects.count == n else { return nil }
        let space = CharacterSet.whitespacesAndNewlines
        func ink(_ i: Int) -> Bool {
            let r = rects[i]
            return !r.isNull && r.width > 0 && r.minX.isFinite && r.minY.isFinite
                && !space.contains(UnicodeScalar(s.character(at: i)) ?? " ")
        }
        let widths = (0..<n).filter(ink).map { rects[$0].width }.sorted()
        guard widths.count > 50 else { return nil }
        let charWidth = widths[widths.count / 2]

        // 1. Segments: runs of consecutive characters on one baseline with no big gap.
        var segments: [ClosedRange<Int>] = []
        var start = 0, lastInk: Int? = nil, newline = false
        for i in 0..<n {
            let c = s.character(at: i)
            if ink(i) {
                if let l = lastInk {
                    let a = rects[l], b = rects[i]
                    let sameRow = abs(a.midY - b.midY) < max(a.height, b.height) * 0.5
                    if newline || !sameRow || b.minX < a.minX - 1 || b.minX - a.maxX > charWidth * 2.5 {
                        segments.append(start...(i - 1)); start = i
                    }
                }
                lastInk = i; newline = false
            } else if c == 10 || c == 13 {
                newline = true
            }
        }
        segments.append(start...(n - 1))
        func bounds(_ seg: ClosedRange<Int>) -> CGRect {
            seg.filter(ink).reduce(CGRect.null) { $0.union(rects[$1]) }
        }

        // 2. Where the right column starts: the most common left edge of lines in the middle of the
        // text. (Not an empty gutter: in OCR'd scans the left column's text can run past it.)
        var boxes = segments.map(bounds)
        let all = boxes.filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
        guard !all.isNull, all.width > 100 else { return nil }
        var starts: [Int: Int] = [:]
        for r in boxes where !r.isNull && r.minX > all.minX + all.width * 0.3 && r.minX < all.minX + all.width * 0.7 {
            starts[Int((r.minX / 3).rounded()), default: 0] += 1
        }
        guard let bin = starts.max(by: { $0.value + (starts[$0.key - 1] ?? 0) + (starts[$0.key + 1] ?? 0)
                                          < $1.value + (starts[$1.key - 1] ?? 0) + (starts[$1.key + 1] ?? 0) })?.key
        else { return nil }
        let column = boxes.filter { !$0.isNull && abs($0.minX - CGFloat(bin) * 3) <= 4 }.map(\.minX).min() ?? CGFloat(bin) * 3

        // Lines merged across the columns (with a gap where the right column starts): split them.
        var split: [ClosedRange<Int>] = []
        for seg in segments {
            let inked = seg.filter(ink)
            var from = seg.lowerBound
            for (p, q) in zip(inked, inked.dropFirst()) {
                let a = rects[p], b = rects[q]
                if abs(b.minX - column) <= 4, b.minX - a.maxX > charWidth * 1.6, abs(a.midY - b.midY) < a.height {
                    split.append(from...(q - 1)); from = q
                }
            }
            split.append(from...seg.upperBound)
        }
        segments = split
        boxes = segments.map(bounds)

        enum Side { case left, right, span }
        // Left-column lines may run a little past the right column's edge; full-width lines run far past it.
        let reach = column + (all.maxX - column) * 0.5
        func side(_ r: CGRect) -> Side { r.minX >= column - 4 ? .right : r.maxX <= reach ? .left : .span }
        // Lone characters (vertical text in the margin, stray marks) go last, out of the lines' way.
        let lone = Set(segments.indices.filter { !boxes[$0].isNull && segments[$0].filter(ink).count == 1 })
        let real = segments.indices.filter { !boxes[$0].isNull && !lone.contains($0) }.map { boxes[$0] }
        let left = real.filter { side($0) == .left }.count, right = real.filter { side($0) == .right }.count
        let span = real.count - left - right
        if force { guard left >= 3, right >= 3, Double(span) < Double(real.count) * 0.5 else { return nil } } else {
        guard left >= 8, right >= 8, Double(span) < Double(real.count) * 0.25 else { return nil }
        // Real columns: many full lines starting at each column's edge, of similar width
        // (not centered equations or table cells in a one-column page).
        func median(_ v: [CGFloat]) -> CGFloat { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        var margins: [Int: Int] = [:]
        for r in real where side(r) == .left { margins[Int((r.minX / 3).rounded()), default: 0] += 1 }
        guard let margin = margins.max(by: { $0.value < $1.value }).map({ CGFloat($0.key) * 3 }) else { return nil }
        let leftLines = real.filter { side($0) == .left && abs($0.minX - margin) <= 4 }
        let rightLines = real.filter { side($0) == .right && $0.minX <= column + 4 }
        let leftWidth = median(leftLines.map(\.width)), rightWidth = median(rightLines.map(\.width))
        guard leftLines.count >= 8, rightLines.count >= 8,
              Double(rightLines.count) >= Double(right) * 0.6,
              leftWidth >= (column - margin) * 0.75,
              min(leftWidth, rightWidth) >= max(leftWidth, rightWidth) * 0.7 else { return nil }
        // Only text that keeps jumping between the columns needs this; a few jumps (running heads,
        // footnotes) are normal in a PDF that is already in reading order.
        let sides = real.map(side).filter { $0 != .span }
        let jumps = zip(sides, sides.dropFirst()).filter { $0 != $1 }.count
        guard jumps >= 8, Double(jumps) > Double(sides.count) * 0.15 else { return nil }
        }

        // 3. Reading order: top to bottom; between full-width lines, the left column then the right.
        let order = segments.indices.filter { !boxes[$0].isNull && !lone.contains($0) }.sorted { boxes[$0].midY > boxes[$1].midY }
        var rows: [[Int]] = []
        for i in order {
            if let r = rows.last?.first, abs(boxes[r].midY - boxes[i].midY) < min(boxes[r].height, boxes[i].height) * 0.5 {
                rows[rows.count - 1].append(i)
            } else { rows.append([i]) }
        }
        var reading: [Int] = []
        var lefts: [Int] = [], rights: [Int] = []
        func flush() { reading += lefts + rights; lefts = []; rights = [] }
        for row in rows {
            for i in row.sorted(by: { boxes[$0].minX < boxes[$1].minX }) {
                switch side(boxes[i]) {
                case .left: lefts.append(i)
                case .right: rights.append(i)
                case .span: flush(); reading.append(i)
                }
            }
        }
        flush()
        reading += lone.sorted()
        // Whitespace-only segments (no rectangle) follow the segment before them in the PDF.
        var placed = Set(reading)
        var withBlanks: [Int] = []
        for i in reading {
            withBlanks.append(i)
            var j = i + 1
            while j < segments.count, boxes[j].isNull, !placed.contains(j) { withBlanks.append(j); placed.insert(j); j += 1 }
        }
        withBlanks += segments.indices.filter { !placed.contains($0) }

        // Already in reading order: leave the page alone.
        if withBlanks == Array(segments.indices) { return nil }

        // 4. The reading text, with a newline after each segment that doesn't end in a space.
        let out = NSMutableString()
        var toPDF: [Int] = [], lines: [Line] = []
        for i in withBlanks {
            let seg = segments[i], begin = toPDF.count
            out.append(s.substring(with: NSRange(location: seg.lowerBound, length: seg.count)))
            toPDF += Array(seg)
            if !space.contains(UnicodeScalar(s.character(at: seg.upperBound)) ?? " ") {
                out.append("\n"); toPDF.append(seg.upperBound)
            }
            guard !boxes[i].isNull, !lone.contains(i) else { continue }   // lone characters aren't lines
            // Pieces of one line in one column, next to each other, make one line.
            if let last = lines.last, last.end == begin - 1, side(last.rect) == side(boxes[i]),
               abs(last.rect.midY - boxes[i].midY) < min(last.rect.height, boxes[i].height) * 0.5 {
                lines[lines.count - 1] = Line(rect: last.rect.union(boxes[i]), start: last.start, end: toPDF.count - 1)
            } else {
                lines.append(Line(rect: boxes[i], start: begin, end: toPDF.count - 1))
            }
        }
        var fromPDF = Array(repeating: 0, count: n)
        for (r, i) in toPDF.enumerated().reversed() { fromPDF[i] = r }
        return ReadingOrder(text: out, toPDF: toPDF, fromPDF: fromPDF, lines: lines)
    }
}
