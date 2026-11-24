import Foundation
import Observation

/** What a click on the plan does. */
enum Tool: String, CaseIterable, Identifiable {
    case select, measure, rooms
    var id: Self { self }
    var title: String { switch self { case .select: "Select"; case .measure: "Measure"; case .rooms: "Rooms" } }
    var symbol: String { switch self { case .select: "cursorarrow"; case .measure: "ruler"; case .rooms: "square.on.square.dashed" } }
    var key: Character { switch self { case .select: "v"; case .measure: "m"; case .rooms: "r" } }
}

/** A node of the selected run being dragged: the saved run, and the run as dragged. Saved on mouse-up. */
struct NodeDraft: Equatable { var base: Run; var moved: Run }

/**
 * One open job: its data, undo history, the rendered page and room labels, and the plan's tool state.
 * Every change goes through `update`, which saves at once. Ported from the Android app's JobScreen.
 */
@MainActor @Observable
final class JobModel {
    let store: JobStore
    private(set) var job: Job
    @ObservationIgnored var onSaved: (Job) -> Void = { _ in }
    /** `updated` of the version on disk this model last loaded or saved; a different one there came from another device. */
    @ObservationIgnored private var seen: Int64

    // Snapshots of the job before each user edit; in memory only, so they're gone once the job is closed.
    private(set) var undoStack: [Job] = []
    private(set) var redoStack: [Job] = []

    private(set) var pdf: PlanPDF?
    private(set) var pageCount = 0
    var message: String?
    private(set) var bitmap: PageBitmap?
    private(set) var bitmapPage = -1 // the page `bitmap` shows (it lags `page` while rendering)
    private var bitmapGen = 0
    /** Room labels per page, read from the PDF's text (or OCR). A page is missing until it's read. */
    private(set) var labels: [Int: [RoomLabel]] = [:]

    // View: screen = page px * zoom + pan.
    var zoom = 1.0
    var pan = Offset.zero
    var viewSize = CGSize.zero
    var topInset = 0.0 // toolbar over the top of the plan
    @ObservationIgnored var bottomInset = 76.0 // the HUD

    // Tools.
    var tool: Tool = .measure { didSet { if tool != oldValue { resetTool() } } }
    /** Page point under the pointer (measure tool). */
    var hover: Offset? { didSet { if hover != oldValue { nudge = .zero } } }
    var nudge = Offset.zero // arrow-key fine-tuning of the hover point
    var chain: [Offset] = []
    var calibrating = false
    var calibLine: Run?
    var selected: Run?
    var hoverRun: Run? // select tool: the run a click would select
    var nodeDraft: NodeDraft?
    var nodeLoupe: Offset? // page point under the pointer while a node is dragged
    // Room-border editing: click a room to edit its border; `draft` is that border while its handles are dragged.
    var editIdx: Int? // index in job.boundaries
    var draft: RoomBoundary?
    // Borders the draft changed (it and the rooms it pushed aside), by index; applied at commit, so borders added
    // meanwhile (seeding finishing mid-drag) aren't overwritten.
    var pushed: [Int: RoomBoundary] = [:]

    // Sheets and confirmations.
    var showConfig = false
    var addingRoom = false
    var renamingRoom: String?
    var deletingRoom: String?
    var redetecting = false
    var confirmClear = false

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshKey: RefreshKey?
    @ObservationIgnored private var lastRefresh: RefreshKey?
    @ObservationIgnored private var seedTask: Task<Void, Never>?
    @ObservationIgnored private var seedKey: SeedKey?
    @ObservationIgnored private var fitPending = true

    private struct RefreshKey: Equatable { var labels: [Int: [RoomLabel]]; var scale: String }
    private struct SeedKey: Equatable {
        var labels: [Int: [RoomLabel]]; var gen: Int; var page: Int; var scale: String; var seeded: Set<Int>; var scaleSet: Bool
    }

    init(store: JobStore, job: Job) {
        self.store = store
        self.job = job
        seen = job.updated
        open()
    }

    func close() {
        (tasks + [renderTask, refreshTask, seedTask].compactMap { $0 }).forEach { $0.cancel() }
    }

    var page: Int { min(max(job.page, 0), max(0, pageCount - 1)) }
    var ppi: Double { bitmap?.ppi ?? 72 }
    var ratio: Double? { parseScale(job.scale) }
    var measuring: Bool { !chain.isEmpty || calibrating }
    /** Mid-gesture: a reload now (`reloadIfChanged`) would drop the run being measured or the drag. */
    var busy: Bool { measuring || nodeDraft != nil || draft != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /** The cursor while measuring: the pointer, nudged by the arrow keys. */
    var cursor: Offset? { tool == .measure ? hover.map { $0 + nudge } : nil }

    /** The selected run as shown: mid-drag, the dragged version. */
    var shownSelected: Run? { nodeDraft.flatMap { $0.base == selected ? $0.moved : nil } ?? selected }

    /** Borders as shown: the draft and the rooms it pushes, mid-edit. */
    var shownBoundaries: [RoomBoundary] {
        job.boundaries.enumerated().map { i, b in i == editIdx && draft != nil ? draft! : pushed[i] ?? b }
    }

    // MARK: - Saving and undo

    /** Applies `f` to the job and saves it. `undoable` edits of runs, rooms or borders can be undone. */
    func update(undoable: Bool = false, _ f: (inout Job) -> Void) {
        var next = job
        f(&next)
        if undoable && (next.runs != job.runs || next.rooms != job.rooms || next.boundaries != job.boundaries || next.roomColors != job.roomColors) {
            undoStack.append(job)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        // Snapshots from another scale hold borders and room picks found at it, and restore keeps the scale.
        if parseScale(next.scale) != parseScale(job.scale) { undoStack.removeAll(); redoStack.removeAll() }
        var reseeded = next.reseedIfScaleChanged(job)
        if reseeded != next { editIdx = nil; draft = nil } // borders were wiped, so editIdx may point at another one
        let pageChanged = reseeded.page != job.page
        reseeded.updated = Int64(Date().timeIntervalSince1970 * 1000)
        job = reseeded
        do {
            try store.save(job, seen: seen)
            seen = job.updated
        } catch JobStore.StoreError.changedElsewhere {
            // Never merge: keep this device's version as its own job and show the other device's.
            do {
                let copy = try store.saveAsConflict(job)
                onSaved(copy)
                message = "This job was changed on another device, so your edit was saved as “\(copy.name)”."
                if let disk = store.load(job.id) { reloadIfChanged(disk) } // only now: the edit is safe in the copy
            } catch { message = "Couldn't save: \(error.localizedDescription)" }
        } catch JobStore.StoreError.deletedElsewhere {
            // Not onSaved (it would put the job back in the list) or kick (seeding would save again); refresh closes it.
            message = "This job was deleted on another device, so changes to it aren't saved."
            if pageChanged { loadPage() }
            return
        } catch { message = "Couldn't save: \(error.localizedDescription)" }
        onSaved(job)
        if pageChanged { loadPage() }
        kick()
    }

    /** Shows `disk` if another device saved it (its `updated` isn't the one seen), keeping this page. Undo is cleared: its snapshots are of the old version. */
    func reloadIfChanged(_ disk: Job) {
        guard isNewer(disk) else { return }
        resetTool()
        undoStack.removeAll(); redoStack.removeAll()
        var d = disk
        d.page = job.page
        job = d
        seen = disk.updated
        onSaved(job)
        kick()
    }

    /** Another device saved `disk` since this one last loaded or saved the job. */
    func isNewer(_ disk: Job) -> Bool { disk.updated != seen }

    func undo() { restore(from: \.undoStack, to: \.redoStack) }
    func redo() { restore(from: \.redoStack, to: \.undoStack) }

    /** Moves the edit data (not page, scale or name) from the top of `from` into the job, pushing the current job onto `to`. */
    private func restore(from: ReferenceWritableKeyPath<JobModel, [Job]>, to: ReferenceWritableKeyPath<JobModel, [Job]>) {
        guard let s = self[keyPath: from].popLast() else { return }
        self[keyPath: to].append(job)
        selected = nil; editIdx = nil; draft = nil; nodeDraft = nil
        update { j in
            j.runs = s.runs; j.rooms = s.rooms; j.boundaries = s.boundaries; j.editedPages = s.editedPages; j.seededPages = s.seededPages; j.roomColors = s.roomColors
        }
    }

    // MARK: - PDF, labels, room picking and seeding

    private func open() {
        guard let pdf = PlanPDF(url: store.pdf(job.id)) else { message = "Couldn't open the plan PDF."; return }
        self.pdf = pdf
        pageCount = pdf.pageCount
        loadPage()
        tasks.append(Task { [weak self] in
            // shortcut: reads every page up front; fine for plan sets of a few dozen sheets, make it per-page if big sets lag.
            var fromText: [Int: [RoomLabel]] = [:]
            for i in 0..<pdf.pageCount { fromText[i] = await pdf.roomLabels(i); if Task.isCancelled { return } }
            guard let self else { return }
            self.labels = fromText.filter { !$0.value.isEmpty }
            self.kick()
            // Last resort: OCR pages with no text labels. A page stays out of `labels` until its OCR is done, so it
            // isn't seeded as roomless first. shortcut: re-runs on every open with no cache; persist in Job if slow.
            for pg in fromText.filter({ $0.value.isEmpty }).keys.sorted() {
                let l = await ocrRoomLabels(pdf, pg)
                if Task.isCancelled { return }
                self.labels[pg] = l
                self.kick()
            }
        })
    }

    private func loadPage() {
        guard let pdf else { return }
        renderTask?.cancel()
        let pg = page
        renderTask = Task { [weak self] in
            let bmp = await pdf.render(pg)
            guard let self, !Task.isCancelled, pg == self.page else { return }
            guard let bmp else { self.message = "Couldn't draw page \(pg + 1)."; return }
            self.bitmap = bmp; self.bitmapPage = pg; self.bitmapGen += 1
            self.hover = nil; self.chain = []; self.editIdx = nil; self.draft = nil
            if self.selected?.page != pg { self.selected = nil } // kept when a list click switched to its page
            if !self.job.scaleSet && !self.calibrating && self.calibLine == nil { self.showConfig = true } // new job: ask for the scale first
            if let focus = self.pendingFocus, focus.page == pg { self.pendingFocus = nil; focus.run() } else { self.pendingFocus = nil; self.fit() }
            self.kick()
        }
    }

    @ObservationIgnored private var pendingFocus: (page: Int, run: () -> Void)? // framing to apply once that page's bitmap is in (its ppi)

    /** Restarts room picking and seeding when what they depend on changed (Compose's keyed LaunchedEffects). */
    private func kick() {
        let r = RefreshKey(labels: labels, scale: job.scale)
        if r != refreshKey {
            refreshKey = r
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                guard let self else { return }
                // When only labels changed (an OCR page came in), re-pick just those pages.
                let pages = lastRefresh.flatMap { prev in
                    prev.scale == job.scale ? Set(labels.keys.filter { labels[$0] != prev.labels[$0] }) : nil
                }
                await refreshRooms(onlyNew: false, pages: pages)
                if !Task.isCancelled { lastRefresh = r } // only once done: a cancelled refresh is redone next time
            }
        }
        let s = SeedKey(labels: labels, gen: bitmapGen, page: bitmapPage, scale: job.scale, seeded: job.seededPages, scaleSet: job.scaleSet)
        if s != seedKey {
            seedKey = s
            seedTask?.cancel()
            seedTask = seed()
        }
    }

    /**
     * Picks rooms for runs the user hasn't placed by hand (all of them, or only new ones without a room):
     * the nearest label not behind a wall. Wall sizes depend on the scale, so this reruns when it changes.
     */
    private func refreshRooms(onlyNew: Bool, pages: Set<Int>? = nil) async {
        guard let pdf else { return }
        let todo = job.runs.filter {
            !$0.roomManual && !job.seededPages.contains($0.page) && (!onlyNew || $0.room == nil) && (pages?.contains($0.page) ?? true)
        }
        if todo.isEmpty || labels.isEmpty { return }
        let shown = bitmap.map { (page: bitmapPage, bitmap: $0) }
        let picked = await pdf.pickRooms(todo, labels: labels, ratio: ratio, shown: shown)
        if Task.isCancelled { return }
        // Apply to the runs as they are now (some may have been added or deleted meanwhile).
        let updated = job.runs.map { run in
            guard let p = picked[run], !job.seededPages.contains(run.page), p != run.room else { return run }
            var r = run; r.room = p; return r
        }
        if updated != job.runs {
            if let s = selected, picked[s] != nil { selected = nil }
            update { $0.runs = updated }
        }
    }

    /**
     * First time a page is shown with a valid scale (and again after Redetect, or a scale change if not edited): draw a
     * starting border around each room label, found from the walls. Runs on this page then go by the borders.
     */
    private func seed() -> Task<Void, Never>? {
        guard job.scaleSet, let bmp = bitmap, let ratio else { return nil } // the 1/4" default is often wrong: seeding at it draws bad borders
        let pg = bitmapPage
        guard let pageLabels = labels[pg] else { return nil } // labels not read yet
        // Re-seeded: pages never seeded, and pages with borders from the old star-shaped seeder (> MAX_CORNERS corners).
        let stale = job.boundaries.contains { $0.page == pg && $0.points.count > MAX_CORNERS }
        if pg != page || (job.seededPages.contains(pg) && !stale) { return nil }
        // Borders the user added before the page was seeded stay; seeds are cut back off them.
        let kept = job.boundaries.filter { $0.page == pg && $0.points.count <= MAX_CORNERS }
        let taken = Set((job.boundaries.filter { $0.page != pg } + kept).map(\.name))
        return Task { [weak self] in
            guard let seeded = await seedBorders(bmp, ratio: ratio, page: pg, labels: pageLabels, kept: kept, taken: taken),
                  let self, !Task.isCancelled else { return }
            if stale { self.editIdx = nil; self.draft = nil } // dropping old borders shifts the indices
            self.update { j in
                j.boundaries = j.boundaries.filter { $0.page != pg || $0.points.count <= MAX_CORNERS } + seeded // drops old star-shaped seeds
                j.seededPages.insert(pg)
                j = j.reassignRooms()
            }
            if let s = self.selected, !self.job.runs.contains(s) { self.selected = nil }
        }
    }

    // MARK: - View

    /** Fits the page in the view, below the toolbar and above the HUD. */
    func fit() {
        guard let b = bitmap, viewSize.width > 0, viewSize.height > 0 else { fitPending = true; return }
        fitPending = false
        let h = max(1, viewSize.height - topInset - bottomInset)
        zoom = min(viewSize.width / Double(b.width), h / Double(b.height)) * 0.97
        pan = Offset((viewSize.width - Double(b.width) * zoom) / 2, topInset + (h - Double(b.height) * zoom) / 2)
    }

    func viewResized(_ size: CGSize, topInset: Double) {
        let first = viewSize == .zero
        viewSize = size
        self.topInset = topInset
        if first || fitPending { fit() }
    }

    /** Zooms by `factor` keeping the screen point `at` (default: the view's middle) still. */
    func zoom(by factor: Double, at: Offset? = nil) {
        let c = at ?? Offset(viewSize.width / 2, viewSize.height / 2)
        let z = coerce(zoom * factor, 0.05, 20)
        pan = c - (c - pan) * (z / zoom)
        zoom = z
    }

    func toPage(_ screen: Offset) -> Offset { (screen - pan) / zoom }
    func toScreen(_ p: Offset) -> Offset { p * zoom + pan }

    /** Centers `r` in the view, zooming in until it spans ~40% of it. */
    private func center(on r: Run) {
        guard viewSize.width > 0 else { return }
        let len = (r.b - r.a).distance()
        if len > 0 { zoom = max(zoom, min(20, viewSize.width * 0.4 / len)) }
        let mid = (r.a + r.b) / 2
        pan = Offset(viewSize.width / 2, viewSize.height / 2) - mid * zoom
    }

    /** A click on a room in the run list: frame its border (this page's first, else another page's). */
    func focusRoom(_ name: String) {
        let mine = job.boundaries.filter { $0.name == name }
        guard let b = mine.first(where: { $0.page == page }) ?? mine.first else { return }
        if b.page != page { pendingFocus = (b.page, { [weak self] in self?.frame(b.bounds()) }); update { $0.page = b.page } } else { frame(b.bounds()) }
    }

    /** Fits `r` (page points) in the visible area, with a margin. */
    private func frame(_ r: Rect) {
        guard viewSize.width > 0, r.width > 0, r.height > 0 else { return }
        let k = ppi / 72
        let h = max(1, viewSize.height - topInset - bottomInset)
        zoom = coerce(min(viewSize.width / (r.width * k), h / (r.height * k)) * 0.8, 0.05, 20)
        let mid = Offset((r.left + r.right) / 2, (r.top + r.bottom) / 2) * k
        pan = Offset(viewSize.width / 2, topInset + h / 2) - mid * zoom
    }

    func goToPage(_ p: Int) {
        guard p >= 0, p < pageCount, p != page else { return }
        update { $0.page = p }
    }

    // MARK: - Tools

    private func resetTool() {
        chain = []; calibrating = false; selected = nil; hoverRun = nil; nodeDraft = nil; nodeLoupe = nil
        editIdx = nil; draft = nil; pushed = [:]
    }

    /** Starts a calibration: two points over a known dimension. */
    func startCalibration() {
        tool = .measure
        resetTool()
        calibrating = true
    }

    // A point must sit a little away from the last one, so a double click can't add a duplicate node.
    func movedEnough(_ c: Offset) -> Bool { chain.last.map { (c - $0).distance() * zoom >= 8 } ?? true }

    func setPoint() {
        guard let c = cursor, movedEnough(c) else { return }
        chain.append(c)
        if calibrating && chain.count == 2 {
            calibLine = Run(page: page, a: chain[0], b: chain[1], ppi: ppi)
            calibrating = false; chain = []
        }
    }

    func removeLastPoint() { if !chain.isEmpty { chain.removeLast() } }

    func cancelMeasuring() { chain = []; calibrating = false }

    func finishChain() {
        guard chain.count >= 2, !calibrating else { return }
        let run = Run(page: page, a: chain[0], b: chain[1], ppi: ppi, extra: Array(chain.dropFirst(2)))
        update(undoable: true) { j in j.runs.append(run); j = j.reassignRooms() }
        tasks.append(Task { [weak self] in await self?.refreshRooms(onlyNew: true) })
        chain = []
    }

    /** The live length of the chain to the cursor. */
    var liveLength: String? {
        guard let c = cursor, !chain.isEmpty, let ratio, !calibrating else { return nil }
        let pts = chain + [c]
        return formatFeetInches(Run(page: page, a: pts[0], b: pts[1], ppi: ppi, extra: Array(pts.dropFirst(2))).inches(ratio))
    }

    /** The run within 24 points (screen) of the screen point `s`, on this page. */
    func runNear(_ s: Offset) -> Run? {
        let p = toPage(s)
        guard let hit = job.runs.filter({ $0.page == page }).minBy({ $0.distanceTo(p) }), hit.distanceTo(p) * zoom < 24 else { return nil }
        return hit
    }

    /**
     * Select tool click: a run selects it; elsewhere clears. On the selected run, a double click or a click on a
     * segment's middle dot adds a node there (Android adds one on any tap, which a mouse hits by accident).
     */
    func selectClick(_ s: Offset, clickCount: Int) {
        guard let hit = runNear(s) else { selected = nil; return }
        guard hit == selected else { selected = hit; return }
        let dot = hit.points().pairs().map { ($0.0 + $0.1) / 2 }.first { (toScreen($0) - s).distance() <= 8 }
        if let dot { replaceSelected(hit, hit.withInserted(dot, minGap: 8 / zoom)) }
        else if clickCount == 2 { replaceSelected(hit, hit.withInserted(toPage(s), minGap: 8 / zoom)) }
    }

    /** Swaps `old` for `new` and selects the stored run (reassignRooms may have changed its room). */
    func replaceSelected(_ old: Run, _ new: Run) {
        guard let i = job.runs.firstIndex(of: old), old != new else { return }
        update(undoable: true) { j in j.runs[i] = new; j = j.reassignRooms() }
        selected = job.runs[i]
    }

    func dragNode(_ base: Run, _ i: Int, to p: Offset) {
        let target = p.clampTo(Rect(0, 0, Double(bitmap?.width ?? 0), Double(bitmap?.height ?? 0)))
        nodeDraft = NodeDraft(base: base, moved: base.withPoint(i, target))
        nodeLoupe = target
    }

    func commitNode() {
        defer { nodeDraft = nil; nodeLoupe = nil }
        guard let d = nodeDraft, d.moved != d.base, let i = job.runs.firstIndex(of: d.base) else { return }
        update(undoable: true) { j in j.runs[i] = d.moved; j = j.reassignRooms() }
        selected = job.runs[i]
    }

    func deleteRun(_ r: Run) {
        if selected == r { selected = nil }
        guard let i = job.runs.firstIndex(of: r) else { return }
        update(undoable: true) { $0.runs.remove(at: i) }
    }

    /** A click in the run list: highlight the run on the plan, switching page or centering on it. */
    func listSelect(_ i: Int) {
        guard i < job.runs.count else { return }
        let r = job.runs[i]
        chain = []; calibrating = false
        if tool != .select { tool = .select }
        selected = r
        if r.page != page { pendingFocus = (r.page, { [weak self] in self?.center(on: r) }); update { $0.page = r.page } } else { center(on: r) }
    }

    /** Moves run `i` to `room` by hand. Keeps the room it left in the list even if that was its last run (Unassigned excepted). */
    func moveRun(_ i: Int, to room: String) {
        guard i < job.runs.count else { return }
        let old = job.runs[i]
        if (old.room ?? "") == room && old.roomManual { return }
        var moved = old; moved.room = room; moved.roomManual = true
        if selected == old { selected = moved }
        let from = old.room ?? ""
        update(undoable: true) { j in
            j.runs[i] = moved
            if !from.isEmpty && !j.rooms.contains(from) { j.rooms.append(from) }
        }
    }

    func clearRuns() { selected = nil; update(undoable: true) { $0.runs = [] } }

    // MARK: - Rooms

    /** Every room name in the job, for the run list and moving runs. */
    var allRooms: [String] {
        (job.runs.map { $0.room ?? "" } + job.rooms + job.boundaries.map(\.name)).distinct().sorted(by: roomOrder)
    }

    /** Rooms tool click: edit the smallest border under the point, or none. */
    func roomClick(_ s: Offset) {
        let pt = toPage(s) / (ppi / 72)
        let i = job.boundaries.indices.filter { job.boundaries[$0].page == page && job.boundaries[$0].contains(pt) }
            .minBy { job.boundaries[$0].area() }
        editIdx = i; draft = i.map { job.boundaries[$0] }; pushed = [:]
    }

    private var pageRectPt: Rect { Rect(0, 0, Double(bitmap?.width ?? 0) / (ppi / 72), Double(bitmap?.height ?? 0) / (ppi / 72)) }

    /** Takes `b` if it's a simple shape on the page, pushing overlapped rooms aside (from where they were before this drag). */
    func tryMove(_ b: RoomBoundary) {
        guard let idx = editIdx, let out = pushAside(job.boundaries, idx, b, pageRectPt) else { return }
        pushed = Dictionary(uniqueKeysWithValues: out.enumerated().filter { $0.element != job.boundaries[$0.offset] }.map { ($0.offset, $0.element) })
        draft = b
    }

    /** Corner `i` of `start` (the draft at drag start) dragged to page point `p` (pixels). */
    func dragCorner(_ i: Int, of cur: RoomBoundary, to p: Offset) {
        let pt = (p / (ppi / 72)).clampTo(pageRectPt)
        let q = snapCorner(cur.points, i, pt, 12 / zoom / (ppi / 72))
        var b = cur; b.points[i] = q
        tryMove(b)
    }

    /** Wall `i` of `start` (the draft at drag start) slid by the screen distance `by`. */
    func dragEdge(_ i: Int, of start: RoomBoundary, by: Offset) { tryMove(start.moveEdge(i, by: by / zoom / (ppi / 72))) }

    func splitEdge(_ i: Int) { draft = draft?.splitEdge(i); commitDraft() }

    func removeCorner(_ i: Int) { if let b = draft?.withoutVertex(i) { tryMove(b); commitDraft() } }

    func commitDraft() {
        let p = pushed
        pushed = [:]
        guard let i = editIdx, let b = draft else { return }
        let changed = p.merging([i: b]) { $1 }
        if changed.allSatisfy({ k, v in k < job.boundaries.count && job.boundaries[k] == v }) { return }
        update(undoable: true) { j in
            for (k, v) in changed where k < j.boundaries.count { j.boundaries[k] = v }
            j.editedPages.insert(b.page)
            j = j.reassignRooms()
        }
        if let s = selected, !job.runs.contains(s) { selected = nil }
    }

    func doneEditingRoom() { editIdx = nil; draft = nil; pushed = [:] }

    /** Whether `name` is already a room (or Unassigned), ignoring case. */
    func roomTaken(_ name: String) -> Bool {
        let n = name.trimmed
        return (job.rooms + job.boundaries.map(\.name) + job.runs.compactMap(\.room) + ["Unassigned"]).contains { $0.caseInsensitiveCompare(n) == .orderedSame }
    }

    /** Adds room `name`, with a 10' square border in the middle of the view cut back off the rooms there (if there's room). */
    func addRoom(_ name: String) {
        let n = name.trimmed
        guard !n.isEmpty, !roomTaken(n) else { return }
        var border: RoomBoundary?
        if let bmp = bitmap {
            let pxPerPt = ppi / 72
            let mid = toPage(Offset(viewSize.width / 2, viewSize.height / 2)) / pxPerPt
            let pageRect = Rect(0, 0, Double(bmp.width) / pxPerPt, Double(bmp.height) / pxPerPt)
            if pageRect.contains(mid) {
                let half = 60 * (ratio ?? (1.0 / 48)) * 72
                var r: Rect? = Rect(center: mid, radius: half).intersect(pageRect)
                for b in job.boundaries where b.page == page { r = r.flatMap { clipAway($0, b.bounds(), keep: mid) } }
                border = r.map { RoomBoundary(name: n, page: page, points: $0.corners()) }
            }
        }
        update(undoable: true) { j in
            j.rooms.append(n)
            if let border { j.boundaries.append(border); j.editedPages.insert(page) }
            j = j.reassignRooms()
        }
        if let border { tool = .rooms; editIdx = job.boundaries.count - 1; draft = border }
    }

    /** Renaming onto another room merges them; this is that room's exact spelling, if any. */
    func mergeTarget(_ old: String, _ name: String) -> String? {
        let t = name.trimmed
        return (job.rooms + job.boundaries.map(\.name) + job.runs.compactMap { $0.room?.isEmpty == false ? $0.room : nil }).distinct()
            .first { $0 != old && $0.caseInsensitiveCompare(t) == .orderedSame }
    }

    func renameRoom(_ old: String, to name: String) {
        let to = mergeTarget(old, name) ?? name.trimmed
        guard !to.isEmpty, to != old, to.caseInsensitiveCompare("Unassigned") != .orderedSame else { return }
        if selected?.room == old { selected = nil }
        editIdx = nil; draft = nil
        update(undoable: true) { $0 = $0.renameRoom(old, to) }
    }

    /** Deletes `room`: its runs stay, moved to Unassigned as manual so re-picking doesn't put them straight back. */
    func deleteRoom(_ room: String) {
        if selected?.room == room { selected = nil }
        editIdx = nil; draft = nil
        update(undoable: true) { j in
            j.rooms.removeAll { $0 == room }
            j.roomColors[room] = nil
            j.editedPages.formUnion(j.boundaries.filter { $0.name == room }.map(\.page))
            j.boundaries.removeAll { $0.name == room }
            j.runs = j.runs.map { var r = $0; if r.room == room { r.room = ""; r.roomManual = true }; return r }
        }
    }

    /** Clean slate for this page's borders: seeding redraws them. */
    func redetect() {
        editIdx = nil; draft = nil
        update(undoable: true) { $0 = $0.unseed([page]) }
    }

    // MARK: - Job config

    func saveConfig(name: String, scale: String) {
        let n = name.trimmed, s = scale.trimmed
        guard !n.isEmpty, parseScale(s) != nil else { return }
        update { j in j.name = n; j.scale = s; j.scaleSet = true }
    }

    func rename(_ name: String) {
        let n = name.trimmed
        guard !n.isEmpty else { return }
        update { $0.name = n }
    }

    /** Sets the scale from the calibration line and its real length. */
    func calibrate(knownInches: Double) {
        guard let line = calibLine, knownInches > 0 else { return }
        update { j in j.scale = calibratedScale(line.inches(1), knownInches); j.scaleSet = true }
        calibLine = nil
    }
}

/** Seed borders for one page (off the main thread): a rectangle per room label from the walls, overlaps removed. */
private func seedBorders(_ bmp: PageBitmap, ratio: Double, page pg: Int, labels: [RoomLabel], kept: [RoomBoundary], taken: Set<String>) async -> [RoomBoundary]? {
    let pxPerPt = bmp.ppi / 72
    let pxPerInch = bmp.ppi * ratio
    let walls = WallFinder(pxPerInch) { bmp.isDark($0, $1) }
    let pageRect = Rect(0, 0, Double(bmp.width), Double(bmp.height))
    let rooms = numberRepeats(labels.filter { !inTable($0.x, $0.y, pxPerPt) { bmp.isDark($0, $1) } }, taken: taken) // schedules list rooms too
    var rects: [(Offset, Rect)] = []
    for l in rooms {
        if Task.isCancelled { return nil }
        let c = Offset(l.x, l.y) * pxPerPt
        rects.append((c, seedRect(c, maxLen: 360 * pxPerInch, inset: 4 * pxPerInch, spread: 24 * pxPerInch, page: pageRect, half: Offset(l.halfW, l.halfH) * pxPerPt) { from, to in
            walls.crosses(from.x, from.y, to.x, to.y)
        }))
    }
    let keptPx = kept.map { b in let r = b.bounds(); return Rect(r.topLeft * pxPerPt, r.bottomRight * pxPerPt) }
    return separate(rects, minApart: 48 * pxPerInch).enumerated().compactMap { i, r in
        // a label inside a kept border is that room: clipAway drops it
        var acc = r
        for k in keptPx { acc = acc.flatMap { clipAway($0, k, keep: rects[i].0) } }
        return acc.map { RoomBoundary(name: rooms[i].name, page: pg, points: $0.corners().map { $0 / pxPerPt }) }
    }
}
