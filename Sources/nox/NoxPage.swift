import PDFKit

/// A page that can draw itself in dark mode: white paper becomes the
/// background color and black ink the foreground color. Highlights are drawn on
/// top as translucent bands so they keep their own colors.
final class NoxPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard Theme.recolor, rotation == 0, let ref = pageRef else {
            super.draw(with: box, to: context)
            return
        }
        let rect = bounds(for: box)
        let white = CGColor(gray: 1, alpha: 1)

        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(white)
        context.fill(rect)
        context.drawPDFPage(ref)  // page content only; annotations are drawn below

        // invert, then map black -> background and white -> foreground
        context.setBlendMode(.difference)
        context.setFillColor(white)
        context.fill(rect)
        context.setBlendMode(.multiply)
        context.setFillColor(Theme.foreground.cgColor)
        context.fill(rect)
        context.setBlendMode(.screen)
        context.setFillColor(Theme.background.cgColor)
        context.fill(rect)
        context.setBlendMode(.normal)

        // Annotations are drawn by PDFView on top (and highlights by the overlay), not here.
        context.restoreGState()
    }

    /// The highlighted rectangles (one per line) in page coordinates.
    static func highlightRects(_ annotation: PDFAnnotation) -> [CGRect] {
        let origin = annotation.bounds.origin
        guard let quads = annotation.quadrilateralPoints?.map({ $0.pointValue }), quads.count >= 4 else {
            return [annotation.bounds]
        }
        return stride(from: 0, to: quads.count - 3, by: 4).map { i in
            let xs = quads[i..<i + 4].map(\.x), ys = quads[i..<i + 4].map(\.y)
            return CGRect(x: origin.x + xs.min()!, y: origin.y + ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }
}
