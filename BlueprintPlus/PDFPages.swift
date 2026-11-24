import Foundation
import PDFKit
import Vision

private let MAX_SIDE_PX = 4096.0 // caps bitmap memory (~64 MB) for big sheets

/** A page rendered to white-backed RGBA pixels, top row first. Immutable after rendering. */
final class PageBitmap: @unchecked Sendable {
    let width: Int
    let height: Int
    /** Pixels per paper inch: PDF units are points (1/72"), so render scale s gives 72*s. */
    let ppi: Double
    let image: CGImage
    private let data: Data
    private let bytesPerRow: Int

    fileprivate init?(width: Int, height: Int, ppi: Double, draw: (CGContext) -> Void) {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        draw(ctx)
        guard let img = ctx.makeImage(), let raw = ctx.data else { return nil }
        self.width = width; self.height = height; self.ppi = ppi; image = img
        bytesPerRow = ctx.bytesPerRow
        data = Data(bytes: raw, count: bytesPerRow * height)
    }

    /** Plan ink vs paper, for wall finding. Off-page counts as paper. */
    func isDark(_ x: Int, _ y: Int) -> Bool {
        if x < 0 || x >= width || y < 0 || y >= height { return false }
        let i = y * bytesPerRow + x * 4
        return data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
            return (r * 3 + g * 6 + b) / 10 < 160
        }
    }
}

/**
 * The job's plan. PDFKit's document isn't thread-safe, so every render and text read goes through this actor
 * (the Android app's `pdfThread`).
 */
actor PlanPDF {
    private let doc: PDFDocument
    let pageCount: Int

    init?(url: URL) {
        guard let d = PDFDocument(url: url), !d.isLocked else { return nil }
        doc = d
        pageCount = d.pageCount
    }

    /** Page size in points, as displayed (crop box, rotated). */
    private func size(_ p: PDFPage) -> CGSize {
        let b = p.bounds(for: .cropBox)
        return p.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /** Draws page `p` so its displayed top-left lands at (tx, ty) points, at `s` pixels per point, in a `h`-px-tall context. */
    private func draw(_ p: PDFPage, _ ctx: CGContext, s: Double, tx: Double = 0, ty: Double = 0, heightPx: Int) {
        let pageH = size(p).height
        ctx.scaleBy(x: s, y: s)
        // CG is bottom-left: the tile's top edge (ty from the page's top) sits at the context's top.
        ctx.translateBy(x: -tx, y: Double(heightPx) / s - (pageH - ty))
        p.draw(with: .cropBox, to: ctx) // applies the page's rotation and box origin
    }

    /** Renders `page` with its long side at most 4096 px (and 4x at most). */
    func render(_ page: Int) -> PageBitmap? {
        guard let p = doc.page(at: page) else { return nil }
        let sz = size(p)
        let s = min(4, MAX_SIDE_PX / max(sz.width, sz.height))
        let w = Int(sz.width * s), h = Int(sz.height * s)
        return PageBitmap(width: w, height: h, ppi: 72 * s) { ctx in draw(p, ctx, s: s, heightPx: h) }
    }

    /** Page size in points (top-left origin, as displayed). */
    func pageSize(_ page: Int) -> CGSize { doc.page(at: page).map(size) ?? .zero }

    /** Room labels on `page` from its text; empty for scans and pages with no text. */
    func roomLabels(_ page: Int) -> [RoomLabel] {
        guard let p = doc.page(at: page), let text = p.string, !text.isEmpty else { return [] }
        let ns = text as NSString
        // From page space to the displayed page with a top-left origin.
        let t = p.transform(for: .cropBox)
        let h = size(p).height
        return findRoomLabels(text) { word in
            var hits: [TextHit] = []
            var from = 0
            while from < ns.length {
                let r = ns.range(of: word, options: [.caseInsensitive, .literal], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                if let sel = p.selection(for: r) {
                    let b = sel.bounds(for: p).applying(t)
                    if !b.isEmpty { hits.append(TextHit(r.location, b.minX, h - b.maxY, b.maxX, h - b.minY)) }
                }
                from = r.location + 1
            }
            return hits
        }
    }

    /** One OCR tile: `tilePx` square at `s` px per point, its top-left at (tx, ty) points. */
    func renderTile(_ page: Int, tx: Double, ty: Double, s: Double, tilePx: Int) -> CGImage? {
        guard let p = doc.page(at: page) else { return nil }
        return PageBitmap(width: tilePx, height: tilePx, ppi: 72 * s) { ctx in draw(p, ctx, s: s, tx: tx, ty: ty, heightPx: tilePx) }?.image
    }

    /**
     * Picks rooms for `runs` from `labels`: the nearest label not behind a wall (walls need the scale `ratio`).
     * `shown` is the page on screen, reused instead of rendering it again.
     */
    func pickRooms(_ runs: [Run], labels: [Int: [RoomLabel]], ratio: Double?, shown: (page: Int, bitmap: PageBitmap)?) -> [Run: String?] {
        var picked: [Run: String?] = [:]
        for (pg, rs) in Dictionary(grouping: runs, by: \.page) {
            guard let l = labels[pg] else { continue } // not read yet (OCR pending): keep its rooms
            if l.isEmpty { for r in rs { picked[r] = .some(nil) }; continue }
            if Task.isCancelled { return [:] }
            guard let bmp = shown?.page == pg ? shown!.bitmap : render(pg) else { continue }
            let walls = ratio.map { r in WallFinder(bmp.ppi * r) { bmp.isDark($0, $1) } }
            for r in rs { let m = r.midPoints(); picked[r] = .some(pickRoom(l, m.x, m.y, bmp.ppi / 72, walls)) }
        }
        return picked
    }
}

/**
 * Room labels on `page` read by on-device OCR (Vision); empty if it fails. The page is rendered in 2048 px tiles at
 * 5 px per point (360 dpi): Vision misses small plan text at the Android app's 3 px/pt (it read 5 of 12 rooms on a
 * scanned letter-size plan, 12 of 12 at 5), and it shrinks bigger tiles internally, which loses the text again.
 * shortcut: a scanned 24x36 sheet is ~100 tiles (tens of seconds, in the background); skip blank tiles if that drags.
 */
func ocrRoomLabels(_ pdf: PlanPDF, _ page: Int) async -> [RoomLabel] {
    let s = 5.0
    let tilePx = 2048
    let tilePt = Double(tilePx) / s
    // Overlap: a line touching an inner tile edge is skipped, so any line up to 200pt (a long label with its size,
    // or two labels read as one) must fit whole in the next tile.
    let step = tilePt - 200
    let size = await pdf.pageSize(page)
    let w = size.width, h = size.height
    func starts(_ len: Double) -> [Double] { (0...Int(ceil(max(0, len - tilePt) / step))).map { Double($0) * step } }
    var words: [OcrWord] = []
    var seen: [(String, Double, Double)] = [] // lines already read in an overlapping tile
    let px = Double(tilePx)
    for ty in starts(h) {
        for tx in starts(w) {
            if Task.isCancelled { return [] }
            guard let tile = await pdf.renderTile(page, tx: tx, ty: ty, s: s, tilePx: tilePx),
                  let lines = try? await recognize(tile) else { continue }
            for (text, b, elements) in lines {
                // A line cut by an inner tile edge is read whole in the next tile.
                if (tx > 0 && b.minX < 2) || (ty > 0 && b.minY < 2) || (tx + tilePt < w && b.maxX > px - 2) || (ty + tilePt < h && b.maxY > px - 2) { continue }
                let cx = tx + b.midX / s, cy = ty + b.midY / s
                if seen.contains(where: { $0.0 == text && abs($0.1 - cx) < 5 && abs($0.2 - cy) < 5 }) { continue }
                seen.append((text, cx, cy))
                for (word, e) in elements {
                    words.append(OcrWord(word, seen.count, tx + e.minX / s, ty + e.minY / s, tx + e.maxX / s, ty + e.maxY / s))
                }
            }
        }
    }
    return ocrLabels(words)
}

/** Text lines in `image`: each line's text, its box and its words' boxes, in image pixels from the top-left. */
private func recognize(_ image: CGImage) async throws -> [(String, CGRect, [(String, CGRect)])] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false // plan labels are abbreviations ("BDRM", "PDR"), not prose
    request.minimumTextHeightFraction = 6 / Float(image.height) // the default skips text under ~1/32 of the tile: all of a plan's labels
    let size = CGSize(width: image.width, height: image.height)
    let found = try await request.perform(on: image)
    func px(_ r: NormalizedRect) -> CGRect { r.toImageCoordinates(size, origin: .upperLeft) }
    return found.compactMap { obs in
        guard let c = obs.topCandidates(1).first else { return nil }
        var elements: [(String, CGRect)] = []
        var i = c.string.startIndex
        for part in c.string.split(separator: " ") {
            guard let r = c.string.range(of: part, range: i..<c.string.endIndex) else { continue }
            i = r.upperBound
            if let box = c.boundingBox(for: r) { elements.append((String(part), px(box.boundingBox))) }
        }
        return (c.string, px(obs.boundingBox), elements)
    }
}
