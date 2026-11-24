import Foundation

// Pure Swift, no AppKit/SwiftUI: mirrors Compose's Offset and Rect so the logic ported from the Android app
// (Boundaries, Rooms) keeps its exact semantics. CGRect would standardize inverted rects and differs on `intersect`.

struct Offset: Hashable, Sendable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static let zero = Offset(0, 0)

    func distance() -> Double { (x * x + y * y).squareRoot() }

    static func + (a: Offset, b: Offset) -> Offset { Offset(a.x + b.x, a.y + b.y) }
    static func - (a: Offset, b: Offset) -> Offset { Offset(a.x - b.x, a.y - b.y) }
    static func * (a: Offset, k: Double) -> Offset { Offset(a.x * k, a.y * k) }
    static func / (a: Offset, k: Double) -> Offset { Offset(a.x / k, a.y / k) }
    static prefix func - (a: Offset) -> Offset { Offset(-a.x, -a.y) }

    var cg: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(p.x, p.y) }
}

/** Compose's Rect: edges, not origin + size, and never standardized. */
struct Rect: Hashable, Sendable {
    var left: Double, top: Double, right: Double, bottom: Double
    init(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    init(center: Offset, radius: Double) { self.init(center.x - radius, center.y - radius, center.x + radius, center.y + radius) }
    init(_ topLeft: Offset, _ bottomRight: Offset) { self.init(topLeft.x, topLeft.y, bottomRight.x, bottomRight.y) }

    var width: Double { right - left }
    var height: Double { bottom - top }
    var topLeft: Offset { Offset(left, top) }
    var topRight: Offset { Offset(right, top) }
    var bottomLeft: Offset { Offset(left, bottom) }
    var bottomRight: Offset { Offset(right, bottom) }

    /** Half-open, like Compose: the right and bottom edges are outside. */
    func contains(_ p: Offset) -> Bool { p.x >= left && p.x < right && p.y >= top && p.y < bottom }
    func intersect(_ o: Rect) -> Rect { Rect(max(left, o.left), max(top, o.top), min(right, o.right), min(bottom, o.bottom)) }

    func with(left: Double? = nil, top: Double? = nil, right: Double? = nil, bottom: Double? = nil) -> Rect {
        Rect(left ?? self.left, top ?? self.top, right ?? self.right, bottom ?? self.bottom)
    }
}

/** Kotlin's roundToInt (Math.round): half rounds up, also for negatives. */
func roundToInt(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

func coerce(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

extension Array {
    /** Kotlin's minByOrNull: the first element with the smallest key. */
    func minBy<K: Comparable>(_ key: (Element) -> K) -> Element? {
        var best: Element?
        var bestKey: K?
        for e in self { let k = key(e); if bestKey == nil || k < bestKey! { best = e; bestKey = k } }
        return best
    }
    /** Kotlin's maxByOrNull: the first element with the largest key. */
    func maxBy<K: Comparable>(_ key: (Element) -> K) -> Element? {
        var best: Element?
        var bestKey: K?
        for e in self { let k = key(e); if bestKey == nil || k > bestKey! { best = e; bestKey = k } }
        return best
    }
    /** Kotlin's zipWithNext. */
    func pairs() -> [(Element, Element)] { count < 2 ? [] : (0..<count - 1).map { (self[$0], self[$0 + 1]) } }
}
