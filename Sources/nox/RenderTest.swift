import AppKit
import PDFKit

/// `nox --render-test in.pdf PAGE out.png [plain]`: draws one page through PDFKit
/// (as the viewer does) into a PNG, to check the recolored output without the GUI.
final class RenderTestDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { NoxPage.self }
}

func renderTest(_ args: [String]) -> Int32 {
    guard args.count >= 3, let page = Int(args[1]) else { return 2 }
    let delegate = RenderTestDelegate()
    guard let doc = PDFDocument(url: URL(fileURLWithPath: args[0])) else { return 1 }
    doc.delegate = delegate
    Theme.recolor = args.count < 4
    guard let pdfPage = doc.page(at: page - 1) else { return 1 }
    let box = pdfPage.bounds(for: .cropBox)
    let scale: CGFloat = 1.5
    guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    pdfPage.draw(with: .cropBox, to: context)
    guard let cgImage = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return 1 }
    try? png.write(to: URL(fileURLWithPath: args[2]))
    print("page class: \(type(of: pdfPage)), size: \(cgImage.width)x\(cgImage.height)")
    return 0
}
