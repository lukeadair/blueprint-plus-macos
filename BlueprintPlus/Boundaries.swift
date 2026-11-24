import Foundation

// Room borders: polygons in PDF points (the units room labels and Run.midPoints use), so they don't depend on
// render size or scale. A run belongs to the room whose border holds its midpoint. Ported from Boundaries.kt.

/** A room's border on `page`: a closed polygon of at least 3 `points`. */
struct RoomBoundary: Hashable, Sendable {
    var name: String
    var page: Int
    var points: [Offset]

    func area() -> Double {
        abs(points.indices.reduce(0.0) { s, i in
            let a = points[i], b = points[(i + 1) % points.count]
            return s + (a.x * b.y - b.x * a.y)
        }) / 2
    }

    func contains(_ p: Offset) -> Bool {
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    func moveVertex(_ i: Int, by: Offset) -> RoomBoundary { var r = self; r.points[i] = points[i] + by; return r }

    /** The wall from vertex `i` to the next slid sideways by the part of `by` across it, so it keeps its length and angle. */
    func moveEdge(_ i: Int, by: Offset) -> RoomBoundary {
        let k = (i + 1) % points.count
        let e = points[k] - points[i]
        let len2 = e.x * e.x + e.y * e.y
        let n = len2 == 0 ? by : by - e * ((by.x * e.x + by.y * e.y) / len2)
        var r = self
        r.points[i] = points[i] + n
        r.points[k] = points[k] + n
        return r
    }

    /** A new vertex at the middle of the edge from vertex `i` to the next one. */
    func splitEdge(_ i: Int) -> RoomBoundary {
        if points.count >= MAX_CORNERS { return self }
        var r = self
        r.points.insert((points[i] + points[(i + 1) % points.count]) / 2, at: i + 1)
        return r
    }

    /** Nil when it would leave fewer than 3 vertices. */
    func withoutVertex(_ i: Int) -> RoomBoundary? {
        if points.count <= 3 { return nil }
        var r = self
        r.points.remove(at: i)
        return r
    }

    func bounds() -> Rect {
        Rect(points.map(\.x).min()!, points.map(\.y).min()!, points.map(\.x).max()!, points.map(\.y).max()!)
    }

    fileprivate func edges() -> [(Offset, Offset)] { points.indices.map { (points[$0], points[($0 + 1) % points.count]) } }

    fileprivate func strictlyContains(_ p: Offset) -> Bool {
        contains(p) && !edges().contains { distToSegment(p, $0.0, $0.1) < EDGE_EPS }
    }

    /** A point just inside each edge's middle: catches one border lying on or inside another along shared lines. */
    fileprivate func insideEdgePoints() -> [Offset] {
        edges().compactMap { a, b in
            let m = (a + b) / 2
            let len = (b - a).distance()
            guard len > 0 else { return nil }
            let n = Offset(-(b - a).y, (b - a).x) / len * (EDGE_EPS * 10)
            return [m + n, m - n].first { contains($0) }
        }
    }

    /** Whether the two borders share any area. Sharing a wall (touching edges or corners) is fine. */
    func overlaps(_ o: RoomBoundary) -> Bool {
        let oe = o.edges()
        return edges().contains { a, b in oe.contains { c, d in properlyCross(a, b, c, d) } }
            || points.contains { o.strictlyContains($0) } || o.points.contains { strictlyContains($0) }
            || insideEdgePoints().contains { o.strictlyContains($0) } || o.insideEdgePoints().contains { strictlyContains($0) }
    }

    /** A border whose edges cross each other (a bow tie). */
    func selfCrosses() -> Bool {
        let e = edges()
        return e.indices.contains { i in
            (i + 2..<max(i + 2, e.count)).contains { j in
                (i != 0 || j != e.count - 1) && properlyCross(e[i].0, e[i].1, e[j].0, e[j].1)
            }
        }
    }

    fileprivate func isRect() -> Bool {
        points.count == 4 && edges().allSatisfy { a, b in abs(a.x - b.x) < EDGE_EPS || abs(a.y - b.y) < EDGE_EPS }
    }
}

/** The room holding `p` (PDF points) on `page`; the smallest border wins, so a closet inside a bedroom is the closet. */
func roomAt(_ boundaries: [RoomBoundary], _ page: Int, _ p: Offset) -> String? {
    boundaries.filter { $0.page == page && $0.contains(p) }.minBy { $0.area() }?.name
}

/** Most corners a border may have: rooms are rectangles, or an L at most. */
let MAX_CORNERS = 6

extension Rect {
    func corners() -> [Offset] { [topLeft, topRight, bottomRight, bottomLeft] }
}

extension Offset {
    func clampTo(_ r: Rect) -> Offset { Offset(coerce(x, r.left, r.right), coerce(y, r.top, r.bottom)) }
}

private func inClosed(_ p: Offset, _ r: Rect) -> Bool { p.x >= r.left && p.x <= r.right && p.y >= r.top && p.y <= r.bottom }

/**
 * A starting rectangle for the room labelled at `center`. Each side is where walls stop rays going that way: three
 * parallel rays, `spread` apart, and the shortest wins, so a door opening (or a wall missed in one ray) doesn't let
 * the room leak into the next one.
 * A ray stops where `hitsWall` says the segment has crossed a wall (bisected; a wall shows up at its far face, so
 * it's pulled back by `inset`), or at `maxLen`. Clamped to `page`. `half`: the label's half size; a side ray ignores
 * what's nearer the center than the label's own text reaches (a wall can't run through it: Plan A's shower partition).
 */
func seedRect(_ center: Offset, maxLen: Double, inset: Double, spread: Double, page: Rect, half: Offset = Offset(0, 0), hitsWall: (Offset, Offset) -> Bool) -> Rect {
    func reach(_ from: Offset, _ dir: Offset) -> Double {
        if !hitsWall(from, from + dir * maxLen) { return maxLen }
        var lo = 0.0, hi = maxLen
        for _ in 0..<8 { let mid = (lo + hi) / 2; if hitsWall(from, from + dir * mid) { hi = mid } else { lo = mid } }
        return max(hi - inset, inset)
    }
    let l = reach(center, Offset(-1, 0)), u = reach(center, Offset(0, -1))
    let r = reach(center, Offset(1, 0)), d = reach(center, Offset(0, 1))
    // Side rays stay inside the room: in a 4' hall, rays 2' off the middle would run outside it. Each goes as far
    // as its own side allows (minus/plus: reach toward -across/+across), so a label near one wall still spans
    // the room the other way and its rays can't all fit through one door.
    func side(_ dir: Offset, _ middle: Double, _ minus: Double, _ plus: Double) -> Double {
        let across = Offset(dir.y, dir.x)
        let skip = abs(dir.x) * half.x + abs(dir.y) * half.y
        let s = min([-min(spread, 0.8 * minus), min(spread, 0.8 * plus)].map { o -> Double in
            let r = reach(center + across * o, dir)
            return r < skip ? reach(center + across * o + dir * skip, dir) + skip : r
        }.min()!, middle)
        if s < maxLen { return s }
        // Every ray ran to the cap: out a door filling that wall (Plan A's mud room). Fan across the room for the wall beside it.
        let step = spread / 2
        return (0...Int(0.8 * (minus + plus) / step)).map { reach(center + across * (-0.8 * minus + Double($0) * step), dir) }.min()!
    }
    return Rect(
        center.x - side(Offset(-1, 0), l, d, u), center.y - side(Offset(0, -1), u, r, l),
        center.x + side(Offset(1, 0), r, u, d), center.y + side(Offset(0, 1), d, l, r)
    ).intersect(page)
}

/**
 * Removes overlaps between seeded rectangles (`seeds`: label center to rectangle). Smallest first, so a closet
 * keeps its space and the room around it is cut back; each later one is cut by `clipAway` against all placed so
 * far. A label inside a room already placed, `minApart` or more from that room's label along the axis they're
 * furthest apart on, splits that room halfway between the two (open plans: hall into kitchen, kitchen into
 * dining). Nil where nothing is left that holds its label (a label right next to another room's).
 */
func separate(_ seeds: [(Offset, Rect)], minApart: Double = .greatestFiniteMagnitude) -> [Rect?] {
    var placed: [Int] = []
    var out = [Rect?](repeating: nil, count: seeds.count)
    let order = seeds.indices.sorted { a, b in // stable, like Kotlin's sortedBy
        let ka = seeds[a].1.width * seeds[a].1.height, kb = seeds[b].1.width * seeds[b].1.height
        return ka != kb ? ka < kb : a < b
    }
    for i in order {
        let (c, seed) = seeds[i]
        for j in placed {
            let p = out[j]!, pc = seeds[j].0
            if !inClosed(c, p) { continue }
            let dx = c.x - pc.x, dy = c.y - pc.y
            if max(abs(dx), abs(dy)) < minApart { continue }
            let m = (c + pc) / 2
            out[j] = abs(dx) >= abs(dy) ? (dx > 0 ? p.with(right: m.x) : p.with(left: m.x))
                : (dy > 0 ? p.with(bottom: m.y) : p.with(top: m.y))
        }
        var r: Rect? = seed
        for j in placed { r = clipAway(r!, out[j]!, keep: c); if r == nil { break } }
        if let r { placed.append(i); out[i] = r }
    }
    return out
}

/**
 * `r` moved back off `taken`: of the four cuts (one side to `taken`'s facing edge), the biggest that still holds
 * `keep` (any, when it's nil); nil if none does. `r` itself if they don't overlap.
 */
func clipAway(_ r: Rect, _ taken: Rect, keep: Offset?) -> Rect? {
    if !(r.left < taken.right && taken.left < r.right && r.top < taken.bottom && taken.top < r.bottom) { return r }
    return [r.with(right: taken.left), r.with(left: taken.right), r.with(bottom: taken.top), r.with(top: taken.bottom)]
        .filter { $0.width > 0 && $0.height > 0 && (keep == nil || inClosed(keep!, $0)) }
        .maxBy { $0.width * $0.height }
}

private func cross(_ o: Offset, _ a: Offset, _ b: Offset) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }

/** Segments ab and cd cross at a point inside both (touching or running along each other doesn't count). */
private func properlyCross(_ a: Offset, _ b: Offset, _ c: Offset, _ d: Offset) -> Bool {
    let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

private let EDGE_EPS = 0.01 // PDF points: a point this close to an edge is on it

/**
 * `target` for vertex `i` with its x and y pulled onto a neighbour's when within `tol`, so the walls meeting
 * there come out square.
 */
func snapCorner(_ points: [Offset], _ i: Int, _ target: Offset, _ tol: Double) -> Offset {
    let ns = [points[(i + points.count - 1) % points.count], points[(i + 1) % points.count]]
    func snap(_ v: Double, _ of: (Offset) -> Double) -> Double {
        ns.map(of).filter { abs($0 - v) <= tol }.minBy { abs($0 - v) } ?? v
    }
    let p = Offset(snap(target.x, \.x), snap(target.y, \.y))
    return ns.contains(p) ? target : p // snapping both ways onto a neighbour would collapse the wall
}

private let MIN_ROOM_PT = 12.0 // a push may not squeeze a room thinner than this (8" at 1/4" = 1')

/**
 * `all` with `all[idx]` replaced by `moved` and every room it now overlaps cut back off it, or nil when that
 * can't be done: `moved` crosses itself or leaves `page`, or an overlapped room isn't a rectangle or would be cut
 * (nearly) away.
 * shortcut: only rectangles are pushed, and against moved's bounding box (over-cuts beside an L); clip real polygons if L rooms need it.
 */
func pushAside(_ all: [RoomBoundary], _ idx: Int, _ moved: RoomBoundary, _ page: Rect) -> [RoomBoundary]? {
    if moved.selfCrosses() || moved.points.contains(where: { !inClosed($0, page) }) { return nil }
    var out = all
    out[idx] = moved
    for (k, o) in all.enumerated() { // a cut room only shrinks, so it can't run into a third one
        if k == idx || o.page != moved.page || !moved.overlaps(o) { continue }
        if !o.isRect() { return nil }
        guard let r = clipAway(o.bounds(), moved.bounds(), keep: nil), r.width >= MIN_ROOM_PT, r.height >= MIN_ROOM_PT else { return nil }
        out[k].points = r.corners()
    }
    return out
}

extension Job {
    /**
     * Puts every run that isn't manual and sits on a seeded page into the room its midpoint is in (Unassigned if
     * none). Pages not seeded yet keep the label-based picks.
     */
    func reassignRooms() -> Job {
        var j = self
        j.runs = runs.map { r in
            if r.roomManual || !seededPages.contains(r.page) { return r }
            var n = r
            n.room = roomAt(boundaries, r.page, r.midPoints()) ?? ""
            return n
        }
        return j
    }

    /** `pages` with their borders gone and not seeded, so the seeding step draws them fresh from the labels. */
    func unseed(_ pages: Set<Int>) -> Job {
        var j = self
        j.boundaries = boundaries.filter { !pages.contains($0.page) }
        j.seededPages = seededPages.subtracting(pages)
        j.editedPages = editedPages.subtracting(pages)
        return j
    }

    /**
     * This job after `old`: when the scale changed, pages whose borders the user hasn't touched are redrawn, since
     * their walls were found with the old scale (which is often just the 1/4" default on a job's first open).
     */
    func reseedIfScaleChanged(_ old: Job) -> Job {
        parseScale(scale) == parseScale(old.scale) ? self : unseed(seededPages.subtracting(editedPages))
    }
}
