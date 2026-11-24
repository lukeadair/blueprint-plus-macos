import Foundation

// Pure Swift, no AppKit/SwiftUI: finding room names in a page's text, and which room a run is in.
// Ported line for line from the Android app's Rooms.kt. Text indices are UTF-16 units, as in Kotlin.

/** A room name on a plan page, centered at (`x`, `y`) in PDF points from the page's top-left; `halfW`/`halfH` size its text box. */
struct RoomLabel: Hashable, Sendable {
    var name: String
    var x: Double
    var y: Double
    var halfW = 0.0
    var halfH = 0.0
}

/** One text-search match: where it starts in the page text, and its box in PDF points (top-left origin). */
struct TextHit: Hashable, Sendable {
    var start: Int
    var left: Double, top: Double, right: Double, bottom: Double
    init(_ start: Int, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.start = start; self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

/** One word read by OCR, boxed in PDF points; `line` numbers the text line it was read on. */
struct OcrWord: Hashable, Sendable {
    var text: String
    var line: Int
    var left: Double, top: Double, right: Double, bottom: Double
    init(_ text: String, _ line: Int, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.text = text; self.line = line; self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
}

/** A string read by UTF-16 index, like a Kotlin String. */
struct Text16 {
    let s: String
    let u: [UInt16]
    init(_ s: String) { self.s = s; u = Array(s.utf16) }
    var count: Int { u.count }

    func isLetter(_ i: Int) -> Bool { Unicode.Scalar(u[i]).map { Character($0).isLetter } ?? false }
    func isWhitespace(_ i: Int) -> Bool { Unicode.Scalar(u[i]).map { Character($0).isWhitespace } ?? false }
    func at(_ i: Int) -> Character { Unicode.Scalar(u[i]).map(Character.init) ?? "\u{FFFD}" }

    func regionMatches(_ i: Int, _ w: Text16) -> Bool {
        guard i >= 0, i + w.count <= count else { return false }
        for k in 0..<w.count where u[i + k] != w.u[k] { return false }
        return true
    }
    /** Kotlin's indexOf(word, from): -1 when not found. */
    func indexOf(_ w: Text16, _ from: Int = 0) -> Int {
        var i = max(0, from)
        while i + w.count <= count { if regionMatches(i, w) { return i }; i += 1 }
        return -1
    }
    func substring(_ from: Int, _ to: Int? = nil) -> String {
        String(utf16CodeUnits: Array(u[from..<(to ?? count)]), count: (to ?? count) - from)
    }
}

/** Room labels from OCR words (reading order): the words become the page text, and a search is a match in that text. */
func ocrLabels(_ all: [OcrWord]) -> [RoomLabel] {
    // OCR boxes are too noisy for the label-height vote (a 7pt "BATH" reads 12pt tall), so notes that mention a room
    // are told apart by their line instead: a label's line is a few words, a sentence is longer.
    var lineLen: [Int: Int] = [:]
    for w in all { lineLen[w.line, default: 0] += 1 }
    let words = all.filter { lineLen[$0.line]! <= 4 }
    var text = ""
    var len = 0
    var starts: [Int] = []
    for (i, w) in words.enumerated() {
        if i > 0 { text += w.line == words[i - 1].line ? " " : "\n"; len += 1 }
        starts.append(len)
        let up = w.text.uppercased()
        text += up; len += up.utf16.count
    }
    let upper = Text16(text)
    return findRoomLabels(text, byHeight: false) { word in
        let w = Text16(word)
        var out: [TextHit] = []
        var i = upper.indexOf(w)
        while i >= 0 {
            let hit = words.indices.filter { starts[$0] < i + w.count && starts[$0] + words[$0].text.utf16.count > i }.map { words[$0] }
            if !hit.isEmpty {
                out.append(TextHit(i, hit.map(\.left).min()!, hit.map(\.top).min()!, hit.map(\.right).max()!, hit.map(\.bottom).max()!))
            }
            i = upper.indexOf(w, i + 1)
        }
        return out
    }
}

// Words that label rooms on residential plans. Longest first so "MASTER BATH" claims its text before "BATH".
// Left out on purpose: words that also show up in general notes (DECK, BAR, DEN, SHOP, FAMILY, SUITE).
private let ROOM_WORDS: [String] = [
    "MASTER BATHROOM", "MASTER BATH", "MASTER BEDROOM", "MASTER CLOSET", "MASTER SUITE",
    "PRIMARY BATHROOM", "PRIMARY BATH", "PRIMARY BEDROOM", "PRIMARY CLOSET",
    "GUEST BATHROOM", "GUEST BATH", "GUEST BEDROOM", "GUEST ROOM", "HALF BATH",
    "POWDER ROOM", "LAUNDRY ROOM", "LIVING ROOM", "FAMILY ROOM", "GREAT ROOM", "DINING ROOM",
    "MUD ROOM", "BONUS ROOM", "GAME ROOM", "MEDIA ROOM", "SITTING ROOM", "UTILITY ROOM",
    "WALK-IN CLOSET", "BUTLER'S PANTRY", "BUTLERS PANTRY", "BREAKFAST NOOK", "WET BAR",
    "FRONT PORCH", "BACK PORCH", "SCREENED PORCH",
    "KITCHEN", "BATHROOM", "BATH", "BEDROOM", "CLOSET", "CLOS", "WIC", "PANTRY", "LAUNDRY", "UTILITY",
    "MUDROOM", "GARAGE", "OFFICE", "STUDY", "DINING", "LIVING", "BREAKFAST", "ENTRY", "FOYER",
    "HALLWAY", "HALL", "PORCH", "PATIO", "NOOK", "POWDER", "PWDR", "STORAGE", "LOFT", "LIBRARY", "GYM",
    "FLEX", "CARPORT",
    // Common plan abbreviations
    "M.BTH", "M. BTH", "M.BATH", "MSTR BATH", "MSTR BDRM", "BEDRM", "BDRM", "BTH", "PDR", "LNDY", "UTIL", "CL", "MASTER CL", "MSTR CL",
].enumerated().sorted { a, b in a.element.utf16.count != b.element.utf16.count ? a.element.utf16.count > b.element.utf16.count : a.offset < b.offset }
    .map(\.element) // stable, like Kotlin's sortedByDescending

private let ABBREVIATIONS: [String: String] = [
    "CLOS": "Closet", "CL": "Closet", "WIC": "Walk-in Closet", "PWDR": "Powder", "PDR": "Powder",
    "M.BTH": "Master Bath", "M. BTH": "Master Bath", "M.BATH": "Master Bath", "MSTR BATH": "Master Bath",
    "MSTR BDRM": "Master Bedroom", "BEDRM": "Bedroom", "BDRM": "Bedroom", "BTH": "Bath", "LNDY": "Laundry", "UTIL": "Utility",
    "MASTER CL": "Master Closet", "MSTR CL": "Master Closet",
]
// Too short to trust alone (CL is also "centerline"): only counts as a room when numbered, like "CL 1".
private let NEEDS_NUMBER: Set<String> = ["CL"]
// A heading in an area table, not a room: "LIVING AREAS SQ. FT.", "GARAGE SF".
private let AREA_HEADING = Re(#"^\s*(?:AREAS?\s+)?(?:SQ\b|SF\b|S\.F\.)"#)
// "BEDROOM 2", "BEDROOM #3", but not a room size: "KITCHEN 10'x26'1" or "FLEX 12' x 10'".
private let NUMBER_AFTER = Re(#"^\s*#?([0-9]{1,2})(?![0-9'"’′x×.,/-])"#)

/**
 * Finds room labels on one page. `pageText` is the page's text; `search` returns every match of a word
 * with its position (PDFKit's findString). Only whole words count, and only at the text height most
 * room words on the page share: notes that mention a room ("remove exist. deck") use a different size.
 */
func findRoomLabels(_ pageText: String, search: (String) -> [TextHit]) -> [RoomLabel] {
    findRoomLabels(pageText, byHeight: true, search: search)
}

/** `byHeight` false skips the label-height filter (OCR boxes are too noisy for it). */
private func findRoomLabels(_ pageText: String, byHeight: Bool, search: (String) -> [TextHit]) -> [RoomLabel] {
    let upperS = pageText.uppercased()
    let upper = Text16(upperS)
    var hits: [(String, TextHit)] = []
    var textHeight: [TextHit: Double] = [:]
    for word in ROOM_WORDS {
        let w = Text16(word)
        // The phrase as the text stores it, plus its words placed together on the page in any text order.
        let found = (upperS.contains(word) ? search(word).map { ($0, $0.start + w.count) } : [])
            + (word.contains(" ") ? placedTogether(word, upper, search) : [])
        for (h0, end0) in found {
            // The search's start can sit a few chars off ("SHALL" for HALL, 2 early after a CR/LF): find the word again nearby.
            var at: Int?
            if h0.start >= 0 && !upper.regionMatches(h0.start, w) {
                let i = upper.indexOf(w, max(0, h0.start - 4))
                if i >= 0 && abs(i - h0.start) <= 4 { at = i }
            }
            var h = h0
            if let at { h.start = at }
            let end = at.map { $0 + w.count } ?? end0
            let indexed = h.start >= 0 && end <= upper.count && upper.regionMatches(h.start, w)
            if indexed && h.start > 0 && upper.isLetter(h.start - 1) { continue } // "...BATH" inside a word
            if indexed && end < upper.count && upper.isLetter(end) { continue } // "CLOS" in "CLOSED"
            // Text already taken ("BATH" in "MASTER BATH", or the same name found twice): another hit covers half its
            // box. A tiny tag clipping a label ("PANTRY 1", "MASTER CLOSET 1") doesn't; the height filter drops those.
            if hits.contains(where: { overlapArea($0.1, h) >= 0.5 * (h.right - h.left) * (h.bottom - h.top) }) { continue }
            // A name pieced together from its words (start -1) reads its room number after its last word.
            let after = indexed || (h.start < 0 && end >= 0 && end <= upper.count) ? upper.substring(end) : ""
            if NEEDS_NUMBER.contains(word) && !NUMBER_AFTER.contains(after) { continue }
            if AREA_HEADING.contains(after) { continue }
            let q = indexed ? qualifier(upper, h, search).map { "\($0) " } ?? "" : ""
            hits.append((q + displayName(word, after), h))
            // A name set on two lines ("FRONT" over "PORCH") comes back as one box twice as tall as its text:
            // size it by its first word's own box instead.
            if !word.contains(" ") {
                textHeight[h] = glyphSize(h)
            } else {
                let first = String(word[..<word.firstIndex(of: " ")!])
                textHeight[h] = search(first)
                    .filter { $0.left >= h.left - 1 && $0.right <= h.right + 1 && $0.top >= h.top - 1 && $0.bottom <= h.bottom + 1 }
                    .map(glyphSize).min() ?? glyphSize(h)
            }
        }
    }
    if hits.isEmpty { return [] }
    // Only horizontal text votes: a page full of tiny vertical tags (5pt "KITCHEN" on cabinets) must not outvote the labels.
    let horizontal = hits.filter { $0.1.right - $0.1.left >= $0.1.bottom - $0.1.top }
    let voters = horizontal.isEmpty ? hits : horizontal
    var order: [Int] = []
    var counts: [Int: Int] = [:]
    for v in voters { let k = roundToInt(textHeight[v.1]!); if counts[k] == nil { order.append(k) }; counts[k, default: 0] += 1 }
    let commonHeight = Double(order.maxBy { counts[$0]! }!)
    return hits
        // Tight: search boxes are whole points, so a 6pt note can measure 8 next to 10pt labels.
        .filter { !byHeight || abs(textHeight[$0.1]! - commonHeight) <= max(1, commonHeight * 0.12) }
        .filter { !notACabinetRoom($0.0) }
        .map { name, h in RoomLabel(name: name, x: (h.left + h.right) / 2, y: (h.top + h.bottom) / 2, halfW: (h.right - h.left) / 2, halfH: (h.bottom - h.top) / 2) }
}

// Text size from its box: the short side, so a vertical label (tall narrow box) measures like a horizontal one.
private func glyphSize(_ h: TextHit) -> Double { min(h.right - h.left, h.bottom - h.top) }

// Closets worth a room of their own: master/his/her and walk-ins. Other closets, halls, and every porch, patio, garage, carport and storage are dropped
// after the height filter, so their words still claim text and count toward the common label height.
private let KEPT_CLOSET = Re(#"^(?:(?:Master|Mstr|Mst|Primary|His|Hers?|Walk-in)\b|M\.)"#)
private let TRAILING_NUMBER = Re(#"\s+[0-9]+$"#)
private func notACabinetRoom(_ name: String) -> Bool {
    let base = TRAILING_NUMBER.replace(name, with: "")
    return ["Porch", "Patio", "Garage", "Carport", "Storage", "Foyer"].contains { base.contains($0) }
        || base.hasSuffix("Hall") || base.hasSuffix("Hallway") || base.hasSuffix("Closet") && !KEPT_CLOSET.contains(base)
}

/**
 * A multi-word name found word by word: each next word right after the last on the same line, or starting
 * on the line below it, at the same text height. Some PDFs store a name set on two lines out of order
 * ("ROOM 18'x20'7 ... GREAT"), so the phrase search misses it. Returns one box per name, with start -1 and
 * the text index just past its last word.
 */
private func placedTogether(_ word: String, _ upper: Text16, _ search: (String) -> [TextHit]) -> [(TextHit, Int)] {
    let parts = word.split(separator: " ").map(String.init)
    if parts.contains(where: { !upper.s.contains($0) }) { return [] }
    func whole(_ h: TextHit, _ w: Text16) -> Bool {
        h.start >= 0 && h.start + w.count <= upper.count && upper.regionMatches(h.start, w)
            && (h.start == 0 || !upper.isLetter(h.start - 1))
            && (h.start + w.count == upper.count || !upper.isLetter(h.start + w.count))
    }
    let found = parts.map { p in let w = Text16(p); return search(p).filter { whole($0, w) } }
    return found[0].compactMap { first -> (TextHit, Int)? in
        let lineH = first.bottom - first.top
        var box = first
        var last = first
        for next in found.dropFirst() {
            guard let n = next.first(where: { h in
                let sameHeight = abs((h.bottom - h.top) - lineH) <= lineH * 0.2
                let sameLine = abs(h.top - last.top) <= lineH / 2 && h.left >= last.right && h.left - last.right <= lineH
                let nextLine = h.top >= last.top + lineH / 2 && h.top - last.bottom <= lineH && h.left < last.right && last.left < h.right
                return sameHeight && (sameLine || nextLine)
            }) else { return nil }
            box = TextHit(-1, min(box.left, n.left), box.top, max(box.right, n.right), max(box.bottom, n.bottom))
            last = n
        }
        return (box, last.start + parts.last!.utf16.count)
    }
}

private func overlapArea(_ a: TextHit, _ b: TextHit) -> Double {
    max(0, min(a.right, b.right) - max(a.left, b.left)) * max(0, min(a.bottom, b.bottom) - max(a.top, b.top))
}

private let QUALIFIER = Re(#"^[A-Z][A-Z']{0,7}\.?$"#)
private let NOT_QUALIFIERS: Set<String> = ["A", "AT", "AND", "FOR", "IN", "OF", "ON", "THE", "TO", "NEW", "EXIST", "EXIST.", "EXISTING"]

/**
 * The word in front of a room word on the same line, so "GIRLS BATH" and "M. BATH" stay apart from plain "BATH":
 * `Girls`, `M.`. Nil when there's none, it's another room word ("HALL BATH" stays two rooms), or a filler word.
 */
private func qualifier(_ upper: Text16, _ h: TextHit, _ search: (String) -> [TextHit]) -> String? {
    if h.start < 2 || upper.at(h.start - 1) != " " { return nil }
    var from = h.start - 1
    while from > 0 && (upper.isLetter(from - 1) || upper.at(from - 1) == "." || upper.at(from - 1) == "'") { from -= 1 }
    if from > 0 && !upper.isWhitespace(from - 1) { return nil } // "LNDY/MUD PDR": MUD belongs to LNDY/MUD
    let w = upper.substring(from, h.start - 1)
    guard QUALIFIER.contains(w) else { return nil }
    if NOT_QUALIFIERS.contains(w) || ROOM_WORDS.contains(where: { $0 == w || $0.hasSuffix(" \(w)") }) { return nil }
    let wLen = w.utf16.count
    let height = h.bottom - h.top
    // On the page right before the room word, on its line (the text order alone can join unrelated lines).
    guard let it = search(w).first(where: { $0.start == h.start - wLen - 1 }),
          abs(it.top - h.top) <= height / 2 && it.right <= h.left + 1 && h.left - it.right <= 2 * (it.right - it.left) / Double(wLen) // a space or two
    else { return nil }
    return w.prefix(1) + w.dropFirst().lowercased()
}

/**
 * `labels` with repeated names numbered in reading order ("Storage", "Storage 2"), so two rooms with one name
 * don't merge into one in the run list. Names in `taken` (rooms on other pages) count as used.
 */
func numberRepeats(_ labels: [RoomLabel], taken: Set<String>) -> [RoomLabel] {
    var used = taken
    let onPage = Set(labels.map(\.name))
    var out = labels
    let order = labels.indices.sorted { a, b in
        let la = labels[a], lb = labels[b]
        return la.y != lb.y ? la.y < lb.y : la.x != lb.x ? la.x < lb.x : a < b
    }
    for i in order {
        let name = labels[i].name
        // a number already used by a label on this page ("Bedroom 2") is skipped too
        var k = 1
        var n = name
        while used.contains(n) || (n != name && onPage.contains(n)) { k += 1; n = "\(name) \(k)" }
        used.insert(n)
        out[i].name = n
    }
    return out
}

/**
 * Whether (`x`, `y`) sits in a table (a schedule listing rooms) rather than on the floor plan: 4+ long horizontal
 * lines evenly spaced 6-30pt apart (ruled rows; a 24x36 sheet's are ~20pt) within 105pt above or below, with the
 * label among them or at most one row past them (a last row with no rule below it).
 * `pxPerPt` is bitmap pixels per PDF point; `isDark` reads one pixel.
 */
func inTable(_ x: Double, _ y: Double, _ pxPerPt: Double, _ isDark: (Int, Int) -> Bool) -> Bool {
    let minLen = 72 * pxPerPt // a paper inch
    let cx = roundToInt(x * pxPerPt)
    func spanAt(_ yy: Int) -> Double {
        func run(_ dir: Int) -> Int { // dark pixels along the row, bridging gaps of up to 2px (antialiasing)
            var n = 0, gap = 0, k = 1
            while Double(n) < minLen && gap <= 2 { if isDark(cx + dir * k, yy) { n += gap + 1; gap = 0 } else { gap += 1 }; k += 1 }
            return n
        }
        return isDark(cx, yy) ? 1 + Double(run(1) + run(-1)) : 0
    }
    var rows: [Int] = []
    var yy = roundToInt((y - 105) * pxPerPt)
    let end = roundToInt((y + 105) * pxPerPt)
    while yy <= end {
        if spanAt(yy) >= minLen { rows.append(yy); yy += max(2, roundToInt(3 * pxPerPt)) } else { yy += 1 }
    }
    let py = y * pxPerPt
    // three gaps in a row, each 6-30pt and within 1.5pt of the first, around the label (not dimension strings nearby)
    guard rows.count >= 4 else { return false }
    return (0...rows.count - 4).contains { s in
        let r = Array(rows[s..<s + 4])
        let g = r.pairs().map { Double($0.1 - $0.0) / pxPerPt }
        return g.allSatisfy { $0 >= 6 && $0 <= 30 && abs($0 - g[0]) <= 1.5 }
            && py >= Double(r[0]) - g[0] * pxPerPt && py <= Double(r[3]) + g[0] * pxPerPt
    }
}

private func displayName(_ word: String, _ after: String) -> String {
    let name = ABBREVIATIONS[word]
        ?? word.lowercased().split(separator: " ", omittingEmptySubsequences: false).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    if let m = NUMBER_AFTER.first(after) { return "\(name) \(after.group(m, 1))" }
    return name
}

/** The room whose label is nearest to (`x`, `y`) on the same page, or nil if the page has none. */
func nearestRoom(_ labels: [RoomLabel], _ x: Double, _ y: Double) -> String? {
    labels.minBy { ($0.x - x) * ($0.x - x) + ($0.y - y) * ($0.y - y) }?.name
}

/**
 * The room for a run whose midpoint is at (`x`, `y`) PDF points: the nearest label whose sightline doesn't
 * cross a wall, else the nearest label. `walls` checks a sightline in page-bitmap pixels; nil skips it.
 */
func pickRoom(_ labels: [RoomLabel], _ x: Double, _ y: Double, _ pxPerPoint: Double, _ walls: WallFinder?) -> String? {
    let byDistance = labels.enumerated().sorted { a, b in
        let da = (a.element.x - x) * (a.element.x - x) + (a.element.y - y) * (a.element.y - y)
        let db = (b.element.x - x) * (b.element.x - x) + (b.element.y - y) * (b.element.y - y)
        return da != db ? da < db : a.offset < b.offset
    }.map(\.element)
    guard let walls else { return byDistance.first?.name }
    let clear = byDistance.first { l in
        !walls.crosses(
            x * pxPerPoint, y * pxPerPoint, l.x * pxPerPoint, l.y * pxPerPoint,
            // stop at the label's own text, plus a little, so its letters don't count
            halfW: l.halfW * pxPerPoint + 2, halfH: l.halfH * pxPerPoint + 2
        )
    }
    return (clear ?? byDistance.first)?.name
}

/**
 * Finds walls along a sightline on a rendered plan. A wall is two long parallel lines 3"-12" apart, center to
 * center (a stud wall is 3.5"; a countertop edge over its cabinet face is ~2.5"), or one long solid band at
 * least 3" thick (filled walls). "Long" means straight for 48"+, which leaves out text, fixture symbols (a 36"
 * cooktop's outline, burners, sinks) and dashed lines. A wall stub beside a door (faces 24"-48") counts too when
 * the pair is closed at one end only: the jamb at the door, open where it joins the next wall (a fixture's box is
 * closed at both). Also a long face paired with a piece of the other face that ends at a wall joining it, and a window: one
 * long glazing line with the wall's two faces carrying on past its jamb. Sizes are real-world inches, turned into pixels with `pxPerInch` (bitmap ppi x drawing scale).
 * `isDark` reads one pixel.
 */
final class WallFinder {
    private let minGap: Double
    private let maxGap: Double
    private let minLength: Double
    private let stubLength: Double
    private let isDark: (Int, Int) -> Bool

    init(_ pxPerInch: Double, _ isDark: @escaping (Int, Int) -> Bool) {
        minGap = 3 * pxPerInch; maxGap = 12 * pxPerInch; minLength = 48 * pxPerInch; stubLength = 24 * pxPerInch
        self.isDark = isDark
    }

    /** A line the ray crosses `t` pixels along; `ends` (x, y, x, y) only on a short (stub) line, nil on a long one. */
    private struct Line {
        var t: Double, angle: Double, thickness: Double, sinToRay: Double
        var ends: [Double]? = nil
    }

    private func dark(_ x: Double, _ y: Double) -> Bool { isDark(roundToInt(x), roundToInt(y)) }

    /** Whether the segment from (x0, y0) toward (x1, y1) crosses a wall before reaching the box around (x1, y1). */
    func crosses(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, halfW: Double = 0, halfH: Double = 0) -> Bool {
        let len = hypot(x1 - x0, y1 - y0)
        if len < 1 { return false }
        let ux = (x1 - x0) / len, uy = (y1 - y0) / len
        let rayAngle = atan2(uy, ux)
        var lines: [Line] = []
        var runStart = -1
        var i = 0
        while i <= Int(len) {
            let px = x0 + ux * Double(i), py = y0 + uy * Double(i)
            if abs(px - x1) <= halfW && abs(py - y1) <= halfH { break } // reached the label's text
            let d = dark(px, py)
            if d && runStart < 0 { runStart = i }
            if !d && runStart >= 0 { lines += linesIn(x0, y0, ux, uy, runStart, i - 1, rayAngle); runStart = -1 }
            i += 1
        }
        if runStart >= 0 { lines += linesIn(x0, y0, ux, uy, runStart, i - 1, rayAngle) }

        func pair(_ a: Line, _ b: Line) -> Bool {
            let parallel = abs(sin(a.angle - b.angle)) < sin(15 * .pi / 180)
            // center to center, measured across the lines rather than along the ray
            let gap = (b.t - a.t) * a.sinToRay
            return parallel && gap >= minGap && gap <= maxGap
        }
        let long = lines.filter { $0.ends == nil }
        if long.contains(where: { $0.thickness >= minGap }) { return true } // filled wall
        if long.pairs().contains(where: { pair($0.0, $0.1) }) { return true }
        if long.contains(where: { isWindow(x0 + ux * $0.t, y0 + uy * $0.t, $0.angle) }) { return true }
        return lines.pairs().contains { a, b in
            guard pair(a, b) else { return false }
            if a.ends != nil && b.ends != nil { return isStub(a, b) }
            if a.ends == nil && b.ends == nil { return false }
            // one long face, one piece of the other face: the piece ends where another wall joins this one
            let (s, l) = a.ends != nil ? (a, b) : (b, a)
            let away = s.t > l.t ? 1.0 : -1.0
            return endsAtJoiningWall(s, ux * away, uy * away)
        }
    }

    /**
     * Offsets k in `range` from (px, py) along (ox, oy) where a line runs at least `maxGap / 2` (6") along (dx, dy):
     * the faces of a wall crossing that segment.
     */
    private func faces(_ px: Double, _ py: Double, _ ox: Double, _ oy: Double, _ range: ClosedRange<Int>, _ dx: Double, _ dy: Double) -> [Int] {
        range.filter { k in
            let x = px + ox * Double(k), y = py + oy * Double(k)
            return dark(x, y) && Double(darkRun(x, y, dx, dy, maxGap / 2)) >= maxGap / 2 - 1
        }
    }

    private func wallWide(_ a: Int, _ b: Int) -> Bool { Double(abs(b - a)) >= minGap && Double(abs(b - a)) <= maxGap }

    /**
     * A long single line through (cx, cy) is a window's glazing when, just past one of its ends (the jamb), a wall's
     * two faces carry on along it, one on each side: the wall it sits in. A counter edge or a lone face ends
     * at a corner or runs on.
     */
    private func isWindow(_ cx: Double, _ cy: Double, _ angle: Double) -> Bool {
        let ax = cos(angle), ay = sin(angle), nx = -ay, ny = ax
        // from the stroke's middle, so the run along it doesn't slip off its edge
        let m = Double(darkRun(cx, cy, nx, ny, maxGap) - darkRun(cx, cy, -nx, -ny, maxGap)) / 2
        let mx = cx + nx * m, my = cy + ny * m
        let cap = 240 * minGap / 3 // 20'
        let g = Int(maxGap)
        return [1.0, -1.0].contains { s in
            let e = Double(darkRun(mx, my, ax * s, ay * s, cap))
            if e >= cap - 1 { return false }
            return (1...Int(minGap)).contains { k in // the faces start right past the jamb
                let px = mx + ax * s * (e + Double(k)), py = my + ay * s * (e + Double(k))
                if (-1...1).contains(where: { dark(px + nx * Double($0), py + ny * Double($0)) }) { return false } // not the wall's hollow
                let f = faces(px, py, nx, ny, -g...g, ax * s, ay * s)
                // the glass sits in the middle half of the wall
                return f.contains { a in a < 0 && f.contains { b in b > 0 && wallWide(a, b) && abs(a + b) * 2 <= b - a } }
            }
        }
    }

    /**
     * Short line `s` (a piece of a wall's face, the other face long) ends where another wall joins: its two faces
     * run off (dx, dy), away from the long face, a wall's width apart, starting at one of `s`'s ends. A fixture
     * outline beside a counter edge has no wall running off it.
     */
    private func endsAtJoiningWall(_ s: Line, _ dx: Double, _ dy: Double) -> Bool {
        let e = s.ends!
        let len = hypot(e[0] - e[2], e[1] - e[3])
        let g = Int(maxGap)
        return [0, 2].contains { i in
            let ox = (e[i] - e[2 - i]) / len, oy = (e[i + 1] - e[3 - i]) / len // outward along s
            let f = faces(e[i], e[i + 1], ox, oy, -3...(g + 3), dx, dy)
            return f.contains { a in a <= 3 && f.contains { b in b > a && wallWide(a, b) } } // its near face right at the end
        }
    }

    /**
     * Short faces `a` and `b` are a wall stub beside a door: the shorter one is joined straight across to the other
     * at one end only (the jamb), and its other end meets a long line across it (the face of the wall it joins). A
     * fixture's box is closed at both ends, a washer's double outline meets no long line, unrelated lines neither.
     */
    private func isStub(_ a: Line, _ b: Line) -> Bool {
        func len(_ l: Line) -> Double { let e = l.ends!; return hypot(e[0] - e[2], e[1] - e[3]) }
        let (s, o) = len(a) <= len(b) ? (a, b) : (b, a)
        let e = s.ends!, oe = o.ends!
        let ox = cos(o.angle), oy = sin(o.angle)
        let sx = cos(s.angle), sy = sin(s.angle)
        let closed = [0, 2].filter { i in
            let x1 = e[i], y1 = e[i + 1]
            let k = (x1 - oe[0]) * ox + (y1 - oe[1]) * oy // the other face's point straight across
            let x2 = oe[0] + ox * k, y2 = oe[1] + oy * k
            return (-2...2).contains { d in // the face's last dark pixel may sit on either side of the closing stroke
                [0.25, 0.5, 0.75].allSatisfy { f in dark(x1 + (x2 - x1) * f + sx * Double(d), y1 + (y2 - y1) * f + sy * Double(d)) }
            }
        }
        if closed.count != 1 { return false }
        // The open end of either face: only the one on the joined wall's side meets its face.
        let ex = e[2 - closed[0]], ey = e[3 - closed[0]]
        let j = hypot(oe[0] - ex, oe[1] - ey) <= hypot(oe[2] - ex, oe[3] - ey) ? 0 : 2
        return [(ex, ey), (oe[j], oe[j + 1])].contains { x0, y0 in
            (-2...2).contains { d in // the face may stop a pixel short of the wall's face, or on it
                let x = x0 + sx * Double(d), y = y0 + sy * Double(d)
                return (-2...2).contains { k in
                    let a2 = s.angle + .pi / 2 + Double(k) * .pi / 36
                    return darkSpan(x, y, cos(a2), sin(a2), minLength) >= minLength
                }
            }
        }
    }

    /**
     * Long lines inside dark stretch `from`...`to` of the ray. Checked every 2px, not just at the middle: a wall
     * face can touch a fixture (a faucet against it) or its twin face, and they'd share one dark stretch.
     */
    private func linesIn(_ x0: Double, _ y0: Double, _ ux: Double, _ uy: Double, _ from: Int, _ to: Int, _ rayAngle: Double) -> [Line] {
        var found: [Line] = []
        var t = from
        while t <= to {
            if let line = lineAt(x0 + ux * Double(t), y0 + uy * Double(t), Double(t), rayAngle) { found.append(line); t += 3 } else { t += 2 } // skip past this line's own stroke
        }
        // A stroke crossed at a shallow angle covers several samples: merge hits within one stroke's width
        // along the ray, and place the line at their middle.
        var merged: [[Line]] = []
        for l in found {
            if let g = merged.last, l.t - g.last!.t <= g.map(\.thickness).max()! / g[0].sinToRay + 2 {
                merged[merged.count - 1].append(l)
            } else {
                merged.append([l])
            }
        }
        return merged.map { g in
            Line(t: g.reduce(0) { $0 + $1.t } / Double(g.count), angle: g[0].angle, thickness: g.map(\.thickness).max()!, sinToRay: g[0].sinToRay,
                 ends: g.allSatisfy { $0.ends != nil } ? g[0].ends : nil)
        }
    }

    /** The straight line (24"+) through (`cx`, `cy`), `t` along the ray, or nil if there isn't one. */
    private func lineAt(_ cx: Double, _ cy: Double, _ t: Double, _ rayAngle: Double) -> Line? {
        var best = 0.0
        var bestAngle = 0.0
        for step in 0..<36 { // every 5 degrees
            let a = Double(step) * .pi / 36
            let length = darkSpan(cx, cy, cos(a), sin(a), minLength)
            if length > best { best = length; bestAngle = a }
            if best >= minLength { break }
        }
        if best < stubLength { return nil }
        let sinToRay = abs(sin(bestAngle - rayAngle))
        if sinToRay < 0.25 { return nil } // the ray runs along this line, not across it
        // Thickness across the line, at three spots along it: the smallest ignores places where another line crosses.
        let ax = cos(bestAngle), ay = sin(bestAngle)
        let thickness = [0, minLength / 4, -minLength / 4].map { o in darkSpan(cx + ax * o, cy + ay * o, -ay, ax, maxGap) }.min()!
        var ends: [Double]?
        if best < minLength {
            let f = Double(darkRun(cx, cy, ax, ay, minLength)), b = Double(darkRun(cx, cy, -ax, -ay, minLength))
            ends = [cx + ax * f, cy + ay * f, cx - ax * b, cy - ay * b]
        }
        return Line(t: t, angle: bestAngle, thickness: thickness, sinToRay: sinToRay, ends: ends)
    }

    /** How many dark pixels follow (cx, cy) along (dx, dy), up to `cap`. */
    private func darkRun(_ cx: Double, _ cy: Double, _ dx: Double, _ dy: Double, _ cap: Double) -> Int {
        var k = 1
        while Double(k) < cap && dark(cx + dx * Double(k), cy + dy * Double(k)) { k += 1 }
        return k - 1
    }

    /** How far the dark pixels continue through (cx, cy) in both directions along (dx, dy), up to `cap`. */
    private func darkSpan(_ cx: Double, _ cy: Double, _ dx: Double, _ dy: Double, _ cap: Double) -> Double {
        var n = 1.0
        for sign in [1.0, -1.0] {
            var k = 1.0
            while n < cap && dark(cx + sign * dx * k, cy + sign * dy * k) { n += 1; k += 1 }
        }
        return n
    }
}
