import SwiftUI
import UniformTypeIdentifiers

/** One job: the plan with its floating controls, the run list inspector, and the job's dialogs. */
struct JobView: View {
    @Bindable var model: JobModel
    @AppStorage("showInspector") private var showInspector = true
    @State private var roomName = ""
    @State private var knownLength = ""

    var body: some View {
        PlanCanvas(model: model)
            .ignoresSafeArea(.container, edges: .top) // the plan runs under the glass toolbar
            .overlay {
                if model.bitmap == nil {
                    if let msg = model.message { ContentUnavailableView("Can't Show the Plan", systemImage: "exclamationmark.triangle", description: Text(msg)) }
                    else { ProgressView() }
                }
            }
            .overlay(alignment: .bottom) { PlanHUD(model: model).padding(16) }
            .navigationTitle(model.job.name)
            .navigationSubtitle("Scale: \(model.job.scale)" + (model.ratio == nil ? " (not valid)" : ""))
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                RunListView(model: model)
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 440)
            }
            .focusedSceneValue(\.jobModel, model)
            .sheet(isPresented: $model.showConfig) { JobConfigView(model: model) }
            .sheet(isPresented: Binding(get: { model.calibLine != nil }, set: { if !$0 { model.calibLine = nil } })) { knownLengthSheet }
            .alert("Add Room", isPresented: $model.addingRoom) {
                TextField("Name", text: $roomName)
                Button("Add") { model.addRoom(roomName) }.disabled(roomName.trimmed.isEmpty || model.roomTaken(roomName))
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.roomTaken(roomName) ? "That room already exists." : "A border is drawn in the middle of the view; drag its corners to fit.")
            }
            .onChange(of: model.addingRoom) { if model.addingRoom { roomName = "" } }
            .alert("Rename Room", isPresented: Binding(get: { model.renamingRoom != nil }, set: { if !$0 { model.renamingRoom = nil } }), presenting: model.renamingRoom) { old in
                TextField("Name", text: $roomName)
                let target = model.mergeTarget(old, roomName)
                let reserved = roomName.trimmed.caseInsensitiveCompare("Unassigned") == .orderedSame
                Button(target != nil ? "Merge" : "Rename") { model.renameRoom(old, to: roomName) }
                    .disabled(roomName.trimmed.isEmpty || reserved || roomName.trimmed == old)
                Button("Delete Room…", role: .destructive) { model.deletingRoom = old }
                Button("Cancel", role: .cancel) {}
            } message: { old in
                if roomName.trimmed.caseInsensitiveCompare("Unassigned") == .orderedSame { Text("That name is taken by Unassigned.") }
                else if let t = model.mergeTarget(old, roomName) { Text("Its runs will join \(t).") }
                else { Text("Runs in \(old) move with it.") }
            }
            .onChange(of: model.renamingRoom) { if let r = model.renamingRoom { roomName = r } }
            .confirmationDialog("Delete \(model.deletingRoom ?? "")?", isPresented: Binding(get: { model.deletingRoom != nil }, set: { if !$0 { model.deletingRoom = nil } }), presenting: model.deletingRoom) { room in
                Button("Delete", role: .destructive) { model.deleteRoom(room) }
            } message: { room in
                let n = model.job.runs.filter { $0.room == room }.count
                Text(n == 0 ? "The room is empty." : "Its \(n) run\(n == 1 ? "" : "s") will move to Unassigned. No measurements are deleted.")
            }
            .confirmationDialog("Redetect Rooms?", isPresented: $model.redetecting) {
                Button("Redetect", role: .destructive) { model.redetect() }
            } message: {
                Text("Replaces every room border on this page, including ones you edited or added, with new ones found from the plan.")
            }
            .confirmationDialog("Clear All Runs?", isPresented: $model.confirmClear) {
                Button("Clear", role: .destructive) { model.clearRuns() }
            } message: { Text("All \(model.job.runs.count) runs on every page will be removed.") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $model.tool) {
                ForEach(Tool.allCases) { t in
                    Label(t.title, systemImage: t.symbol).tag(t).help("\(t.title) (\(t.key.uppercased()))")
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
        }
        if model.pageCount > 1 {
            ToolbarItemGroup {
                Button { model.goToPage(model.page - 1) } label: { Label("Previous Page", systemImage: "chevron.left") }
                    .disabled(model.page == 0)
                Text("\(model.page + 1) of \(model.pageCount)").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                Button { model.goToPage(model.page + 1) } label: { Label("Next Page", systemImage: "chevron.right") }
                    .disabled(model.page >= model.pageCount - 1)
            }
            ToolbarSpacer(.fixed)
        }
        ToolbarItemGroup {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo (⌘Z)")
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo (⇧⌘Z)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button { exportQuote(model) } label: { Label("Export Quote", systemImage: "tablecells") }
                .disabled(!canExport(model)).help("Export a quote spreadsheet (⇧⌘E)")
            Button { model.showConfig = true } label: { Label("Job Settings", systemImage: "gearshape") }.help("Name, scale and calibration (⌘J)")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button { showInspector.toggle() } label: { Label("Runs", systemImage: "sidebar.trailing") }.help("Show or hide the run list (⌥⌘I)")
        }
    }

    private var knownLengthSheet: some View {
        let inches = parseLength(knownLength, 12).flatMap { $0 > 0 ? $0 : nil }
        return Form {
            Section {
                TextField("Real length of the blue line", text: $knownLength, prompt: Text("e.g. 10' 6\""))
            } header: {
                Text("Known Length")
            } footer: {
                Text("Plain numbers are feet. The scale snaps to a standard architectural scale when it's within 2%.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.calibLine = nil } }
            ToolbarItem(placement: .confirmationAction) { Button("Set Scale") { if let inches { model.calibrate(knownInches: inches) } }.disabled(inches == nil) }
        }
        .onAppear { knownLength = "" }
    }
}

@MainActor func canExport(_ m: JobModel) -> Bool { m.ratio != nil && (!m.job.runs.isEmpty || !m.job.rooms.isEmpty) }

/** Saves the quote spreadsheet where the user picks. */
@MainActor func exportQuote(_ m: JobModel) {
    guard let ratio = m.ratio else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
    let name = m.job.name.filter { $0.isLetter || $0.isNumber || " -_.".contains($0) }.trimmed
    panel.nameFieldStringValue = (name.isEmpty ? "Quote" : name) + ".xlsx"
    panel.canCreateDirectories = true
    let data = quoteXlsx(m.job, ratio)
    let done: (NSApplication.ModalResponse) -> Void = { r in
        guard r == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }
    if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
}

/** The floating glass controls over the plan: what the current tool is doing and its actions. */
private struct PlanHUD: View {
    @Bindable var model: JobModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .capsule)
        }
        .animation(.smooth(duration: 0.2), value: model.tool)
    }

    @ViewBuilder private var content: some View {
        let m = model
        if m.calibrating || (m.tool == .measure && !m.chain.isEmpty) {
            Button("Cancel") { m.cancelMeasuring() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
            Text(m.calibrating ? (m.chain.isEmpty ? "Click the start of a known dimension" : "Click its end")
                 : m.liveLength ?? "\(m.chain.count) point\(m.chain.count == 1 ? "" : "s")")
                .font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(m.calibrating ? Color.blue : Color.primary)
                .frame(minWidth: 120)
            if !m.calibrating {
                Button("Done") { m.finishChain() }.disabled(m.chain.count < 2).buttonStyle(.glassProminent)
                    .help("Finish the run (Return or double-click)")
            }
        } else if m.tool == .rooms {
            if let name = m.draft?.name {
                Button("Delete", role: .destructive) { m.deletingRoom = name }.buttonStyle(.glass)
                Button { m.renamingRoom = name } label: { Text(name).font(.headline).lineLimit(1) }
                    .buttonStyle(.plain).help("Rename").frame(minWidth: 100)
                Button("Done") { m.doneEditingRoom() }.buttonStyle(.glassProminent)
            } else {
                Text("Click a room to edit its border").foregroundStyle(.secondary)
                Button { m.addingRoom = true } label: { Label("Add Room", systemImage: "plus") }.buttonStyle(.glass).disabled(m.bitmap == nil)
                Button("Redetect…") { m.redetecting = true }.buttonStyle(.glass).disabled(m.bitmap == nil)
            }
        } else if let sel = m.selected {
            Button("Delete", role: .destructive) { m.deleteRun(sel) }.buttonStyle(.glass)
            Text([sel.room.flatMap { $0.isEmpty ? nil : $0 }, m.ratio.map { formatFeetInches((m.shownSelected ?? sel).inches($0)) }]
                .compactMap { $0 }.joined(separator: " · ").ifEmpty("Selected run"))
                .font(.headline).monospacedDigit().lineLimit(1).frame(minWidth: 100)
            Button("Done") { m.selected = nil }.buttonStyle(.glassProminent)
        } else {
            totals
            Text(m.tool == .measure ? "Click to place points · Return to finish" : "Click a run to select it · Drag to pan")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var totals: some View {
        let total = model.job.totalInches()
        return VStack(spacing: 0) {
            Text(total.map(formatLF) ?? "Fix the scale").font(.headline).monospacedDigit()
                .foregroundStyle(total == nil ? Color.red : Color.primary)
            Text("\(model.job.runs.count) runs" + (total.map { " · \(formatFeetInches($0))" } ?? "")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

struct JobModelKey: FocusedValueKey { typealias Value = JobModel }
extension FocusedValues {
    var jobModel: JobModel? { get { self[JobModelKey.self] } set { self[JobModelKey.self] = newValue } }
}
