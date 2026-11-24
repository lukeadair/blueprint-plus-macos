import Foundation
import Testing
@testable import BlueprintPlus

// Ported from JobTest.kt and ExportTest.kt, plus a load of a job file saved by the Android app.

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-4) -> Bool { abs(a - b) <= tol }

private let run = Run(page: 1, a: Offset(10, 20), b: Offset(154, 20), ppi: 144) // 1" on paper
// An L: 144 px right (1" on paper), then 144 px down (1"). At 1/4" = 1' that is 48" + 48".
private let corner: Run = { var r = run; r.extra = [Offset(154, 164)]; return r }()

private func roundTrip(_ j: Job) throws -> Job { try jobFromJson(try jobToJson(j)) }
private func with(_ r: Run, page: Int? = nil, room: String?? = nil, manual: Bool? = nil) -> Run {
    var c = r
    if let page { c.page = page }
    if let room { c.room = room }
    if let manual { c.roomManual = manual }
    return c
}

@Suite struct JobTests {
    @Test func jsonRoundTrips() throws {
        let job = Job(id: "id1", name: "Smith \"kitchen\"", scale: "1/8\" = 1'", page: 2, updated: 123, created: 100,
                      runs: [run, with(run, page: 0, room: "Kitchen"), with(run, room: "", manual: true)], rooms: ["Pantry", "Office"])
        #expect(try roundTrip(job) == job)
    }

    @Test func distanceToRun() {
        #expect(near(run.distanceTo(Offset(82, 30)), 10)) // beside the middle
        #expect(near(run.distanceTo(Offset(0, 20)), 10)) // past the start: to the endpoint, not the line
        #expect(near(Run(page: 0, a: Offset(1, 1), b: Offset(1, 1), ppi: 72).distanceTo(Offset(4, 5)), 5)) // zero-length
    }

    @Test func midPointIsInPdfPoints() {
        #expect(run.midPoints() == Offset(41, 10)) // (82, 20) px at 144 ppi = 2x points
    }

    @Test func renameAndMergeRooms() {
        let job = Job(id: "i", name: "n", runs: [with(run, room: "Bath"), with(run, room: "Kitchen"), with(run, room: "Bath")], rooms: ["Bath", "Pantry"])
        let renamed = job.renameRoom("Bath", "Master Bath")
        #expect(renamed.runs.map(\.room) == ["Master Bath", "Kitchen", "Master Bath"])
        #expect(renamed.runs.map(\.roomManual) == [true, false, true]) // only the moved runs
        #expect(renamed.rooms == ["Master Bath", "Pantry"])

        let merged = renamed.renameRoom("Master Bath", "Kitchen")
        #expect(merged.runs.map(\.room) == ["Kitchen", "Kitchen", "Kitchen"])
        #expect(merged.rooms == ["Kitchen", "Pantry"]) // no duplicate, old name gone
    }

    @Test func olderSavesWithoutCreatedUseUpdated() throws {
        let old = #"{"id":"i","name":"n","scale":"1/4\" = 1'","page":0,"updated":500,"runs":[],"rooms":[]}"#
        #expect(try jobFromJson(Data(old.utf8)).created == 500)
        #expect(try jobFromJson(Data(old.utf8)).scaleSet == true)
        #expect(try roundTrip(Job(id: "i", name: "n", scaleSet: false)).scaleSet == false)
        #expect(try jobFromJson(Data(old.utf8)).foundScale == nil)
        #expect(try roundTrip(Job(id: "i", name: "n", foundScale: "1/8\" = 1'")).foundScale == "1/8\" = 1'")
    }

    @Test func totals() {
        #expect(near(Job(id: "i", name: "n", scale: "1/4\" = 1'", runs: [run, run]).totalInches()!, 96, 1e-9))
        #expect(Job(id: "i", name: "n", scale: "nonsense", runs: [run]).totalInches() == nil)
    }

    @Test func chainedRunSumsSegments() {
        #expect(near(corner.inches(parseScale("1/4\" = 1'")!), 96, 1e-9))
        #expect(near(corner.distanceTo(Offset(164, 100)), 10)) // beside the second segment
        #expect(corner.points().last == Offset(154, 164))
    }

    @Test func chainedRunRoundTripsAndOldSavesLoad() throws {
        let job = Job(id: "i", name: "n", runs: [corner, run])
        #expect(try roundTrip(job) == job)
        #expect(try roundTrip(job).runs[1].extra.isEmpty)
        #expect(!String(decoding: try jobToJson(Job(id: "i", name: "n", runs: [run])), as: UTF8.self).contains("pts")) // no "pts" key when not chained
    }

    @Test func withPointMovesOneNode() {
        #expect(corner.withPoint(0, Offset(0, 0)).a == Offset(0, 0))
        #expect(corner.withPoint(1, Offset(0, 0)).b == Offset(0, 0))
        var moved = corner; moved.extra = [Offset(1, 2)]
        #expect(corner.withPoint(2, Offset(1, 2)) == moved)
        #expect(corner.withPoint(0, Offset(0, 0)).points().last == Offset(154, 164)) // others untouched
    }

    @Test func insertAndRemoveNode() {
        let r = Run(page: 0, a: Offset(0, 0), b: Offset(100, 0), ppi: 72)
        let grown = r.withInserted(Offset(30, 9))
        #expect(grown.points().count == 3)
        #expect(near(grown.points()[1].x, 30, 0.01))
        #expect(near(grown.points()[1].y, 0, 0.01))
        #expect(grown.withoutPoint(1) == r)
        #expect(r.withoutPoint(0) == r) // keeps two points
        #expect(r.withInserted(Offset(130, 5)) == r) // past the end: would duplicate the endpoint
        #expect(r.withInserted(Offset(5, 5), minGap: 8) == r) // too close to a node
    }

    @Test func loadsAJobSavedByTheAndroidApp() throws {
        // Written by Android's Job.toJson (org.json): floats widened to doubles, optional keys left out.
        let android = #"""
        {"id":"7d1","name":"Smith Kitchen","scale":"1\/4\" = 1'","page":0,"updated":1730000000000,"created":1729000000000,
         "runs":[{"page":0,"ax":10,"ay":20,"bx":154,"by":20,"ppi":144,"room":"Kitchen"},
                 {"page":0,"ax":10.5,"ay":20.25,"bx":154,"by":20,"ppi":144,"roomManual":true,"room":"","pts":[154,164]}],
         "rooms":["Pantry"],"boundaries":[{"name":"Kitchen","page":0,"pts":[0,0,100,0,100,50,0,50]}],
         "seededPages":[0],"editedPages":[],"scaleSet":true,"foundScale":"1\/4\" = 1'"}
        """#
        let job = try jobFromJson(Data(android.utf8))
        #expect(job.runs.count == 2 && job.runs[1].extra == [Offset(154, 164)] && job.runs[1].roomManual)
        #expect(job.boundaries[0].points.count == 4)
        #expect(job.seededPages == [0] && job.foundScale == "1/4\" = 1'")
        #expect(formatFeetInches(job.runs[0].inches(parseScale(job.scale)!)) == "4' 0\"")
    }
}

/** Reads a stored (uncompressed) zip back into path -> text. */
private func unzip(_ d: Data) -> [String: String] {
    var out: [String: String] = [:]
    var i = d.startIndex
    func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    while i + 30 <= d.endIndex, u32(i) == 0x04034b50 {
        let size = u32(i + 18), nameLen = u16(i + 26), extraLen = u16(i + 28)
        let name = String(decoding: d[(i + 30)..<(i + 30 + nameLen)], as: UTF8.self)
        let start = i + 30 + nameLen + extraLen
        let body = d[start..<(start + size)]
        #expect(crc32(Data(body)) == UInt32(u32(i + 14)))
        out[name] = String(decoding: body, as: UTF8.self)
        i = start + size
    }
    return out
}

@Suite struct ExportTests {
    // 144 ppi, 1" on paper = 4' at 1/4" = 1'
    private func run(_ room: String?, _ inches: Double = 1) -> Run { Run(page: 0, a: Offset(0, 0), b: Offset(144 * inches, 0), ppi: 144, room: room) }
    private let ratio = 1.0 / 48

    @Test func roomFeetInListOrder() {
        let job = Job(id: "i", name: "n", runs: [run("kitchen"), run(""), run("Bath", 2), run("kitchen", 0.5)], rooms: ["Pantry"])
        let feet = roomFeet(job, ratio)
        #expect(feet.map(\.0) == ["Bath", "kitchen", "Pantry", ""])
        #expect(zip(feet.map(\.1), [8.0, 6, 0, 4]).allSatisfy { near($0, $1, 1e-9) })
    }

    @Test func xlsxHasFormulasAndEscapes() {
        let job = Job(id: "i", name: "Smith & <Sons>", runs: [run("Bath"), run("Kitchen")])
        let parts = unzip(quoteXlsx(job, ratio))
        #expect(Set(parts.keys) == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml", "xl/worksheets/sheet1.xml"])
        let sheet = parts["xl/worksheets/sheet1.xml"]!
        #expect(sheet.contains("<f>B6*IF(C6=&quot;&quot;,$B$3,C6)</f>"))
        #expect(sheet.contains("<f>B7*IF(C7=&quot;&quot;,$B$3,C7)</f>"))
        #expect(sheet.contains(#"<c r="B8" s="5"><f>SUM(B6:B7)</f>"#))
        #expect(sheet.contains("<f>SUM(D6:D7)</f>"))
        #expect(sheet.contains("<v>4.0</v>"))
        #expect(sheet.contains("Smith &amp; &lt;Sons&gt;"))
        #expect(parts["xl/workbook.xml"]!.contains(#"name="Smith &amp; &lt;Sons&gt;""#))
    }
}

@Test func roomColorsSurviveJsonAndFollowRenames() throws {
    var job = Job(id: "j", name: "J")
    job.rooms = ["Bath", "Kitchen"]
    job.roomColors = ["Bath": 0x3949AB, "Kitchen": 0x43A047]
    let back = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
    #expect(back.roomColors == job.roomColors)
    #expect(job.renameRoom("Bath", "Master Bath").roomColors == ["Master Bath": 0x3949AB, "Kitchen": 0x43A047])
    #expect(job.renameRoom("Bath", "Kitchen").roomColors == ["Kitchen": 0x43A047]) // a merge keeps the target's color
    let old = try JSONDecoder().decode(Job.self, from: #"{"id":"j","name":"J","scale":"1/4\" = 1'","runs":[]}"#.data(using: .utf8)!)
    #expect(old.roomColors.isEmpty)
}
