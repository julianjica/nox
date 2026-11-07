import AppKit
import PDFKit

/// A transparent view over one page that draws its highlights and note dots live.
/// In dark mode, highlights are tinted bands blended in screen mode (light text
/// stays light); PDFKit's own highlight drawing (meant for white paper) is hidden meanwhile.
final class NoteOverlayView: NSView {
    weak var page: PDFPage?
    weak var pdfView: PDFView?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the page

    override func draw(_ dirtyRect: NSRect) {
        guard let page, let pdfView, let context = NSGraphicsContext.current?.cgContext else { return }
        func local(_ rect: CGRect) -> CGRect { convert(pdfView.convert(rect, from: page), from: pdfView) }
        for annotation in page.annotations where annotation.type == "Highlight" {
            let rects = NoxPage.highlightRects(annotation).map(local)
            if Theme.recolor {
                context.saveGState()
                context.setBlendMode(.screen)
                context.setFillColor(annotation.color.withAlphaComponent(0.42).cgColor)
                rects.forEach { context.fill($0.insetBy(dx: -1, dy: 0)) }
                context.restoreGState()
            }
            let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !note.isEmpty, let top = rects.max(by: { $0.maxY < $1.maxY }) {
                let size = max(5, min(9, top.height * 0.28))
                context.setFillColor((Theme.recolor ? Theme.accent : Theme.hex(0x5C6BC0)).cgColor)
                context.fillEllipse(in: CGRect(x: top.minX - size - 3, y: top.maxY - size, width: size, height: size))
            }
        }
    }
}

/// Supplies and refreshes the overlays of one PDFView.
final class OverlayProvider: NSObject, PDFPageOverlayViewProvider {
    private var views: [ObjectIdentifier: NoteOverlayView] = [:]

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = views[ObjectIdentifier(page)] ?? NoteOverlayView()
        overlay.page = page
        overlay.pdfView = view
        views[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        views[ObjectIdentifier(page)] = nil
    }

    func refresh(_ page: PDFPage? = nil) {
        for (key, view) in views where page == nil || key == ObjectIdentifier(page!) { view.needsDisplay = true }
    }

    func reset() { views = [:] }
}

extension PDFDocument {
    /// Hides PDFKit's own highlight drawing while nox draws them in dark mode.
    func showNativeHighlights(_ show: Bool) {
        for index in 0..<pageCount {
            page(at: index)?.annotations.filter { $0.type == "Highlight" }.forEach { $0.shouldDisplay = show }
        }
    }
}
