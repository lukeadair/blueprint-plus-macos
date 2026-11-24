import Foundation
import Testing
@testable import BlueprintPlus

// Ported from RoomsTest.kt and WallFinderTest.kt.

/** Every occurrence of `word` in `text`, by UTF-16 index. */
private func occurrences(_ text: String, _ word: String) -> [Int] {
    let t = Text16(text), w = Text16(word)
    var out: [Int] = []
    var i = t.indexOf(w)
    while i >= 0 { out.append(i); i = t.indexOf(w, i + 1) }
    return out
}

/** Fake text search: every occurrence in `text`, laid out on one line at 20pt per character, `height` tall. */
private func search(_ text: String, _ height: @escaping (Int) -> Double?) -> (String) -> [TextHit] {
    { word in
        occurrences(text, word).compactMap { i in
            height(i).map { h in TextHit(i, Double(i) * 20, 100, Double(i + word.utf16.count) * 20 - 5, 100 + h) }
        }
    }
}

private func names(_ l: [RoomLabel]) -> [String] { l.map(\.name).sorted() }
private func at(_ text: String, _ word: String) -> Int { occurrences(text, word)[0] }
private func lastAt(_ text: String, _ word: String) -> Int { occurrences(text, word).last! }

@Suite struct RoomsTests {
    @Test func shallInNotesDoesNotOutvoteTheLabelHeight() {
        // The search starts the match at the word's first letter: 4 notes saying "SHALL" look like 10pt "HALL" labels.
        let text = "KITCHEN BEDROOM DINING SHALL A SHALL B SHALL C SHALL"
        let generic = search(text) { _ in 14 }
        let labels = findRoomLabels(text) { w in
            w == "HALL" ? occurrences(text, "SHALL").map { TextHit($0, Double($0) * 20, 100, Double($0 + 5) * 20 - 5, 110) } : generic(w)
        }
        #expect(names(labels) == ["Bedroom", "Dining", "Kitchen"])
    }

    @Test func numberIsReadWhenSearchStartIsOffByTheLineBreak() {
        let text = "KITCHEN\r\nBATH 2\r\nDINING"
        let generic = search(text) { _ in 14 }
        let labels = findRoomLabels(text) { w in generic(w).map { var h = $0; if w == "BATH" { h.start -= 2 }; return h } }
        #expect(names(labels) == ["Bath 2", "Dining", "Kitchen"])
    }

    @Test func utilIsUtilityAndFoyerIsLeftOut() {
        let text = "UTIL. FOYER KITCHEN"
        #expect(names(findRoomLabels(text, search: search(text) { _ in 14 })) == ["Kitchen", "Utility"])
    }

    /** OCR words laid out left to right at 10pt, 60pt apart, one text line per row. */
    private func ocr(_ lines: String...) -> [OcrWord] {
        lines.enumerated().flatMap { row, l in
            l.split(separator: " ").enumerated().map { c, w in
                OcrWord(String(w), row, Double(c) * 60, Double(row) * 20, Double(c) * 60 + 50, Double(row) * 20 + 10)
            }
        }
    }

    @Test func ocrFindsRoomNamesAndNumbers() {
        let labels = ocrLabels(ocr("Kitchen Master Bath", "Bedrm 2 Dining"))
        #expect(names(labels) == ["Bedroom 2", "Dining", "Kitchen", "Master Bath"])
        #expect(near(labels.first { $0.name == "Kitchen" }!.x, 25, 0.01))
    }

    @Test func ocrKeepsOddlySizedLabelsAndDropsSentences() {
        #expect(ocrLabels([]).isEmpty)
        // BATH and LAUNDRY come back taller than their neighbors; a sentence naming a room is not a label.
        let words = ocr("Kitchen Dining", "Hall") + [OcrWord("Bath", 5, 0, 300, 30, 312), OcrWord("Laundry", 6, 0, 400, 50, 413)]
            + "Remove the old kitchen wall near the dining".split(separator: " ").enumerated().map { c, w in
                OcrWord(String(w), 9, Double(c) * 60, 500, Double(c) * 60 + 50, 508)
            }
        #expect(names(ocrLabels(words)) == ["Bath", "Dining", "Kitchen", "Laundry"])
    }

    @Test func findsLabelsOnARealFloorPlan() {
        // Real text from the test plan (labels are 10pt), plus a 7pt note that mentions a deck and a porch.
        let text = "GUEST ROOM BEDROOM CLOS CLOS DINING KITCHEN HALL BATH FRONT PORCH BACK PORCHDW N" +
            " REMOVE EXIST. DECK, FOUNDATION FOR NEW PORCH ADDITION TV CLOSED"
        let noteStart = at(text, "REMOVE")
        let labels = findRoomLabels(text, search: search(text) { $0 >= noteStart ? 7 : 10 })
        // Not: Room (inside Guest Room), Porch (inside Front Porch), Back Porch (glued to "DW"), Deck, the
        // note's Porch (7pt), or Closet from "CLOSED". Front Porch and the plain closets are found but dropped.
        #expect(names(labels) == ["Bath", "Bedroom", "Dining", "Guest Room", "Kitchen"])
    }

    @Test func verticalLabelIsMeasuredByItsShortSide() {
        // BATHROOM set sideways: its box is 10pt wide and 8 chars tall, like the 10pt labels beside it.
        let text = "KITCHEN BEDROOM BATHROOM"
        let i = at(text, "BATHROOM")
        let horizontal = search(text) { _ in 10 }
        let labels = findRoomLabels(text) { w in w == "BATHROOM" ? [TextHit(i, 300, 100, 310, 260)] : horizontal(w) }
        #expect(names(labels) == ["Bathroom", "Bedroom", "Kitchen"])
    }

    @Test func tinyVerticalTagsDoNotOutvoteTheLabels() {
        // Plan A: 14pt labels, a 5pt horizontal tag, and several 5pt-wide vertical "KITCHEN"/"PANTRY" tags.
        let text = "KITCHEN DINING PANTRY KITCHEN PANTRY KITCHEN KITCHEN"
        let boxes: [String: [TextHit]] = [
            "KITCHEN": [TextHit(0, 0, 0, 55, 14), TextHit(22, 300, 0, 320, 5), TextHit(30, 400, 0, 405, 20), TextHit(38, 500, 0, 505, 20)],
            "DINING": [TextHit(8, 100, 0, 144, 14)],
            "PANTRY": [TextHit(15, 200, 0, 251, 14), TextHit(30, 600, 0, 605, 19)],
        ]
        #expect(names(findRoomLabels(text) { boxes[$0] ?? [] }) == ["Dining", "Kitchen", "Pantry"])
    }

    @Test func noteNextToTheCounterIsNotARoom() {
        // Test plan A: "NEW BEDROOM ADDITION" note (8pt box on the phone) sits closer to a kitchen run
        // than the 10pt KITCHEN label does. It must not count as a room.
        let text = "GUEST ROOM BEDROOM DINING KITCHEN HALL BATH AS REQUIRED FOR NEW BEDROOM ADDITION"
        let noteStart = at(text, "AS REQUIRED")
        let labels = findRoomLabels(text, search: search(text) { $0 >= noteStart ? 8 : 10 })
        #expect(labels.filter { $0.name == "Bedroom" }.count == 1)
    }

    @Test func labelOnTwoLines() {
        // Test plan A on the phone: "FRONT PORCH" came back as one 24pt box (both lines); "FRONT" alone is 10pt.
        // Porches are dropped now, so this uses a kept two-word name.
        let text = "GUEST ROOM KITCHEN MASTER CLOSET HALL"
        let i = at(text, "MASTER CLOSET")
        let s = search(text) { _ in 10 }
        let labels = findRoomLabels(text) { word in
            s(word).map { h in var c = h; if h.start == i && word == "MASTER CLOSET" { c.bottom = h.top + 24 }; return c }
        }
        #expect(names(labels) == ["Guest Room", "Kitchen", "Master Closet"])
    }

    @Test func labelOnTwoLinesStoredOutOfOrder() {
        // Test plan C on the phone: "GREAT" over "ROOM", but the page text has ROOM first, so "GREAT ROOM" never matches.
        let text = "ROOM 18'x20'7 9' CLN HT GREAT KITCHEN"
        let boxes: [String: TextHit] = [
            "ROOM": TextHit(0, 501, 223, 520, 228),
            "GREAT": TextHit(at(text, "GREAT"), 501, 218, 521, 223),
            "KITCHEN": TextHit(at(text, "KITCHEN"), 300, 100, 330, 105),
        ]
        func find(_ b: [String: TextHit]) -> [String] { names(findRoomLabels(text) { b[$0].map { [$0] } ?? [] }) }
        #expect(find(boxes) == ["Great Room", "Kitchen"])
        // ROOM elsewhere on the page (not right under GREAT) isn't paired
        var apart = boxes; apart["ROOM"] = TextHit(0, 501, 260, 520, 265)
        #expect(find(apart) == ["Kitchen"])
        // Same line, stored out of order: "GREAT ROOM" on the page, "ROOM ... GREAT" in the text.
        var sideBySide = boxes; sideBySide["ROOM"] = TextHit(0, 524, 218, 543, 223)
        #expect(find(sideBySide) == ["Great Room", "Kitchen"])
        // ROOM before GREAT on the line isn't "GREAT ROOM"
        var reversed = boxes; reversed["ROOM"] = TextHit(0, 478, 218, 497, 223)
        #expect(find(reversed) == ["Kitchen"])
    }

    @Test func porchesAndPlainClosetsAreDropped() {
        let text = "CLOSET ; CL 1 ; GIRLS CLOSET ; BACK PORCH ; COVERED PATIO ; PATIO 2 ; GARAGE ; CARPORT ; STORAGE ; HALL ; HALLWAY ; HALL 2 ; M. CLOSET ; MASTER CLOSET ; MASTER CL ; MSTR CL 2 ; HIS CLOSET ; HERS CLOSET ;" +
            " PRIMARY CLOSET ; WIC ; KITCHEN"
        #expect(names(findRoomLabels(text, search: search(text) { _ in 10 })) ==
            ["Hers Closet", "His Closet", "Kitchen", "M. Closet", "Master Closet", "Master Closet", "Master Closet 2", "Primary Closet", "Walk-in Closet"])
    }

    @Test func numberedRooms() {
        let text = "BEDROOM 2 BEDROOM #3 BEDROOM"
        #expect(findRoomLabels(text, search: search(text) { _ in 10 }).map(\.name) == ["Bedroom 2", "Bedroom 3", "Bedroom"])
    }

    @Test func planAbbreviations() {
        // Labels from test plan B.
        let text = "M.BTH BEDRM 2 BTH 2 CL 1 LNDY/MUD PDR FLEX HALL 1 KITCHEN CL OF WALL"
        // the bare "CL" (centerline) is skipped; "CL 1" is a plain closet, dropped
        #expect(names(findRoomLabels(text, search: search(text) { _ in 10 })) == ["Bath 2", "Bedroom 2", "Flex", "Kitchen", "Laundry", "Master Bath", "Powder"])
    }

    @Test func roomSizesAreNotRoomNumbers() {
        // Test plan B's text puts each room's size right after its name.
        let text = "KITCHEN 10'x26'1 HALL 1 4'x4' BEDRM 2 12'x11' FLEX 12' x 10' PDR 5'x5'"
        #expect(names(findRoomLabels(text, search: search(text) { _ in 10 })) == ["Bedroom 2", "Flex", "Kitchen", "Powder"])
    }

    @Test func wordBeforeTheRoomWordKeepsRoomsApart() {
        // Plan A: GIRLS BATH, BOYS BATH and M. BATH were all "Bath". HALL BATH stays Hall + Bath; a note's
        // "NEW BATH" is just Bath.
        let text = "GIRLS BATH BOYS BATH M. BATH HALL BATH NEW BATH M. CLOSET"
        #expect(names(findRoomLabels(text, search: search(text) { _ in 10 })) == ["Bath", "Bath", "Boys Bath", "Girls Bath", "M. Bath", "M. Closet"])
    }

    @Test func wordBeforeOnAnotherLineIsNotPartOfTheName() {
        let text = "GIRLS BATH"
        let boxes: [String: TextHit] = ["BATH": TextHit(6, 300, 200, 340, 210), "GIRLS": TextHit(0, 300, 100, 350, 110)]
        #expect(findRoomLabels(text) { boxes[$0].map { [$0] } ?? [] }.map(\.name) == ["Bath"])
    }

    @Test func repeatedNamesAreNumbered() {
        let labels = [
            RoomLabel(name: "Storage", x: 500, y: 300), RoomLabel(name: "Storage", x: 100, y: 100), RoomLabel(name: "Bedroom", x: 0, y: 50),
            RoomLabel(name: "Bedroom 2", x: 0, y: 60), RoomLabel(name: "Bedroom", x: 0, y: 70), RoomLabel(name: "Bath", x: 0, y: 0), RoomLabel(name: "Kitchen", x: 0, y: 0),
        ]
        #expect(numberRepeats(labels, taken: ["Bath"]).map(\.name) == ["Storage 2", "Storage", "Bedroom", "Bedroom 2", "Bedroom 3", "Bath 2", "Kitchen"])
    }

    @Test func tagOverTheLabelDoesNotHideIt() {
        // Plan A on the phone: a 5pt "PANTRY 1" elevation tag box overlaps the 10pt PANTRY label.
        let text = "PANTRY 1 P KITCHEN PANTRY DINING"
        let boxes: [String: [TextHit]] = [
            "PANTRY": [TextHit(0, 871, 695, 891, 700), TextHit(lastAt(text, "PANTRY"), 877, 695, 928, 705)],
            "KITCHEN": [TextHit(at(text, "KITCHEN"), 901, 1011, 956, 1021)],
            "DINING": [TextHit(at(text, "DINING"), 943, 1176, 986, 1186)],
        ]
        #expect(names(findRoomLabels(text) { boxes[$0] ?? [] }) == ["Dining", "Kitchen", "Pantry"])
    }

    @Test func rotatedTagClippingTheLabelDoesNotHideIt() {
        // Plan A on the phone: a rotated "MASTER CLOSET 1" tag (5pt wide, 41pt tall) clips the M. CLOSET label.
        let text = "MASTER CLOSET 1 NURSERY M. BEDROOM M. CLOSET M. BATH"
        let i = at(text, "M. CLOSET") + 3
        let boxes: [String: [TextHit]] = [
            "MASTER CLOSET": [TextHit(0, 508, 854, 513, 895)],
            "CLOSET": [TextHit(7, 508, 854, 513, 874), TextHit(i, 495, 888, 546, 899)],
            "M.": [TextHit(i - 3, 478, 888, 491, 898)],
            "BATH": [TextHit(at(text, "BATH"), 640, 833, 670, 844)],
            "BEDROOM": [TextHit(at(text, "BEDROOM"), 275, 922, 330, 933)],
        ]
        #expect(names(findRoomLabels(text) { boxes[$0] ?? [] }) == ["Bath", "Bedroom", "M. Closet"]) // only the closet's "M." has a box here
    }

    @Test func labelInTheLastRowOfATableIsSkipped() {
        // Ruled rows every 11pt above the label, nothing below it.
        #expect(inTable(200, 200, 1) { x, y in (100...300).contains(x) && (150...205).contains(y) && (y - 150) % 11 == 0 })
    }

    @Test func labelInATableIsSkipped() {
        // 1 px per point. A schedule: ruled rows every 12pt, 200pt wide; and a plan room: two walls 100pt apart.
        #expect(inTable(200, 200, 1) { x, y in (100...300).contains(x) && (100...300).contains(y) && y % 12 == 0 })
        #expect(!inTable(200, 200, 1) { x, y in (100...300).contains(x) && (y == 150 || y == 250) })
    }

    @Test func tableOnABigSheet() {
        // FILE_7325's schedules: ruled rows every ~20.4pt; label mid-row, and in the last row above the bottom rule.
        let table = { (x: Int, y: Int) in (100...300).contains(x) && (100...310).contains(y) && (y - 100) % 21 == 0 }
        #expect(inTable(200, 215.5, 1, table))
        #expect(inTable(200, 299.5, 1, table))
    }

    @Test func labelPastEvenlySpacedLinesIsNotInATable() {
        // Stacked dimension strings outside a room: four lines 12pt apart, the label 34pt below the last one.
        #expect(!inTable(200, 220, 1) { x, y in (100...300).contains(x) && [150, 162, 174, 186].contains(y) })
    }

    @Test func areaTableHeadingsAreNotRooms() {
        // Heath plan's title block: the only real text on a page whose room names are drawn as lines.
        func n(_ text: String) -> [String] { names(findRoomLabels(text, search: search(text) { _ in 10 })) }
        #expect(n("LIVING AREAS SQ. FT. SF NOTES 1ST FLOOR PLAN") == [])
        #expect(n("LIVING AREA ; KITCHEN") == ["Kitchen", "Living"])
        #expect(n("GARAGE SQ. FT. ; BEDROOM") == ["Bedroom"])
    }

    @Test func nothingFound() {
        #expect(findRoomLabels("SITE PLAN NORTH", search: search("SITE PLAN NORTH") { _ in 10 }).isEmpty)
    }

    @Test func nearest() {
        let labels = [RoomLabel(name: "Kitchen", x: 100, y: 100), RoomLabel(name: "Bath", x: 300, y: 100)]
        #expect(nearestRoom(labels, 150, 120) == "Kitchen")
        #expect(nearestRoom(labels, 260, 300) == "Bath")
        #expect(nearestRoom([], 0, 0) == nil)
    }
}

/** A 200x200 "plan" at 4 px per real inch: walls need 12-48 px between line centers and 192 px of straight line. */
private final class Ink {
    var g: [[Bool]]
    let n: Int
    init(_ n: Int = 200) { self.n = n; g = Array(repeating: Array(repeating: false, count: n), count: n) }
    func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { for x in x0...x1 { for y in y0...y1 { g[x][y] = true } } }
    var walls: WallFinder { WallFinder(4) { [self] x, y in x >= 0 && x < n && y >= 0 && y < n && g[x][y] } }
}

@Suite struct WallFinderTests {
    @Test func doubleLineWall() {
        let ink = Ink()
        ink.fill(50, 0, 52, 199); ink.fill(64, 0, 66, 199) // two 3px lines, 14px (3.5") apart center to center
        let w = ink.walls
        #expect(w.crosses(20, 100, 100, 90))
        #expect(w.crosses(20, 100, 100, 40)) // at an angle
        #expect(!w.crosses(20, 100, 40, 30)) // stays on one side
    }

    @Test func filledWall() {
        let ink = Ink()
        ink.fill(50, 0, 63, 199) // 14px = 3.5" solid
        #expect(ink.walls.crosses(20, 100, 100, 100))
    }

    @Test func counterEdgeAndCooktopAreNotWalls() {
        let ink = Ink()
        ink.fill(50, 0, 51, 199) // one long line: a counter edge
        for x in 0..<200 { for y in 0..<200 where hypot(Double(x) - 90, Double(y) - 100) <= 10 { ink.g[x][y] = true } } // burner
        ink.fill(110, 95, 111, 105); ink.fill(118, 95, 119, 105) // short parallel strokes: lettering
        #expect(!ink.walls.crosses(20, 100, 150, 100))
    }

    @Test func linesCloserThanAWallAreNotOne() {
        let ink = Ink()
        ink.fill(50, 0, 51, 199); ink.fill(60, 0, 61, 199) // countertop edge + cabinet face, 2.5" apart
        #expect(!ink.walls.crosses(20, 100, 100, 100))
    }

    @Test func sightlineAlongALineIsNotBlocked() {
        let ink = Ink()
        ink.fill(0, 99, 199, 101)
        #expect(!ink.walls.crosses(10, 100, 190, 100))
    }

    @Test func stopsAtTheLabelText() {
        let ink = Ink()
        ink.fill(150, 0, 152, 199); ink.fill(164, 0, 166, 199) // a wall right where the label's text box is
        #expect(!ink.walls.crosses(20, 100, 158, 100, halfW: 12, halfH: 5))
    }

    @Test func shortParallelEdgesAreAFixtureNotAWall() {
        let ink = Ink()
        ink.fill(50, 40, 52, 184); ink.fill(74, 40, 76, 184) // 36" long, 6" apart: a cooktop's sides
        ink.fill(80, 0, 81, 199) // and the counter edge beside it
        ink.fill(50, 40, 76, 41); ink.fill(50, 183, 76, 184) // its front and back, crossing them
        #expect(!ink.walls.crosses(20, 100, 120, 70))
    }

    /**
     * A 400x400 plan at 4 px per inch with a 26" wall stub beside a door (Building Plan 2's bath): faces at y 200 and
     * 214 run right from a through-wall (faces x 100 and 114, the near one open where the stub joins) to a jamb at x 219.
     */
    private func stubPlan(throughWall: Bool = true, closedMouth: Bool = false) -> WallFinder {
        let ink = Ink(400)
        ink.fill(114, 200, 219, 201); ink.fill(114, 214, 219, 215) // the stub's faces
        ink.fill(218, 200, 219, 215) // the jamb at the door
        if throughWall { ink.fill(100, 0, 101, 399); ink.fill(114, 0, 115, 201); ink.fill(114, 214, 115, 399) }
        if closedMouth { ink.fill(114, 200, 115, 215) }
        return ink.walls
    }

    @Test func shortWallBesideADoor() { #expect(stubPlan().crosses(170, 150, 170, 260)) }

    @Test func shortBoxIsAFixture() { #expect(!stubPlan(closedMouth: true).crosses(170, 150, 170, 260)) }

    @Test func shortDoubleOutlineJoiningNoWallIsAFixture() { #expect(!stubPlan(throughWall: false).crosses(170, 150, 170, 260)) } // a washer's outline

    /**
     * A 400x400 plan with a wall (faces y 200 and 214) holding a 60" window: the faces stop at jambs (x 100 and 340),
     * one glazing line runs between them down the wall's middle. `gap` moves where the faces resume past the jambs.
     */
    private func windowPlan(gap: Int = 0) -> WallFinder {
        let ink = Ink(400)
        ink.fill(0, 200, 99 - gap, 201); ink.fill(0, 213, 99 - gap, 214)
        ink.fill(341 + gap, 200, 399, 201); ink.fill(341 + gap, 213, 399, 214)
        ink.fill(100, 200, 101, 214); ink.fill(339, 200, 340, 214) // jambs
        ink.fill(100, 206, 340, 208) // glass
        return ink.walls
    }

    @Test func windowInAWall() { #expect(windowPlan().crosses(220, 150, 220, 260)) } // Plan B: kitchen leaked out its windows

    @Test func lineEndingShortOfAWallIsNotAWindow() { #expect(!windowPlan(gap: 20).crosses(220, 150, 220, 260)) } // a vanity edge

    /**
     * A wall (faces x 100 and 114) whose near face is broken by two walls joining it from the right (faces y 100/114
     * and 230/244), leaving a 28" piece (Plan B: the pantry's wall at the water heater closet). `gap` starts the
     * joining walls that far off the piece.
     */
    private func joinedWallPlan(gap: Int = 0) -> WallFinder {
        let ink = Ink(400)
        ink.fill(100, 0, 101, 399)
        ink.fill(114, 0, 115, 101); ink.fill(114, 116, 115, 229); ink.fill(114, 244, 115, 399)
        for y in [100, 114, 230, 244] { ink.fill(114 + gap, y, 399, y + 1) }
        return ink.walls
    }

    @Test func wallFaceBrokenByJoiningWalls() { #expect(joinedWallPlan().crosses(50, 170, 200, 170)) }

    @Test func fixtureEdgeShortOfAWallIsNotAFace() { #expect(!joinedWallPlan(gap: 18).crosses(50, 170, 200, 170)) } // a tub's rim

    @Test func wallFaceTouchingAFixture() {
        let ink = Ink()
        ink.fill(50, 0, 52, 199); ink.fill(64, 0, 66, 199)
        ink.fill(40, 95, 50, 105) // a faucet handle against the first face: one dark stretch on the ray
        #expect(ink.walls.crosses(20, 100, 100, 100))
    }

    @Test func picksTheNearestLabelNotBehindAWall() {
        let ink = Ink()
        ink.fill(50, 0, 52, 199); ink.fill(64, 0, 66, 199)
        let walls = ink.walls
        let behindWall = RoomLabel(name: "Hall", x: 80, y: 100) // 50 away, other side of the wall
        let sameRoom = RoomLabel(name: "Kitchen", x: 30, y: 170) // 70 away
        #expect(pickRoom([behindWall, sameRoom], 30, 100, 1, walls) == "Kitchen")
        #expect(pickRoom([behindWall, sameRoom], 30, 100, 1, nil) == "Hall") // no wall check: nearest
        #expect(pickRoom([behindWall], 30, 100, 1, walls) == "Hall") // everything blocked: nearest
    }
}
