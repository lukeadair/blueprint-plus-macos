import SwiftUI

@main
struct BlueprintPlusApp: App {
    @State private var app = AppState()

    var body: some Scene {
        Window("Blueprint+", id: "main") {
            ContentView(app: app)
                .frame(minWidth: 900, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in app.refresh() }
                #if DEBUG
                .task { await debugSnapshot(app) }
                #endif
        }
        .defaultSize(width: 1400, height: 900)
        .commands { AppCommands(app: app) }
    }
}

private struct AppCommands: Commands {
    let app: AppState
    @FocusedValue(\.jobModel) private var focused

    @AppStorage("showInspector") private var showInspector = true // same key as JobView's

    private var m: JobModel? { focused ?? app.model }
    private var focusing: Bool { app.sidebar == .detailOnly && !showInspector }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Job…") { app.importing = true }.keyboardShortcut("n")
            Divider()
            Button(app.syncFolder.map { "Sync Folder: \($0.lastPathComponent)…" } ?? "Sync Folder…") { app.chooseSyncFolder() }
            Button("Stop Syncing") { app.stopSyncing() }.disabled(app.syncFolder == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export Quote…") { if let m { exportQuote(m) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(m.map(canExport) != true)
        }
        CommandGroup(replacing: .undoRedo) {
            // Text fields in dialogs keep their own undo; the plan uses the job's history.
            Button("Undo") { if !textUndo(redo: false) { m?.undo() } }
                .keyboardShortcut("z")
                .disabled(m?.canUndo != true && !textFieldActive)
            Button("Redo") { if !textUndo(redo: true) { m?.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(m?.canRedo != true && !textFieldActive)
        }
        CommandGroup(after: .toolbar) {
            Button(focusing ? "Exit Focus Mode" : "Focus Mode") {
                let show = focusing
                withAnimation {
                    app.sidebar = show ? .all : .detailOnly
                    showInspector = show
                }
            }.keyboardShortcut("f")
            Divider()
            Button("Zoom In") { m?.zoom(by: 1.25) }.keyboardShortcut("+").disabled(m == nil)
            Button("Zoom Out") { m?.zoom(by: 0.8) }.keyboardShortcut("-").disabled(m == nil)
            Button("Zoom to Fit") { m?.fit() }.keyboardShortcut("0").disabled(m == nil)
            Divider()
            ForEach(Tool.allCases) { t in
                Button(t.title + " Tool") { m?.tool = t }.disabled(m == nil)
            }
            Divider()
        }
        CommandMenu("Job") {
            Button("Job Settings…") { m?.showConfig = true }.keyboardShortcut("j").disabled(m == nil)
            Button("Calibrate Scale…") { m?.startCalibration() }.disabled(m?.bitmap == nil)
            Divider()
            Button("Previous Page") { if let m { m.goToPage(m.page - 1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(m.map { $0.page == 0 } ?? true)
            Button("Next Page") { if let m { m.goToPage(m.page + 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(m.map { $0.page >= $0.pageCount - 1 } ?? true)
            Divider()
            Button("Add Room…") { m?.addingRoom = true }.disabled(m?.bitmap == nil)
            Button("Redetect Rooms on This Page…") { m?.redetecting = true }.disabled(m?.bitmap == nil)
            Divider()
            Button("Clear All Runs…") { m?.confirmClear = true }.disabled(m?.job.runs.isEmpty ?? true)
        }
    }

    private var textFieldActive: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    /** Sends undo/redo to a focused text field instead of the job; false when no text field has focus. */
    private func textUndo(redo: Bool) -> Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager else { return false }
        if redo { um.redo() } else { um.undo() }
        return true
    }
}

#if DEBUG
/**
 * Debug builds: `open --env BP_SNAPSHOT=1 Blueprint+.app` writes the window to the container's tmp/snapshot.png after
 * a few seconds, for checking the UI without Screen Recording permission. `BP_HOVER=x,y` (view points) puts the
 * measuring loupe there first, `BP_TOOL=select|measure|rooms` picks the tool.
 */
@MainActor private func debugSnapshot(_ app: AppState) async {
    let env = ProcessInfo.processInfo.environment
    guard env["BP_SNAPSHOT"] != nil else { return }
    try? await Task.sleep(for: .seconds(5))
    if let m = app.model {
        if let t = env["BP_TOOL"].flatMap(Tool.init(rawValue:)) { m.tool = t }
        if let h = env["BP_HOVER"]?.split(separator: ",").compactMap({ Double($0) }), h.count == 2 { m.hover = m.toPage(Offset(h[0], h[1])) }
        if env["BP_SELECT"] != nil, let r = m.job.runs.first(where: { $0.page == m.page }) { m.selected = r }
    }
    try? await Task.sleep(for: .seconds(1))
    if let m = app.model {
        let state = "zoom \(m.zoom) pan \(m.pan) view \(m.viewSize) tool \(m.tool) selected \(String(describing: m.selected))"
        try? state.write(to: URL.temporaryDirectory.appending(path: "snapshot.txt"), atomically: true, encoding: .utf8)
    }
    guard let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL.temporaryDirectory.appending(path: "snapshot.png"))
    func find(_ v: NSView) -> PlanView? { v as? PlanView ?? v.subviews.lazy.compactMap(find).first }
    if let plan = find(view), let r2 = plan.bitmapImageRepForCachingDisplay(in: plan.bounds) {
        plan.cacheDisplay(in: plan.bounds, to: r2)
        try? r2.representation(using: .png, properties: [:])?.write(to: URL.temporaryDirectory.appending(path: "plan.png"))
    }
}
#endif
