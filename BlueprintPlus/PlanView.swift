import AppKit
import SwiftUI

private let LOUPE_R = 64.0
private let LOUPE_MAG = 2.5 // loupe magnification relative to the current zoom
// Fixed, not themed: drawn over white paper.
private let RUN_COLOR = NSColor(red: 0xD3 / 255.0, green: 0x2F / 255.0, blue: 0x2F / 255.0, alpha: 1)
private let CALIB_COLOR = NSColor(red: 0x15 / 255.0, green: 0x65 / 255.0, blue: 0xC0 / 255.0, alpha: 1)
private let SELECTED_COLOR = NSColor(red: 1, green: 0x6F / 255.0, blue: 0, alpha: 1)
private let NEXT_POINT_COLOR = NSColor(red: 0x2E / 255.0, green: 0x7D / 255.0, blue: 0x32 / 255.0, alpha: 1) // every point after the first
private let ROOM_TEXT = NSColor(red: 0x26 / 255.0, green: 0x32 / 255.0, blue: 0x38 / 255.0, alpha: 1)
private let ROOM_COLORS: [UInt32] = [0x1E88E5, 0x43A047, 0x8E24AA, 0xF4511E, 0x00897B, 0xC0CA33, 0xD81B60, 0x6D4C41]

/** What the room color picker offers: the automatic colors first, then a few more. */
let ROOM_PALETTE: [UInt32] = ROOM_COLORS + [0x3949AB, 0x039BE5, 0x7CB342, 0xFB8C00, 0x546E7A]

/**
 * A room's color: the one picked for it in `custom`, else fixed per name (Java's String.hashCode, so it matches the
 * Android app and survives relaunch).
 */
func roomColor(_ name: String, _ custom: [String: UInt32] = [:]) -> NSColor {
    var h: Int32 = 0
    for u in name.utf16 { h = h &* 31 &+ Int32(u) }
    let c = custom[name] ?? ROOM_COLORS[Int(h & Int32.max) % ROOM_COLORS.count]
    return NSColor(red: CGFloat(c >> 16 & 255) / 255, green: CGFloat(c >> 8 & 255) / 255, blue: CGFloat(c & 255) / 255, alpha: 1)
}

struct PlanCanvas: NSViewRepresentable {
    let model: JobModel
    func makeNSView(context: Context) -> PlanView { PlanView(model) }
    func updateNSView(_ v: PlanView, context: Context) {
        if v.model !== model { v.model = model; v.needsDisplay = true }
    }
}

/**
 * The plan: the rendered page and everything drawn on it, with mouse, trackpad and keyboard handling.
 * Scroll pans, pinch or ⌘-scroll zooms, and dragging empty paper pans. Redraws whenever what `draw` read changes.
 */
final class PlanView: NSView {
    var model: JobModel

    /** What a mouse-down grabbed. */
    private enum Grab {
        case none
        case pan(Offset)
        case node(Run, Int)
        case corner(Int, RoomBoundary)
        case edge(Int, RoomBoundary)
    }
    private var grab = Grab.none
    private var downAt = Offset.zero
    private var dragged = false
    private var lastTool: Tool?
    private var windowX: Double? // our left edge in window coordinates at the last layout

    init(_ model: JobModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Plan")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func layout() {
        super.layout()
        // Keep the plan still on screen when our left edge moves (the job list showing or hiding).
        let x = convert(NSPoint.zero, to: nil).x
        if let windowX, x != windowX { model.pan = model.pan + Offset(windowX - x, 0) }
        windowX = x
        model.viewResized(bounds.size, topInset: safeAreaInsets.top)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    private func point(_ e: NSEvent) -> Offset { Offset(convert(e.locationInWindow, from: nil)) }

    // MARK: - Cursor

    override func cursorUpdate(with event: NSEvent) { cursor(for: point(event)).set() }

    private func cursor(for s: Offset) -> NSCursor {
        if case .pan = grab, dragged { return .closedHand }
        switch model.tool {
        case .measure: return .crosshair
        case .select: return handleNear(s) != nil ? .openHand : model.runNear(s) != nil ? .pointingHand : .arrow
        case .rooms: return handleNear(s) != nil ? .openHand : .arrow
        }
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let s = point(event)
        // As first responder we get the window's mouse moves everywhere (acceptsMouseMovedEvents), and our bounds run
        // under the inspector and the toolbar, so only act when we're the view actually under the pointer (not the run
        // list) and below the toolbar (it lives in the titlebar, outside contentView, so the hit test can't see it).
        guard s.y >= safeAreaInsets.top, let cv = window?.contentView,
              cv.hitTest(event.locationInWindow)?.isDescendant(of: self) == true else { return clearHover() }
        switch model.tool {
        case .measure: model.hover = model.toPage(s)
        case .select: model.hoverRun = model.runNear(s)
        case .rooms: break
        }
        cursor(for: s).set(); ownsCursor = true
    }

    private var ownsCursor = false // so moves over the run list don't keep stomping its cursors (text fields)

    override func mouseExited(with event: NSEvent) { clearHover() }

    /** Off the plan (or under the inspector/HUD, which don't send us mouseExited): drop hover and our cursor. */
    private func clearHover() {
        if model.hover != nil { model.hover = nil }
        if model.hoverRun != nil { model.hoverRun = nil }
        if ownsCursor, case .none = grab { NSCursor.arrow.set(); ownsCursor = false } // we set it by hand in mouseMoved, so nothing else resets it (the run list)
    }

    /** A handle under the screen point: a node of the selected run, or a corner or wall dot of the room being edited. */
    private func handleNear(_ s: Offset) -> Grab? {
        if model.tool == .select, let sel = model.selected, sel.page == model.page {
            if let i = sel.points().indices.first(where: { (model.toScreen(sel.points()[$0]) - s).distance() <= 11 }) { return .node(sel, i) }
        }
        if model.tool == .rooms, let d = model.draft {
            let k = model.ppi / 72
            if let i = d.points.indices.first(where: { (model.toScreen(d.points[$0] * k) - s).distance() <= 11 }) { return .corner(i, d) }
            if let i = d.points.indices.first(where: { i in
                (model.toScreen((d.points[i] + d.points[(i + 1) % d.points.count]) / 2 * k) - s).distance() <= 8
            }) { return .edge(i, d) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let s = point(event)
        downAt = s
        dragged = false
        guard model.bitmap != nil else { grab = .none; return }
        if event.modifierFlags.contains(.option), let h = handleNear(s) { // ⌥-click removes a node or corner
            switch h {
            case .node(let r, let i): model.replaceSelected(r, r.withoutPoint(i))
            case .corner(let i, _): model.removeCorner(i)
            default: break
            }
            grab = .none
            return
        }
        grab = handleNear(s) ?? .pan(model.pan)
        if event.clickCount == 2, model.tool == .measure, model.chain.count >= 2 { // double-click finishes the run
            model.finishChain()
            grab = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let s = point(event)
        if !dragged && (s - downAt).distance() < 3 { return }
        dragged = true
        switch grab {
        case .none: break
        case .pan(let start):
            model.pan = start + (s - downAt)
            NSCursor.closedHand.set()
        case .node(let r, let i): model.dragNode(r, i, to: model.toPage(s))
        case .corner(let i, _): if let cur = model.draft { model.dragCorner(i, of: cur, to: model.toPage(s)) }
        case .edge(let i, let start): model.dragEdge(i, of: start, by: s - downAt)
        }
        if model.tool == .measure { model.hover = model.toPage(s) }
    }

    override func mouseUp(with event: NSEvent) {
        let s = point(event)
        defer { grab = .none; cursor(for: s).set() }
        if dragged {
            switch grab {
            case .node: model.commitNode()
            case .corner, .edge: model.commitDraft()
            default: break
            }
            return
        }
        guard model.bitmap != nil else { return }
        switch grab {
        case .edge(let i, _): model.splitEdge(i) // a click on a wall's dot adds a corner there
        case .corner, .node: break
        default:
            switch model.tool {
            case .measure: if event.clickCount < 2 { model.hover = model.toPage(s); model.setPoint() }
            case .select: model.selectClick(s, clickCount: event.clickCount)
            case .rooms: model.roomClick(s)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let menu = contextMenu(at: point(event)) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    private func contextMenu(at s: Offset) -> NSMenu? {
        let m = NSMenu()
        m.autoenablesItems = false // honor each item's isEnabled
        if case .node(let r, let i) = handleNear(s) {
            m.addItem(ClosureItem("Remove Point", enabled: r.points().count > 2) { [model] in model.replaceSelected(r, r.withoutPoint(i)) })
            return m
        }
        if case .corner(let i, let d) = handleNear(s) {
            m.addItem(ClosureItem("Remove Corner", enabled: d.points.count > 3) { [model] in model.removeCorner(i) })
            return m
        }
        if model.tool == .rooms {
            model.roomClick(s)
            guard let name = model.draft?.name else { return nil }
            m.addItem(ClosureItem("Rename “\(name)”…") { [model] in model.renamingRoom = name })
            m.addItem(ClosureItem("Delete “\(name)”…") { [model] in model.deletingRoom = name })
            return m
        }
        if let r = model.runNear(s) {
            if model.tool != .select { model.tool = .select }
            model.selected = r
            m.addItem(ClosureItem("Add Point Here") { [model] in model.replaceSelected(r, r.withInserted(model.toPage(s), minGap: 8 / model.zoom)) })
            let move = NSMenuItem(title: "Move to Room", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for room in model.allRooms {
                let item = ClosureItem(room.isEmpty ? "Unassigned" : room) { [model] in
                    if let i = model.job.runs.firstIndex(of: r) { model.moveRun(i, to: room) }
                }
                item.state = (r.room ?? "") == room ? .on : .off
                sub.addItem(item)
            }
            move.submenu = sub
            m.addItem(move)
            m.addItem(.separator())
            m.addItem(ClosureItem("Delete Run") { [model] in model.deleteRun(r) })
            return m
        }
        return nil
    }

    // MARK: - Trackpad and wheel

    override func scrollWheel(with event: NSEvent) {
        let s = point(event)
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas {
            // ⌘-scroll, or a mouse wheel's clicks: zoom around the pointer
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            model.zoom(by: exp(dy), at: s)
        } else {
            model.pan = model.pan + Offset(event.scrollingDeltaX, event.scrollingDeltaY)
        }
        if model.tool == .measure { model.hover = model.toPage(s) }
    }

    override func magnify(with event: NSEvent) {
        let s = point(event)
        model.zoom(by: 1 + event.magnification, at: s)
        if model.tool == .measure { model.hover = model.toPage(s) }
    }

    override func smartMagnify(with event: NSEvent) {
        if model.zoom < 2 { model.zoom(by: 3, at: point(event)) } else { model.fit() }
    }

    // MARK: - Keyboard

    override func flagsChanged(with event: NSEvent) {
        needsDisplay = true // Shift shows the loupe; draw reads the live flags so focus changes can't leave it stale
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let chars = event.charactersIgnoringModifiers ?? ""
        switch Int(event.keyCode) {
        case 36, 76: // Return, Enter
            if model.tool == .measure, model.chain.count >= 2 { model.finishChain(); return }
            if model.tool == .rooms, model.draft != nil { model.doneEditingRoom(); return }
            if model.selected != nil { model.selected = nil; return }
        case 53: // Escape
            if model.measuring { model.cancelMeasuring(); return }
            if model.draft != nil { model.doneEditingRoom(); return }
            if model.selected != nil { model.selected = nil; return }
            if model.tool == .rooms { model.tool = .select; return }
        case 51, 117: // Delete, Forward Delete
            if model.tool == .measure, !model.chain.isEmpty { model.removeLastPoint(); return }
            if let r = model.selected { model.deleteRun(r); return }
            if let name = model.draft?.name { model.deletingRoom = name; return }
        case 123, 124, 125, 126: // arrows: nudge the measuring point 1 px on screen, else pan
            let d: Offset = [123: Offset(-1, 0), 124: Offset(1, 0), 125: Offset(0, 1), 126: Offset(0, -1)][Int(event.keyCode)]!
            if model.tool == .measure, model.hover != nil {
                model.nudge = model.nudge + d * ((flags.contains(.shift) ? 10 : 1) / model.zoom)
            } else {
                model.pan = model.pan - d * (flags.contains(.shift) ? 200 : 40)
            }
            return
        default:
            if flags.isEmpty, let c = chars.first, let t = Tool.allCases.first(where: { $0.key == c }) { model.tool = t; return }
            if flags.isEmpty && chars == " " && model.tool == .measure { model.setPoint(); return }
        }
        super.keyDown(with: event)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Everything `render` reads is tracked: any change to it redraws the view.
        withObservationTracking { render(ctx) } onChange: { [weak self] in
            Task { @MainActor in self?.needsDisplay = true }
        }
    }

    private func render(_ ctx: CGContext) {
        let m = model
        if lastTool != m.tool { lastTool = m.tool; window?.invalidateCursorRects(for: self) }
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let bmp = m.bitmap else { return }
        let ppi = bmp.ppi
        let k = ppi / 72
        let page = m.page
        let runs = m.job.runs.filter { $0.page == page }.map { $0 == m.selected ? m.shownSelected! : $0 }
        let rooms = m.shownBoundaries.filter { $0.page == page }
        let cursor = m.cursor.flatMap { c in bounds.contains(m.toScreen(c).cg) ? c : nil }
        let pointColor = m.calibrating ? CALIB_COLOR : m.chain.isEmpty ? RUN_COLOR : NEXT_POINT_COLOR

        /** The page and its marks in page-pixel space; `px` is one screen point in that space. */
        func plan(_ px: Double) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(bmp.height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(bmp.image, in: CGRect(x: 0, y: 0, width: bmp.width, height: bmp.height))
            ctx.restoreGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for r in rooms {
                let path = CGMutablePath()
                path.addLines(between: r.points.map { ($0 * k).cg })
                path.closeSubpath()
                let c = roomColor(r.name, m.job.roomColors)
                let active = r == m.draft
                ctx.addPath(path)
                ctx.setFillColor(c.withAlphaComponent(active ? 0.25 : m.tool == .rooms ? 0.16 : 0.07).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth((active ? 3 : 1.5) * px)
                ctx.strokePath()
            }
            for r in runs {
                let sel = r == m.selected
                let hovered = !sel && r == m.hoverRun
                stroke(r.points(), sel ? SELECTED_COLOR : RUN_COLOR, (sel ? 4 : hovered ? 5 : 3) * px)
                if sel {
                    for (p, q) in r.points().pairs() { dot((p + q) / 2, 5 * px, SELECTED_COLOR) } // click an edge to add a node
                    for p in r.points() { ring(p, 7 * px, SELECTED_COLOR, 2.5 * px) } // node handles, like a room border's corners
                }
            }
            if let l = m.calibLine { stroke([l.a, l.b], CALIB_COLOR, 3 * px) }
            stroke(m.chain, pointColor, 2 * px)
            for p in m.chain { dot(p, 4 * px, pointColor) }
            if let a = m.chain.last, let c = cursor {
                ctx.saveGState()
                ctx.setLineDash(phase: 0, lengths: [10 * px, 6 * px])
                stroke([a, c], pointColor, 2 * px)
                ctx.restoreGState()
            }
        }
        func stroke(_ pts: [Offset], _ c: NSColor, _ w: Double) {
            guard pts.count >= 2 else { return }
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w)
            ctx.addLines(between: pts.map(\.cg)); ctx.strokePath()
        }
        func dot(_ p: Offset, _ r: Double, _ c: NSColor) {
            ctx.setFillColor(c.cgColor); ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        func ring(_ p: Offset, _ r: Double, _ c: NSColor, _ w: Double) {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(.white); ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); ctx.strokeEllipse(in: rect)
        }

        ctx.saveGState()
        ctx.translateBy(x: m.pan.x, y: m.pan.y)
        ctx.scaleBy(x: m.zoom, y: m.zoom)
        plan(1 / m.zoom)
        ctx.restoreGState()

        if let ratio = m.ratio {
            for r in runs { label(formatFeetInches(r.inches(ratio)), at: m.toScreen(r.midpoint()) - Offset(0, 12), size: 13, color: r == m.selected ? SELECTED_COLOR : RUN_COLOR) }
        }
        for r in rooms { // names sit at the middle of each border, over the plan
            let mid = r.points.reduce(Offset.zero, +) / Double(r.points.count) * k
            label(r.name, at: m.toScreen(mid), size: 12, color: ROOM_TEXT)
        }
        if m.tool == .rooms, let d = m.draft { // corner handles; the dots between them move a wall or add a corner
            let c = roomColor(d.name, m.job.roomColors)
            for (i, v) in d.points.enumerated() {
                dot(m.toScreen((v + d.points[(i + 1) % d.points.count]) / 2 * k), 4, c)
            }
            for v in d.points { ring(m.toScreen(v * k), 7, c, 2.5) }
        }

        // With Shift held, the loupe: what's under the point, magnified. It follows the
        // pointer while measuring; while a node is dragged it floats above the pointer so the pointer doesn't cover the point.
        guard let c = cursor ?? m.nodeLoupe else { return }
        let r = LOUPE_R
        let p = m.toScreen(c)
        guard NSEvent.modifierFlags.contains(.shift) else { // the pointer is already a crosshair
            if cursor != nil, m.nudge != .zero { // arrow keys moved the point off the pointer: mark where it is now
                ctx.setStrokeColor(pointColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addLines(between: [CGPoint(x: p.x - 8, y: p.y), CGPoint(x: p.x + 8, y: p.y)])
                ctx.addLines(between: [CGPoint(x: p.x, y: p.y - 8), CGPoint(x: p.x, y: p.y + 8)])
                ctx.strokePath()
            }
            if let live = m.liveLength { label(live, at: p + Offset(0, r + 16), size: 13, color: RUN_COLOR) }
            return
        }
        let lc = cursor != nil ? p : Offset(coerce(p.x, r, bounds.width - r), max(p.y - 2.2 * r, r + 4))
        let mag = min(m.zoom * LOUPE_MAG, max(m.zoom, 12))
        let circle = CGRect(x: lc.x - r, y: lc.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        ctx.translateBy(x: lc.x - c.x * mag, y: lc.y - c.y * mag)
        ctx.scaleBy(x: mag, y: mag)
        plan(1 / mag)
        ctx.restoreGState()
        ctx.setStrokeColor(pointColor.cgColor)
        ctx.setLineWidth(1)
        ctx.addLines(between: [CGPoint(x: lc.x - r, y: lc.y), CGPoint(x: lc.x + r, y: lc.y)])
        ctx.addLines(between: [CGPoint(x: lc.x, y: lc.y - r), CGPoint(x: lc.x, y: lc.y + r)])
        ctx.strokePath()
        ctx.setStrokeColor(NSColor(white: 0.25, alpha: 0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle)
        if let live = m.liveLength { // the run so far, beside the loupe
            label(live, at: lc + Offset(0, r + 16), size: 13, color: RUN_COLOR)
        }
    }

    /** Bold text centered on `at`, on a soft white backing so it reads over the drawing. */
    private func label(_ s: String, at: Offset, size: CGFloat, color: NSColor) {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color])
        let sz = str.size()
        let rect = CGRect(x: at.x - sz.width / 2, y: at.y - sz.height / 2, width: sz.width, height: sz.height)
        NSColor.white.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4).fill()
        str.draw(in: rect)
    }
}

/** A menu item that runs a closure. */
final class ClosureItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
