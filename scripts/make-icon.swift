// Draws the nox app icon (1024×1024 PNG): a dark page with a highlighted line under a crescent moon.
// usage: swift make-icon.swift out.png
import AppKit

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Squircle background (macOS grid: 824 px tile, 100 px margin), night-sky gradient.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: hex(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(hex(0x0B0B0B)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let sky = CGGradient(colorsSpace: space, colors: [hex(0x2A2F45), hex(0x141414), hex(0x0B0B0B)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// a few stars
for (x, y, r) in [(230.0, 800.0, 5.0), (300, 870, 3), (820, 300, 4), (190, 420, 3.5), (850, 520, 3)] {
    ctx.setFillColor(hex(0xE6E4DF, 0.75)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
ctx.restoreGState()
// thin rim
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(hex(0x8C9EFF, 0.35)); ctx.setLineWidth(3); ctx.strokePath()

// The page, with a folded corner.
let page = CGRect(x: 290, y: 190, width: 420, height: 560)
let fold: CGFloat = 96
let pagePath = CGMutablePath()
pagePath.move(to: CGPoint(x: page.minX + 28, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX - 28, y: page.minY))
pagePath.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + 28), control: CGPoint(x: page.maxX, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
pagePath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
pagePath.addLine(to: CGPoint(x: page.minX + 28, y: page.maxY))
pagePath.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - 28), control: CGPoint(x: page.minX, y: page.maxY))
pagePath.addLine(to: CGPoint(x: page.minX, y: page.minY + 28))
pagePath.addQuadCurve(to: CGPoint(x: page.minX + 28, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0x000000, 0.55))
ctx.addPath(pagePath); ctx.setFillColor(hex(0x1E1F24)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(pagePath); ctx.setStrokeColor(hex(0x8C8C8C, 0.6)); ctx.setLineWidth(4); ctx.strokePath()
// folded corner
let corner = CGMutablePath()
corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 14))
corner.addQuadCurve(to: CGPoint(x: page.maxX - fold + 14, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
corner.closeSubpath()
_ = corner  // the moon sits over the fold

// Lines of text; the third one is highlighted (a translucent band, like a real highlight).
let left = page.minX + 56
let lines: [(CGFloat, CGFloat)] = [(600, 210), (540, 300), (480, 270), (420, 300), (360, 240), (300, 290), (240, 180)]
ctx.setFillColor(hex(0xFFE45C, 0.92))
ctx.addPath(CGPath(roundedRect: CGRect(x: left - 12, y: 480 - 24, width: 270 + 24, height: 48), cornerWidth: 5, cornerHeight: 5, transform: nil))
ctx.fillPath()
for (y, w) in lines {
    ctx.setFillColor(y == 480 ? hex(0x141414, 0.9) : hex(0xE6E4DF, 0.85))
    ctx.addPath(CGPath(roundedRect: CGRect(x: left, y: y - 8, width: w, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()
}

// Crescent moon in the top-right corner, with a soft glow.
let moonCenter = CGPoint(x: 712, y: 730), r: CGFloat = 112
let outer = CGRect(x: moonCenter.x - r, y: moonCenter.y - r, width: 2 * r, height: 2 * r)
let inner = outer.offsetBy(dx: 62, dy: 40)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 50, color: hex(0x8C9EFF, 0.85))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.addEllipse(in: outer); ctx.clip()
let cut = CGMutablePath(); cut.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024)); cut.addEllipse(in: inner)
ctx.addPath(cut); ctx.clip(using: .evenOdd)
let moonGrad = CGGradient(colorsSpace: space, colors: [hex(0xE8ECFF), hex(0x8C9EFF), hex(0x6CD4FF)] as CFArray,
                          locations: [0, 0.6, 1])!
ctx.drawLinearGradient(moonGrad, start: CGPoint(x: outer.minX, y: outer.maxY),
                       end: CGPoint(x: outer.maxX, y: outer.minY), options: [])
ctx.endTransparencyLayer()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
