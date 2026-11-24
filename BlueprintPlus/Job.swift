import Foundation

// Pure Swift: the job model and its JSON, in the same format as the Android app's Job.kt so a job file
// (plus its PDF) moves between the two.

/**
 * A measured run: a polyline of `a`, `b` and any `extra` points (a corner turned), in page-bitmap pixels, on a page rendered at `ppi`.
 * `room`: nil = not assigned yet; "" = Unassigned. `roomManual`: the user chose the room (by dragging), so the
 * app never changes it; otherwise the app picks it from the plan's labels and re-picks when the job reopens.
 */
struct Run: Hashable, Sendable {
    var page: Int
    var a: Offset
    var b: Offset
    var ppi: Double
    var room: String? = nil
    var roomManual = false
    var extra: [Offset] = []

    func points() -> [Offset] { [a, b] + extra }

    /** This run with the point at `i` (0 = `a`, 1 = `b`, then `extra`) moved to `p`. */
    func withPoint(_ i: Int, _ p: Offset) -> Run {
        var r = self
        switch i {
        case 0: r.a = p
        case 1: r.b = p
        default: r.extra[i - 2] = p
        }
        return r
    }

    private func withPoints(_ l: [Offset]) -> Run {
        var r = self
        r.a = l[0]; r.b = l[1]; r.extra = Array(l.dropFirst(2))
        return r
    }

    /** This run with a new point on the segment nearest `p`, at the spot on it closest to `p`; unchanged if that is within `minGap` of an existing point. */
    func withInserted(_ p: Offset, minGap: Double = 0) -> Run {
        let pts = points()
        let k = Array(0..<pts.count - 1).minBy { Run(page: page, a: pts[$0], b: pts[$0 + 1], ppi: ppi).distanceTo(p) }!
        let ab = pts[k + 1] - pts[k]
        let len2 = ab.x * ab.x + ab.y * ab.y
        let t = len2 == 0 ? 0 : coerce(((p.x - pts[k].x) * ab.x + (p.y - pts[k].y) * ab.y) / len2, 0, 1)
        let q = pts[k] + ab * t
        if (q - pts[k]).distance() <= minGap || (q - pts[k + 1]).distance() <= minGap { return self }
        var l = pts
        l.insert(q, at: k + 1)
        return withPoints(l)
    }

    /** This run without point `i`; a run keeps at least two points. */
    func withoutPoint(_ i: Int) -> Run {
        let pts = points()
        if pts.count <= 2 { return self }
        var l = pts
        l.remove(at: i)
        return withPoints(l)
    }

    private func segments() -> [(Offset, Offset)] { points().pairs() }

    /** Midpoint of the longest segment, in page pixels: where the run's label sits and its room is picked. */
    func midpoint() -> Offset {
        let (p, q) = segments().maxBy { ($0.1 - $0.0).distance() }!
        return (p + q) / 2
    }

    /** Midpoint in PDF points (1/72"), the units room labels come in. */
    func midPoints() -> Offset { midpoint() / ppi * 72 }

    func inches(_ ratio: Double) -> Double {
        realInches(segments().reduce(0) { $0 + ($1.1 - $1.0).distance() }, ppi, ratio)
    }

    /** Distance from `p` to the nearest segment of this run (not the infinite line), in page pixels. */
    func distanceTo(_ p: Offset) -> Double {
        segments().map { a, b in distToSegment(p, a, b) }.min()!
    }
}

func distToSegment(_ p: Offset, _ a: Offset, _ b: Offset) -> Double {
    let ab = b - a
    let len2 = ab.x * ab.x + ab.y * ab.y
    let t = len2 == 0 ? 0 : coerce(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0, 1)
    return (p - (a + ab * t)).distance()
}

struct Job: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var scale = "1/4\" = 1'"
    var page = 0
    var updated: Int64 = 0
    var created: Int64 = 0
    var runs: [Run] = []
    /** Rooms the user added by hand; they show in the run list even with no runs in them. */
    var rooms: [String] = []
    /** Room borders. Runs on a page in `seededPages` get their room from these (see `reassignRooms`). */
    var boundaries: [RoomBoundary] = []
    /** Pages whose borders were auto-drawn from the room labels; redone only by Redetect or, if not edited, a new scale. */
    var seededPages: Set<Int> = []
    /** Pages whose borders the user changed (moved, added, deleted); a scale change leaves these alone. */
    var editedPages: Set<Int> = []
    /** The user confirmed the scale (Save in Job Config, or a calibration). Rooms aren't seeded before that. */
    var scaleSet = true
    /** The scale read from the plan when the job was made (nil = none found); Job Config marks it "found in plan". */
    var foundScale: String? = nil
    /** Colors the user picked for rooms (0xRRGGBB); others get one from their name. Mac only: Android ignores the key. */
    var roomColors: [String: UInt32] = [:]

    /**
     * Room `old` renamed to `to` (an existing room's name merges the two). Its runs move with it, marked
     * manual so re-picking doesn't put them back under the plan's label.
     */
    func renameRoom(_ old: String, _ to: String) -> Job {
        var j = self
        j.runs = runs.map { var r = $0; if r.room == old { r.room = to; r.roomManual = true }; return r }
        j.rooms = (rooms.map { $0 == old ? to : $0 } + [to]).distinct()
        j.boundaries = boundaries.map { var b = $0; if b.name == old { b.name = to }; return b }
        j.editedPages = editedPages.union(boundaries.filter { $0.name == old }.map(\.page)) // a scale change must not undo it
        if let c = j.roomColors.removeValue(forKey: old), j.roomColors[to] == nil { j.roomColors[to] = c } // a merge keeps the target's
        return j
    }

    /** Nil when the scale text doesn't parse. */
    func totalInches() -> Double? { parseScale(scale).map { r in runs.reduce(0) { $0 + $1.inches(r) } } }
}

extension Array where Element: Hashable {
    /** Kotlin's distinct(): first occurrences, in order. */
    func distinct() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

/** How rooms are listed (run list, export): alphabetical so they don't jump when a run moves, Unassigned ("") last. */
func roomOrder(_ a: String, _ b: String) -> Bool {
    if a.isEmpty != b.isEmpty { return !a.isEmpty }
    return a.lowercased() < b.lowercased()
}

// MARK: - JSON (same keys as Android's toJson / jobFromJson)

extension Job: Codable {
    private enum K: String, CodingKey {
        case id, name, scale, page, updated, created, runs, rooms, boundaries, seededPages, editedPages, scaleSet, foundScale, roomColors
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        scale = try c.decode(String.self, forKey: .scale)
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        updated = try c.decodeIfPresent(Int64.self, forKey: .updated) ?? 0
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? updated // saves before this field: best guess
        runs = try c.decode([Run].self, forKey: .runs)
        rooms = try c.decodeIfPresent([String].self, forKey: .rooms) ?? []
        boundaries = try c.decodeIfPresent([RoomBoundary].self, forKey: .boundaries) ?? []
        seededPages = Set(try c.decodeIfPresent([Int].self, forKey: .seededPages) ?? [])
        editedPages = Set(try c.decodeIfPresent([Int].self, forKey: .editedPages) ?? [])
        scaleSet = try c.decodeIfPresent(Bool.self, forKey: .scaleSet) ?? true // older saves: already in use, don't prompt
        foundScale = try c.decodeIfPresent(String.self, forKey: .foundScale)
        roomColors = try c.decodeIfPresent([String: UInt32].self, forKey: .roomColors) ?? [:]
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(scale, forKey: .scale)
        try c.encode(page, forKey: .page); try c.encode(updated, forKey: .updated); try c.encode(created, forKey: .created)
        try c.encode(runs, forKey: .runs); try c.encode(rooms, forKey: .rooms); try c.encode(boundaries, forKey: .boundaries)
        try c.encode(seededPages.sorted(), forKey: .seededPages); try c.encode(editedPages.sorted(), forKey: .editedPages)
        try c.encode(scaleSet, forKey: .scaleSet)
        try c.encodeIfPresent(foundScale, forKey: .foundScale)
        if !roomColors.isEmpty { try c.encode(roomColors, forKey: .roomColors) }
    }
}

extension Run: Codable {
    private enum K: String, CodingKey { case page, ax, ay, bx, by, ppi, room, roomManual, pts }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        page = try c.decode(Int.self, forKey: .page)
        a = Offset(try c.decode(Double.self, forKey: .ax), try c.decode(Double.self, forKey: .ay))
        b = Offset(try c.decode(Double.self, forKey: .bx), try c.decode(Double.self, forKey: .by))
        ppi = try c.decode(Double.self, forKey: .ppi)
        room = try c.decodeIfPresent(String.self, forKey: .room)
        roomManual = try c.decodeIfPresent(Bool.self, forKey: .roomManual) ?? false
        extra = offsets(try c.decodeIfPresent([Double].self, forKey: .pts) ?? [])
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(page, forKey: .page)
        try c.encode(a.x, forKey: .ax); try c.encode(a.y, forKey: .ay)
        try c.encode(b.x, forKey: .bx); try c.encode(b.y, forKey: .by)
        try c.encode(ppi, forKey: .ppi)
        try c.encodeIfPresent(room, forKey: .room)
        if roomManual { try c.encode(true, forKey: .roomManual) }
        if !extra.isEmpty { try c.encode(extra.flatMap { [$0.x, $0.y] }, forKey: .pts) }
    }
}

extension RoomBoundary: Codable {
    private enum K: String, CodingKey { case name, page, pts }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        self.init(name: try c.decode(String.self, forKey: .name), page: try c.decode(Int.self, forKey: .page),
                  points: offsets(try c.decode([Double].self, forKey: .pts)))
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(name, forKey: .name); try c.encode(page, forKey: .page)
        try c.encode(points.flatMap { [$0.x, $0.y] }, forKey: .pts)
    }
}

private func offsets(_ flat: [Double]) -> [Offset] { (0..<flat.count / 2).map { Offset(flat[2 * $0], flat[2 * $0 + 1]) } }

func jobToJson(_ job: Job) throws -> Data { try JSONEncoder().encode(job) }
func jobFromJson(_ data: Data) throws -> Job { try JSONDecoder().decode(Job.self, from: data) }
