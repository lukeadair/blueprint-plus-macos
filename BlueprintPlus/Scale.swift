import Foundation
import Compression

// Pure Swift, no AppKit/SwiftUI: all length/scale parsing and math. Keep it unit-testable.
// Ported from the Android app's Scale.kt; `\d` is written [0-9] because Java's \d is ASCII-only and ICU's isn't.

/** A regex over UTF-16 (NSString) indices, the same indexing Kotlin strings use. */
struct Re: @unchecked Sendable { // NSRegularExpression is immutable and thread-safe
    let re: NSRegularExpression
    init(_ pattern: String, ignoreCase: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }
    func all(_ s: String, from: Int = 0) -> [NSTextCheckingResult] {
        let n = (s as NSString).length
        guard from <= n else { return [] }
        return re.matches(in: s, range: NSRange(location: from, length: n - from))
    }
    func first(_ s: String, from: Int = 0) -> NSTextCheckingResult? {
        let n = (s as NSString).length
        guard from <= n else { return nil }
        return re.firstMatch(in: s, range: NSRange(location: from, length: n - from))
    }
    func contains(_ s: String) -> Bool { first(s) != nil }
    func replace(_ s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
}

extension String {
    func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : (self as NSString).substring(with: r)
    }
    func whole(_ m: NSTextCheckingResult) -> String { (self as NSString).substring(with: m.range) }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func normalizedQuotes() -> String {
        replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "′", with: "'")
            .replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "″", with: "\"")
    }
}

private let PART = Re(#"([0-9]+/[0-9]+|[0-9]+(?:\.[0-9]+)?(?:\s+[0-9]+/[0-9]+)?)\s*(['"]?)"#)
private let FEET_WORD = Re(#"\s*(ft|feet|foot)\b"#)
private let INCH_WORD = Re(#"\s*(in|inch|inches)\b"#)

/**
 * Parses a length like `1/4"`, `1 1/2"`, `12' 6"`, `1'-0"`, `3.5'` into inches.
 * A bare number (no `'` or `"`) is worth `bareUnitInches` each.
 */
func parseLength(_ text: String, _ bareUnitInches: Double) -> Double? {
    let s = INCH_WORD.replace(FEET_WORD.replace(text.trimmed.normalizedQuotes(), with: "'"), with: "\"")
    let parts = PART.all(s)
    if parts.isEmpty || PART.replace(s, with: "").contains(where: { $0 != " " && $0 != "-" }) { return nil }
    if parts.count > 1 && parts.contains(where: { s.group($0, 2).isEmpty }) { return nil }
    var sum = 0.0
    for m in parts {
        guard let n = parseNumber(s.group(m, 1)) else { return nil }
        switch s.group(m, 2) {
        case "'": sum += n * 12
        case "\"": sum += n
        default: sum += n * bareUnitInches
        }
    }
    return sum
}

private func parseNumber(_ s: String) -> Double? {
    var sum = 0.0
    for piece in s.trimmed.split(whereSeparator: { $0.isWhitespace }) {
        if piece.contains("/") {
            let ab = piece.split(separator: "/", omittingEmptySubsequences: false)
            guard ab.count == 2, let a = Double(ab[0]), let b = Double(ab[1]) else { return nil }
            if b == 0 { return nil }
            sum += a / b
        } else {
            guard let v = Double(piece) else { return nil }
            sum += v
        }
    }
    return sum
}

/**
 * Parses a drawing scale like `1/4" = 1'` into a ratio of paper inches per real inch
 * (1/48 for quarter-inch scale). Left side defaults to inches, right side to feet.
 */
func parseScale(_ text: String) -> Double? {
    let sides = text.split(separator: "=", omittingEmptySubsequences: false)
    if sides.count != 2 { return nil }
    guard let paper = parseLength(String(sides[0]), 1), let real = parseLength(String(sides[1]), 12) else { return nil }
    if paper <= 0 || real <= 0 { return nil }
    return paper / real
}

// Architectural scales, as paper inches per foot. Neighbours are 25%+ apart, so a 2% snap can't pick the wrong one.
private let STANDARD_SCALES = ["3", "1 1/2", "1", "3/4", "1/2", "3/8", "1/4", "3/16", "1/8", "3/32", "1/16"]

/**
 * Scale text for a calibration: `paperInches` on the sheet measured `realInches` in real life.
 * Within 2% of a standard scale it is that scale (tap error); a plan printed reduced (~5%+ off) keeps its own.
 */
func calibratedScale(_ paperInches: Double, _ realInches: Double) -> String {
    let perFoot = paperInches / realInches * 12
    if let s = STANDARD_SCALES.first(where: { abs(perFoot / parseNumber($0)! - 1) <= 0.02 }) { return "\(s)\" = 1'" }
    return String(format: "%.4f\" = 1'", perFoot)
}

/** Real-world inches for a line `px` long on a page rendered at `ppi`, at scale `ratio`. */
func realInches(_ px: Double, _ ppi: Double, _ ratio: Double) -> Double { px / ppi / ratio }

/** `150.0` -> `12' 6"`, rounded to the nearest inch. */
func formatFeetInches(_ inches: Double) -> String {
    let total = Int((inches + 0.5).rounded(.down))
    return "\(total / 12)' \(total % 12)\""
}

/** `%.2f LF` for inches. */
func formatLF(_ inches: Double) -> String { String(format: "%.2f LF", inches / 12) }

private let IN = #"(?:"|in\b|inch(?:es)?\b)"#
private let NUM = #"(?:[0-9]+/[0-9]+|[0-9]+(?:\.[0-9]+)?(?:\s+[0-9]+/[0-9]+)?)"#
// `1/4" = 1'-0"`, `3/16 in = 1 ft`, `1" = 20'`: paper (inches, unit optional) = real (feet, then optional inches).
// The inches tail needs the hyphen and stays on the line, so `1' 6" UPPERS` or `1'⏎36"` isn't read as 1'-6" / 1'-36".
private let CAPTION = Re(#"scale[ \t]*[-:]?[ \t]*\z"#, ignoreCase: true)
private let SCALE_PHRASE = Re(
    #"(?<![0-9/.])"# + NUM + #"\s*"# + IN + #"?\s*=\s*[0-9]+(?:\.[0-9]+)?\s*(?:'|ft\b|feet\b|foot\b)(?:[ \t]*-[ \t]*"# + NUM + #"[ \t]*"# + IN + ")?",
    ignoreCase: true
)

/**
 * The drawing scale stated in `text` (a plan's title block, a PDF measure string), or nil. Only plan scales count
 * (3" per foot or smaller, so a note like `30" = 2'-6"` doesn't), and ones ending `= 1'` beat others (`1" = 20'`).
 * Among those the most common wins (a sheet's main scale outnumbers its detail callouts). Standard scales come back
 * as `1/4" = 1'`. `captioned`: only ones right after the word "scale" on their line (`Scale - 3/16" = 1'`).
 */
func findScale(_ text: String, captioned: Bool = false) -> String? {
    let s = text.normalizedQuotes()
    let all: [(Double, String)] = SCALE_PHRASE.all(s).compactMap { m in
        let at = m.range.location
        if captioned && !CAPTION.contains((s as NSString).substring(with: NSRange(location: max(0, at - 12), length: min(12, at)))) { return nil }
        let v = s.whole(m)
        guard let r = parseScale(v), r * 12 <= 3 + 1e-9 else { return nil }
        return (r, v.trimmed)
    }
    let perOneFoot = all.filter { isPerOneFoot($0.1) }
    let found = perOneFoot.isEmpty ? all : perOneFoot
    // groupingBy + maxBy: the first ratio (in order seen) with the highest count
    var order: [Double] = []
    var counts: [Double: Int] = [:]
    for (r, _) in found { if counts[r] == nil { order.append(r) }; counts[r, default: 0] += 1 }
    guard let ratio = order.maxBy({ counts[$0]! }) else { return nil }
    let perFoot = ratio * 12
    if let std = STANDARD_SCALES.first(where: { abs(perFoot - parseNumber($0)!) < 1e-9 }) { return "\(std)\" = 1'" }
    return found.first { $0.0 == ratio }!.1
}

private func isPerOneFoot(_ scale: String) -> Bool {
    let after = scale.firstIndex(of: "=").map { String(scale[scale.index(after: $0)...]) } ?? scale
    return parseLength(after, 12) == 12
}

/**
 * The plan's scale from each page's `findScale` in page order (lazy, so pages after a hit aren't read): the first
 * `= 1'` one, else the first of any kind. A cover or site sheet (`1" = 20'`) usually comes before the floor plan.
 */
func pickPlanScale<S: Sequence>(_ pageScales: S) -> String? where S.Element == String? {
    var first: String?
    for s in pageScales {
        guard let s else { continue }
        if isPerOneFoot(s) { return s }
        if first == nil { first = s }
    }
    return first
}

private let OBJ_STM = Re(#"/Type\s*/ObjStm"#)
private let STREAM = Re(#"stream\r?\n"#)
private let INFO_STRING = Re(#"/(?:R|Title|Subject|Keywords)\s*\(((?:\\.|[^\\)])*)\)"#)

/**
 * The scale saved in the PDF file itself: `/R (1/4 in = 1 ft)` in a `/Measure` dict (Bluebeam/Acrobat calibration),
 * or one written in the Info Title/Subject/Keywords. Looks in the raw file and in Flate-compressed object streams.
 * shortcut: UTF-16 strings, XMP and non-Flate object streams are skipped; add them if a real plan needs it.
 */
func scaleInPdf(_ bytes: Data) -> String? {
    // Latin-1 keeps one UTF-16 unit per byte, so string indices are byte offsets.
    guard let raw = String(data: bytes, encoding: .isoLatin1) else { return nil }
    var strings: [String] = []
    func collect(_ t: String) { strings += INFO_STRING.all(t).map { t.group($0, 1) } }
    collect(raw)
    for m in OBJ_STM.all(raw) { // one inflated object stream alive at a time
        guard let st = STREAM.first(raw, from: m.range.location + m.range.length - 1) else { continue }
        if let t = inflate(bytes, from: st.range.location + st.range.length) { collect(t) }
    }
    return findScale(strings.joined(separator: "\n"))
}

/** A zlib stream starting at `from`, or nil if it isn't one. Capped at 16 MB so a bad file can't run out of memory. */
private func inflate(_ bytes: Data, from: Int) -> String? {
    let start = bytes.startIndex + from
    guard from + 2 <= bytes.count, bytes[start] & 0x0F == 8, (UInt16(bytes[start]) << 8 | UInt16(bytes[start + 1])) % 31 == 0 else { return nil }
    let cap = 16 << 20
    var out = Data()
    let ok: Bool = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let src = raw.baseAddress!.advanced(by: from + 2).assumingMemoryBound(to: UInt8.self) // skip the zlib header: Compression reads raw deflate
        let dstSize = 65536
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return false }
        defer { compression_stream_destroy(streamPtr) }
        streamPtr.pointee.src_ptr = UnsafePointer(src)
        streamPtr.pointee.src_size = bytes.count - from - 2
        while out.count < cap {
            streamPtr.pointee.dst_ptr = dst
            streamPtr.pointee.dst_size = dstSize
            let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            out.append(dst, count: dstSize - streamPtr.pointee.dst_size)
            if status == COMPRESSION_STATUS_END { return true }
            if status == COMPRESSION_STATUS_ERROR { return false }
            if streamPtr.pointee.dst_size == dstSize && streamPtr.pointee.src_size == 0 { return true } // input ran out
        }
        return true
    }
    return ok ? String(data: out, encoding: .isoLatin1) : nil
}
