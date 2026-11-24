import Foundation
import Testing
@testable import BlueprintPlus

// Ported from BoundariesTest.kt.

private func box(_ name: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, page: Int = 0) -> RoomBoundary {
    RoomBoundary(name: name, page: page, points: [Offset(x0, y0), Offset(x1, y0), Offset(x1, y1), Offset(x0, y1)])
}
private func b(_ r: Rect) -> RoomBoundary { RoomBoundary(name: "", page: 0, points: r.corners()) }
private let page = Rect(0, 0, 1000, 1000)

private func noOverlaps(_ kept: [Rect]) -> Bool {
    kept.indices.allSatisfy { i in kept[(i + 1)...].allSatisfy { !b(kept[i]).overlaps(b($0)) } }
}

@Suite struct BoundariesTests {
    @Test func containsAndArea() {
        let l = RoomBoundary(name: "L", page: 0, points: [Offset(0, 0), Offset(10, 0), Offset(10, 5), Offset(5, 5), Offset(5, 10), Offset(0, 10)])
        #expect(near(l.area(), 75, 1e-3))
        #expect(l.contains(Offset(2, 8)))
        #expect(l.contains(Offset(8, 2)))
        #expect(!l.contains(Offset(8, 8))) // the notch
    }

    @Test func smallestBorderWinsAndPagesAreSeparate() {
        let bs = [box("Bedroom", 0, 0, 100, 100), box("Closet", 10, 10, 30, 30), box("Other page", 0, 0, 100, 100, page: 1)]
        #expect(roomAt(bs, 0, Offset(20, 20)) == "Closet")
        #expect(roomAt(bs, 0, Offset(60, 60)) == "Bedroom")
        #expect(roomAt(bs, 1, Offset(20, 20)) == "Other page")
        #expect(roomAt(bs, 0, Offset(150, 20)) == nil)
    }

    @Test func editingVertices() {
        let r = box("R", 0, 0, 10, 10)
        #expect(r.moveVertex(1, by: Offset(2, -1)).points[1] == Offset(12, -1))
        #expect(r.moveVertex(1, by: Offset(2, -1)).points[0] == r.points[0]) // only that vertex moves
        let split = r.splitEdge(3) // last edge wraps to vertex 0
        #expect(split.points.count == 5)
        #expect(split.points[4] == Offset(0, 5))
        #expect(RoomBoundary(name: "T", page: 0, points: Array(r.points.prefix(3))).withoutVertex(0) == nil) // a triangle stays a triangle
        #expect(r.withoutVertex(2)!.points.count == 3)
    }

    @Test func seedRectFindsTheRoomBetweenWalls() {
        // Walls at the edges of a 100x80 room at (100, 100): a ray has crossed one once its end is outside the box.
        let room = Rect(100, 100, 200, 180)
        let r = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page) { _, to in !room.contains(to) }
        #expect(near(r.left, room.left, 2.5) && near(r.top, room.top, 2.5))
        #expect(near(r.right, room.right, 2.5) && near(r.bottom, room.bottom, 2.5))
    }

    @Test func seedRectIgnoresADoorInOneRay() {
        // A door in the right wall right in front of the label: only the middle ray escapes.
        let room = Rect(100, 100, 200, 180)
        func escaped(_ to: Offset) -> Bool { to.x > 200 && to.y >= 135 && to.y <= 145 }
        let r = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page) { from, to in
            !room.contains(to) && !(from.y >= 135 && from.y <= 145 && escaped(to))
        }
        #expect(near(r.right, 200, 2.5))
    }

    @Test func seedRectStopsAtTheWallEvenIfTwoRaysMissIt() {
        // Plan A: a door in front of the label, and the wall missed in a second ray; one ray still finds it.
        let room = Rect(100, 100, 200, 180)
        let r = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page) { from, to in !room.contains(to) && !(from.y < 145 && to.x > 200) }
        #expect(near(r.right, 200, 2.5))
    }

    @Test func seedRectInANarrowHallKeepsItsRaysInside() {
        // A 20-tall hall (spread 10 would put side rays on its walls) whose right wall has a door away from the middle.
        let hall = Rect(100, 130, 300, 150)
        let r = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page) { from, to in
            !hall.contains(to) && !(!(from.y >= 132 && from.y <= 148) && to.x > 300) // rays off the hall's middle 16 see no right wall
        }
        #expect(near(r.right, 300, 2.5))
    }

    @Test func seedRectNearOneWallSpansTheRoomPastADoor() {
        // Building Plan 2 laundry: the label is 10 below the top wall and a door fills the top of the left wall. Side
        // rays kept within 0.8 x 10 of the label would all go through the door; the lower one must use the room below.
        let room = Rect(100, 100, 200, 200)
        let r = seedRect(Offset(150, 110), maxLen: 500, inset: 0, spread: 40, page: page) { _, to in
            !room.contains(to) && !(to.x < 100 && to.y >= 100 && to.y <= 130)
        }
        #expect(near(r.left, 100, 2.5))
    }

    @Test func seedRectFansOutWhenAllThreeRaysLeak() {
        // Plan A mud room: a door fills most of the right wall, so all three rays run out to the cap.
        let room = Rect(100, 100, 200, 180)
        let r = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page) { from, to in
            !room.contains(to) && !(to.x > 200 && from.y >= 125 && from.y <= 165)
        }
        #expect(near(r.right, 200, 2.5))
    }

    @Test func seedRectSideRaysSkipWhatsBesideTheLabel() {
        // Plan A boys bath: a shower partition just above the label's left end stops the upper side ray 6 px out.
        let room = Rect(100, 100, 200, 180)
        func partition(_ from: Offset, _ to: Offset) -> Bool { from.y < 140 && from.x >= 144 && to.x <= 144 }
        let r = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page, half: Offset(15, 4)) { from, to in
            !room.contains(to) || partition(from, to)
        }
        #expect(near(r.left, 100, 2.5))
        let bare = seedRect(Offset(150, 140), maxLen: 500, inset: 0, spread: 10, page: page) { from, to in !room.contains(to) || partition(from, to) }
        #expect(near(bare.left, 144, 2.5)) // without the label's size it's cut
    }

    @Test func separateSplitsOpenPlanRooms() {
        // Plan A: the hall's seed runs into the open kitchen and holds the kitchen's label; the kitchen and
        // dining seeds each hold the other's label.
        let seeds: [(Offset, Rect)] = [
            (Offset(600, 1010), Rect(194, 975, 1004, 1034)), // hall
            (Offset(928, 1016), Rect(765, 761, 1156, 1285)), // kitchen
            (Offset(964, 1181), Rect(764, 776, 1156, 1286)), // dining
        ]
        let out = separate(seeds, minApart: 50)
        #expect(near(out[0]!.right, 764, 1)) // halfway from hall label to kitchen label
        #expect(out[1] != nil && out[2] != nil)
        #expect(out[1]!.contains(seeds[1].0) && out[2]!.contains(seeds[2].0))
        #expect(noOverlaps(out.compactMap { $0 }))
    }

    @Test func seedRectWithNoWallsIsCappedAndStaysOnThePage() {
        let r = seedRect(Offset(30, 500), maxLen: 50, inset: 5, spread: 10, page: page) { _, _ in false }
        #expect(r == Rect(0, 450, 80, 550))
    }

    @Test func separateLeavesNoOverlaps() {
        // Two neighbours whose seeds overlap; a closet whose label sits inside the bedroom's seed; a label inside the closet.
        let seeds: [(Offset, Rect)] = [
            (Offset(50, 50), Rect(0, 0, 120, 100)), // bedroom
            (Offset(150, 50), Rect(80, 0, 220, 100)), // neighbour, bigger
            (Offset(20, 20), Rect(10, 10, 30, 30)), // closet
            (Offset(25, 25), Rect(0, 0, 60, 60)), // label inside the closet: dropped
        ]
        let out = separate(seeds)
        #expect(out[2] == Rect(10, 10, 30, 30)) // smallest keeps its seed
        #expect(out[3] == nil)
        let kept = out.compactMap { $0 }
        #expect(kept.count == 3)
        #expect(noOverlaps(kept))
        for (s, r) in zip(seeds, out) { if let r { #expect(r.contains(s.0) || s.0.x == r.right || s.0.y == r.bottom) } }
    }

    @Test func overlapsAllowsSharedWalls() {
        let a = box("A", 0, 0, 10, 10)
        #expect(!a.overlaps(box("B", 10, 0, 20, 10))) // shares an edge
        #expect(!a.overlaps(box("B", 10, 10, 20, 20))) // shares a corner
        #expect(a.overlaps(box("B", 5, 5, 15, 15))) // crossing
        #expect(a.overlaps(box("B", 2, 2, 8, 8))) // inside
        #expect(a.overlaps(box("B", 0, 0, 5, 10))) // inside, along shared lines
        #expect(a.overlaps(box("B", 0, 0, 10, 10))) // the same
    }

    @Test func selfCrossing() {
        #expect(!box("A", 0, 0, 10, 10).selfCrosses())
        #expect(RoomBoundary(name: "A", page: 0, points: [Offset(0, 0), Offset(10, 10), Offset(10, 0), Offset(0, 10)]).selfCrosses())
    }

    @Test func atMostSixCorners() {
        var r = box("A", 0, 0, 10, 10)
        for _ in 0..<5 { r = r.splitEdge(0) }
        #expect(r.points.count == MAX_CORNERS)
    }

    @Test func reassignOnlyTouchesSeededPagesAndNeverManualRuns() {
        // 144 ppi: a point at (x, y) px is (x/2, y/2) PDF points. Midpoint of each run below is (60, 60) px = (30, 30) pt.
        func run(_ page: Int, _ room: String? = nil, manual: Bool = false) -> Run {
            Run(page: page, a: Offset(40, 60), b: Offset(80, 60), ppi: 144, room: room, roomManual: manual)
        }
        var far = run(0); far.a = Offset(400, 400); far.b = Offset(440, 400)
        let job = Job(id: "i", name: "n", runs: [run(0), run(0, "Old"), run(0, "Hand", manual: true), run(1, "Label pick"), far],
                      boundaries: [box("Kitchen", 0, 0, 100, 100), box("Kitchen", 0, 0, 100, 100, page: 1)], seededPages: [0])
        #expect(job.reassignRooms().runs.map(\.room) == ["Kitchen", "Kitchen", "Hand", "Label pick", ""])
    }

    @Test func boundariesSurviveJsonAndOldSavesLoad() throws {
        let job = Job(id: "i", name: "n", boundaries: [box("Kitchen", 1.5, 2, 30, 40, page: 2)], seededPages: [0, 2], editedPages: [2])
        #expect(try jobFromJson(try jobToJson(job)) == job)
        let old = try jobFromJson(Data(#"{"id":"i","name":"n","scale":"1/4\" = 1'","runs":[]}"#.utf8))
        #expect(old.boundaries.isEmpty && old.seededPages.isEmpty && old.editedPages.isEmpty)
    }

    @Test func renamingARoomRenamesItsBorder() {
        let job = Job(id: "i", name: "n", boundaries: [box("Bath", 0, 0, 1, 1), box("Hall", 2, 2, 3, 3)])
        #expect(job.renameRoom("Bath", "Master Bath").boundaries.map(\.name) == ["Master Bath", "Hall"])
    }

    @Test func renamedBorderSurvivesScaleChange() {
        let job = Job(id: "i", name: "n", scale: "1/4\" = 1'", boundaries: [box("Bath", 0, 0, 1, 1), box("Hall", 0, 0, 1, 1, page: 1)],
                      seededPages: [0, 1]).renameRoom("Bath", "Kids Bath")
        #expect(job.editedPages == [0])
        var rescaled = job; rescaled.scale = "1/8\" = 1'"
        #expect(rescaled.reseedIfScaleChanged(job).boundaries.map(\.name) == ["Kids Bath"]) // page 1 untouched: redrawn
    }

    @Test func scaleChangeRedrawsOnlyUneditedPages() {
        let job = Job(id: "i", name: "n", scale: "1/4\" = 1'",
                      boundaries: [box("Kitchen", 0, 0, 1, 1), box("Bath", 0, 0, 1, 1, page: 1), box("Hall", 0, 0, 1, 1, page: 2)],
                      seededPages: [0, 1], editedPages: [1])
        // same ratio, different text: nothing redone
        var same = job; same.scale = "1/4\"=1'-0\""
        var back = same.reseedIfScaleChanged(job); back.scale = job.scale
        #expect(back == job)
        var other = job; other.scale = "1/8\" = 1'"
        let rescaled = other.reseedIfScaleChanged(job)
        #expect(rescaled.boundaries.map(\.name) == ["Bath", "Hall"]) // page 2 was never seeded: hand-drawn
        #expect(rescaled.seededPages == [1])
        #expect(rescaled.editedPages == [1])
    }

    @Test func unseedClearsThePageEvenIfEdited() {
        let job = Job(id: "i", name: "n", boundaries: [box("Kitchen", 0, 0, 1, 1), box("Bath", 0, 0, 1, 1, page: 1)], seededPages: [0, 1], editedPages: [0, 1])
        let u = job.unseed([0])
        #expect(u.boundaries.map(\.name) == ["Bath"])
        #expect(u.seededPages == [1] && u.editedPages == [1])
    }

    @Test func moveEdgeSlidesTheWallSidewaysOnly() {
        let moved = box("A", 0, 0, 100, 50).moveEdge(1, by: Offset(20, 7)) // right wall
        // Double leaves ~1e-15 of the along-wall part where Kotlin's Float rounded to exactly 0
        #expect(zip(moved.points, box("A", 0, 0, 120, 50).points).allSatisfy { near($0.x, $1.x, 1e-9) && near($0.y, $1.y, 1e-9) })
    }

    @Test func snapCornerSquaresUpNearNeighbours() {
        let pts = box("A", 0, 0, 100, 50).points
        #expect(snapCorner(pts, 2, Offset(104, 47), 5) == Offset(100, 50))
        #expect(snapCorner(pts, 2, Offset(110, 48), 5) == Offset(110, 50)) // y snaps, x too far
        #expect(snapCorner(pts, 2, Offset(110, 60), 5) == Offset(110, 60))
        #expect(snapCorner(pts, 2, Offset(102, 2), 5) == Offset(102, 2)) // would land on the corner above
    }

    @Test func pushAsideCutsTheNeighboursBack() {
        let all = [box("A", 0, 0, 100, 100), box("B", 100, 0, 200, 50), box("C", 100, 50, 200, 100), box("Other page", 100, 0, 200, 100, page: 1)]
        let out = pushAside(all, 0, all[0].moveEdge(1, by: Offset(30, 0)), page)!
        #expect(out[0] == box("A", 0, 0, 130, 100))
        #expect(out[1] == box("B", 130, 0, 200, 50))
        #expect(out[2] == box("C", 130, 50, 200, 100))
        #expect(out[3] == all[3])
    }

    @Test func pushAsideRefusesWhatItCantPush() {
        let a = box("A", 0, 0, 100, 100)
        let bb = box("B", 100, 0, 200, 100)
        #expect(pushAside([a, bb], 0, a.moveEdge(1, by: Offset(95, 0)), page) == nil) // B would be a sliver
        let l = RoomBoundary(name: "L", page: 0, points: [Offset(100, 0), Offset(200, 0), Offset(200, 200), Offset(150, 200), Offset(150, 100), Offset(100, 100)])
        #expect(pushAside([a, l], 0, a.moveEdge(1, by: Offset(20, 0)), page) == nil) // not a rectangle
        #expect(pushAside([a, bb], 0, a.moveEdge(2, by: Offset(0, 1000)), page) == nil) // off the page
        #expect(pushAside([a, bb], 0, a.moveEdge(3, by: Offset(10, 0)), page) != nil) // nothing in the way
    }
}
