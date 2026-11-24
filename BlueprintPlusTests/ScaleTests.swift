import Foundation
import Testing
@testable import BlueprintPlus

// Ported from the Android app's ScaleTest.kt: same cases, same expectations.

private func eq(_ expected: Double, _ actual: Double?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual != nil && abs(expected - actual!) < 1e-9, "\(String(describing: actual)) != \(expected)", sourceLocation: sourceLocation)
}

@Suite struct ScaleTests {
    @Test func lengths() {
        eq(0.25, parseLength("1/4\"", 1))
        eq(1.5, parseLength("1 1/2\"", 1))
        eq(150, parseLength("12' 6\"", 1))
        eq(18, parseLength("1'-6\"", 1))
        eq(12, parseLength("1'-0\"", 1))
        eq(42, parseLength("3.5'", 1))
        eq(24, parseLength("2", 12))
        eq(30, parseLength("2 ft 6 in", 1))
        eq(12, parseLength("1’", 1))
    }

    @Test func badLengths() {
        #expect(parseLength("", 1) == nil)
        #expect(parseLength("abc", 1) == nil)
        #expect(parseLength("1/0\"", 1) == nil)
        #expect(parseLength("2 3", 1) == nil) // two bare numbers is ambiguous
    }

    @Test func scales() {
        eq(1.0 / 48, parseScale("1/4\" = 1'"))
        eq(1.0 / 48, parseScale("1/4\"=1'-0\""))
        eq(1.0 / 96, parseScale("1/8 = 1"))
        eq(1.0 / 16, parseScale("3/4\" = 1'"))
        #expect(parseScale("1/4\"") == nil)
        #expect(parseScale("0 = 1'") == nil)
    }

    @Test func calibrationRoundTrips() {
        // 2" on paper measured as 8' -> quarter-inch scale
        eq(1.0 / 48, parseScale(calibratedScale(2, 96)))
    }

    @Test func calibrationSnapsToStandardScales() {
        #expect(calibratedScale(2 * 1.015, 96) == "1/4\" = 1'") // 1.5% tap error
        #expect(calibratedScale(2 * 0.985, 96) == "1/4\" = 1'")
        #expect(calibratedScale(1.5, 96) == "3/16\" = 1'")
        #expect(calibratedScale(12, 96) == "1 1/2\" = 1'")
        eq(1.0 / 8, parseScale(calibratedScale(12, 96)))
        // 5% off (a reduced print) keeps its own scale
        #expect(calibratedScale(2.1, 96) == "0.2625\" = 1'")
    }

    @Test func measuring() {
        // 1" on a 144 ppi render at 1/4" scale = 4'
        eq(48, realInches(144, 144, 1.0 / 48))
        #expect(formatFeetInches(150) == "12' 6\"")
        #expect(formatFeetInches(11.6) == "1' 0\"")
    }

    @Test func findsScaleInPlanText() {
        #expect(findScale("FLOOR PLAN\nSCALE: 1/4\" = 1'-0\"") == "1/4\" = 1'")
        #expect(findScale("SCALE 1/8\"=1'") == "1/8\" = 1'")
        #expect(findScale("3/16 in = 1 ft") == "3/16\" = 1'")
        #expect(findScale("DETAIL 1 1/2\" = 1'-0\"") == "1 1/2\" = 1'")
        #expect(findScale("SCALE: 1/4” = 1’-0”") == "1/4\" = 1'")
        #expect(findScale("SITE PLAN 1\" = 20'") == "1\" = 20'") // not architectural: kept as written, exact
        #expect(findScale("SCALE: AS NOTED") == nil)
        #expect(findScale("NTS  2 = 3  X=4'") == nil)
        // main plan scale outnumbers a detail callout
        #expect(findScale("1/2\" = 1'-0\" ... 1/4\" = 1'-0\" ... 1/4\"=1'") == "1/4\" = 1'")
        // the inches tail doesn't swallow the next text
        #expect(findScale("SCALE: 1/4\" = 1'\n36\" BASE") == "1/4\" = 1'")
        #expect(findScale("SCALE: 1/4\" = 1' 6\" UPPERS") == "1/4\" = 1'")
        #expect(findScale("SCALE: 1/4\" = 1' - 0\"") == "1/4\" = 1'")
        // unit conversions aren't plan scales
        #expect(findScale("30\" = 2'-6\" ... 30\" = 2'-6\" ... SCALE 1/4\" = 1'") == "1/4\" = 1'")
        #expect(findScale("12\" = 1'-0\"") == nil)
        #expect(findScale("DETAIL 3\" = 1'-0\"") == "3\" = 1'")
        // `= 1'` beats a more common other form
        #expect(findScale("1\" = 20' ... 1\" = 20' ... 1/8\" = 1'-0\"") == "1/8\" = 1'")
        #expect(findScale("1\" = 20' ... 1\" = 20'") == "1\" = 20'")
    }

    @Test func findsCaptionedScale() { // Plan A: the title block was a template left at 1/4", the plan says 3/16"
        let page = "First Level Floor Plan\nScale - 3/16\" = 1'\n1/4\" =1'\nSCALE:"
        #expect(findScale(page, captioned: true) == "3/16\" = 1'")
        #expect(findScale("Second Level Electrical PlaScale 3/16\" = 1'", captioned: true) == "3/16\" = 1'")
        #expect(findScale("SCALE: 1/4\" = 1'-0\"", captioned: true) == "1/4\" = 1'")
        #expect(findScale("SHEET:\n1/4\" =1'\nSCALE:", captioned: true) == nil) // the caption must be on its line
        #expect(findScale("SCALE:\n1/4\" =1'", captioned: true) == nil)
    }

    @Test func picksPlanScaleAcrossPages() {
        // site sheet first: the floor plan's `= 1'` scale wins
        #expect(pickPlanScale([nil, "1\" = 20'", "1/4\" = 1'", "1/2\" = 1'"]) == "1/4\" = 1'")
        #expect(pickPlanScale(["1\" = 20'", nil, "1\" = 10'"]) == "1\" = 20'")
        #expect(pickPlanScale([String?.none, nil]) == nil)
        // stops at the first hit: later pages aren't read
        var read = 0
        let lazy = [String?("1/8\" = 1'"), nil].lazy.map { s -> String? in read += 1; return s }
        #expect(pickPlanScale(lazy) == "1/8\" = 1'")
        #expect(read == 1)
    }

    @Test func findsScaleInPdfData() throws {
        let plain = "%PDF-1.7\n5 0 obj << /Type /Measure /Subtype /RL /R (1/4 in = 1 ft-0 in) >> endobj".data(using: .isoLatin1)!
        #expect(scaleInPdf(plain) == "1/4\" = 1'")
        let dict = "<< /Type /Measure /Subtype /RL /R (1/8 in = 1 ft) >>".data(using: .isoLatin1)!
        // zlib = 2-byte header + raw deflate (+ adler32, which the reader doesn't need)
        let z = Data([0x78, 0x9C]) + (try (dict as NSData).compressed(using: .zlib) as Data) + Data([0, 0, 0, 0])
        let packed = "%PDF-1.7\n7 0 obj << /Type /ObjStm /N 1 /First 4 /Filter /FlateDecode /Length \(z.count) >>\nstream\n".data(using: .isoLatin1)!
            + z + "\nendstream endobj".data(using: .isoLatin1)!
        #expect(scaleInPdf(packed) == "1/8\" = 1'")
        #expect(scaleInPdf("%PDF-1.7\n/Title (Smith Kitchen)".data(using: .isoLatin1)!) == nil)
    }
}
