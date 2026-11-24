// Draws the Blueprint+ app icon. Logo path data is from the Android ic_launcher_foreground.xml (512 viewport).
// Usage: swift scripts/make-icon.swift icons BlueprintPlus/Assets.xcassets/AppIcon.appiconset docs/images/icon.png
//        (STYLE=<index> picks another style; default 2 = B, the shipped one)   |   ... sheet <out.png> compares styles
import AppKit

struct Style {
    var name: String
    var logo: Double        // logo width (incl. stroke caps) as a fraction of the tile
    var cells: Int          // major grid cells across the tile
    var lineWidth: Double   // major line width at 1024
    var alpha: Double
    var minorDiv = 1        // minor lines per major cell (1 = none)
    var minorWidth = 0.0
    var minorAlpha = 0.0
}

let blue = CGColor(srgbRed: 0x1B / 255.0, green: 0x4F / 255.0, blue: 0x9C / 255.0, alpha: 1)
let yellow = CGColor(srgbRed: 1, green: 0xC8 / 255.0, blue: 0x3D / 255.0, alpha: 1)

func draw(_ s: Style, in ctx: CGContext, size: Double) {
    let k = size / 1024
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)   // top-left origin, like the Android paths
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(shape); ctx.setFillColor(blue); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    func grid(_ n: Int, _ w: Double, _ a: Double, skipEvery: Int) {
        let pitch = tile.width / Double(n)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: a)); ctx.setLineWidth(w * k)
        for i in 1..<n where skipEvery == 0 || i % skipEvery != 0 {
            let o = Double(i) * pitch
            ctx.move(to: CGPoint(x: tile.minX + o, y: tile.minY)); ctx.addLine(to: CGPoint(x: tile.minX + o, y: tile.maxY))
            ctx.move(to: CGPoint(x: tile.minX, y: tile.minY + o)); ctx.addLine(to: CGPoint(x: tile.maxX, y: tile.minY + o))
        }
        ctx.strokePath()
    }
    if s.minorDiv > 1 { grid(s.cells * s.minorDiv, s.minorWidth, s.minorAlpha, skipEvery: s.minorDiv) }
    grid(s.cells, s.lineWidth, s.alpha, skipEvery: 0)
    ctx.restoreGState()

    // Logo: 330 units wide (96...416 plus 10-unit round caps), centred on 256,256.
    let f = s.logo * tile.width / 330
    ctx.translateBy(x: 512 * k - 256 * f, y: 512 * k - 256 * f); ctx.scaleBy(x: f, y: f)
    ctx.setLineCap(.round)
    func lines(_ segs: [(Double, Double, Double, Double)], _ color: CGColor, _ w: Double) {
        ctx.setStrokeColor(color); ctx.setLineWidth(w)
        for (x1, y1, x2, y2) in segs { ctx.move(to: CGPoint(x: x1, y: y1)); ctx.addLine(to: CGPoint(x: x2, y: y2)) }
        ctx.strokePath()
    }
    lines([(96, 256, 416, 256), (256, 96, 256, 416), (96, 216, 96, 296), (416, 216, 416, 296),
           (216, 96, 296, 96), (216, 416, 296, 416)], CGColor(gray: 1, alpha: 1), 20)
    lines([136, 176, 216, 296, 336, 376].map { x in (x, 256, x, 256 - (x == 176 || x == 336 ? 14 : 22)) }, yellow, 8)
    ctx.setFillColor(yellow); ctx.fillEllipse(in: CGRect(x: 230, y: 230, width: 52, height: 52))
    ctx.restoreGState()
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ ctx: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let styles = [
    Style(name: "Current", logo: 0.47, cells: 16, lineWidth: 2, alpha: 0.13),
    Style(name: "A: subtle", logo: 0.58, cells: 10, lineWidth: 3, alpha: 0.20),
    Style(name: "B: blueprint", logo: 0.62, cells: 6, lineWidth: 4, alpha: 0.28, minorDiv: 4, minorWidth: 2, minorAlpha: 0.12),
    Style(name: "C: bold", logo: 0.68, cells: 5, lineWidth: 5, alpha: 0.30),
]

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "sheet":
    let big = 400, sizes = [128, 64, 32], pad = 30, rowH = big + 2 * pad, labelW = 170
    let W = labelW + big + sizes.reduce(0) { $0 + $1 + pad } + pad, H = rowH * styles.count
    let ctx = bitmap(W, H)
    ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (row, s) in styles.enumerated() {
        let y = H - (row + 1) * rowH
        (s.name as NSString).draw(at: CGPoint(x: pad, y: y + rowH / 2),
                                  withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
        ctx.saveGState(); ctx.translateBy(x: CGFloat(labelW), y: CGFloat(y + pad))
        draw(s, in: ctx, size: Double(big)); ctx.restoreGState()
        var x = labelW + big + pad
        for sz in sizes {   // render at true pixel size, then paste 1:1
            let c = bitmap(sz, sz); draw(s, in: c, size: Double(sz))
            ctx.draw(c.makeImage()!, in: CGRect(x: x, y: y + rowH / 2 - sz / 2, width: sz, height: sz))
            x += sz + pad
        }
    }
    save(ctx, args[2])
case "icons":
    let s = styles[Int(ProcessInfo.processInfo.environment["STYLE"] ?? "2")!]
    for sz in [16, 32, 64, 128, 256, 512, 1024] {
        let c = bitmap(sz, sz); draw(s, in: c, size: Double(sz)); save(c, "\(args[2])/icon_\(sz).png")
    }
    let c = bitmap(1024, 1024); draw(s, in: c, size: 1024); save(c, args[3])
default:
    print("usage: make-icon.swift sheet <out.png> | icons <appiconset dir> <docs icon.png>")
}
