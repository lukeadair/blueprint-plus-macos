import SwiftUI

/**
 * Runs grouped by room, each room with its total. Drag a run onto another room's section to move it.
 * Rooms are alphabetical (so they don't jump when a run moves), Unassigned last; rooms the user added show even
 * when empty, so runs can be dragged into them.
 */
struct RunListView: View {
    @Bindable var model: JobModel
    @State private var dropTarget: String?
    @State private var colorPicking: String? // room whose color palette is open

    private var sections: [(room: String, runs: [(Int, Run)])] {
        let byRoom = Dictionary(grouping: model.job.runs.enumerated().map { ($0.offset, $0.element) }) { $0.1.room ?? "" }
        return model.allRooms.map { ($0, byRoom[$0] ?? []) }
    }

    private var selection: Binding<Int?> {
        Binding(get: { model.selected.flatMap { model.job.runs.firstIndex(of: $0) } },
                set: { if let i = $0 { model.listSelect(i) } else { model.selected = nil } })
    }

    var body: some View {
        let ratio = model.ratio
        let total = model.job.totalInches()
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(total.map(formatLF) ?? "Fix the scale").font(.title2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(total == nil ? Color.red : Color.primary)
                Text("\(model.job.runs.count) runs" + (total.map { " · \(formatFeetInches($0))" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            List(selection: selection) {
                // Header as a plain row, not a Section header: pinned headers stay put while the list bounces.
                let secs = sections
                ForEach(secs, id: \.room) { section in
                    header(section.room, section.runs, ratio, first: section.room == secs.first?.room)
                        .listRowSeparator(.hidden)
                    ForEach(section.runs, id: \.0) { i, r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ratio.map { formatFeetInches(r.inches($0)) } ?? "Scale not set").monospacedDigit()
                            Text("Run \(i + 1)" + (model.pageCount > 1 ? " · page \(r.page + 1)" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 18)
                        .tag(i)
                        .draggable("\(i)")
                        .dropDestination(for: String.self) { items, _ in _ = drop(items, on: section.room) }
                        .contextMenu { runMenu(i, r) }
                    }
                }
                Button { model.addingRoom = true } label: { Label("Add Room", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 4)
            }
            .onDeleteCommand { if let r = model.selected { model.deleteRun(r) } }
            .overlay {
                if model.job.runs.isEmpty && model.allRooms.isEmpty {
                    ContentUnavailableView("No Runs", systemImage: "ruler", description: Text("Choose Measure, then click along a cabinet run."))
                }
            }
        }
    }

    private func header(_ room: String, _ runs: [(Int, Run)], _ ratio: Double?, first: Bool) -> some View {
        let color = room.isEmpty ? Color.secondary : Color(nsColor: roomColor(room, model.job.roomColors)) // matches its border on the plan
        let hasBorder = model.job.boundaries.contains { $0.name == room }
        return HStack {
            if room.isEmpty {
                Circle().fill(color).frame(width: 10, height: 10)
            } else {
                Button { colorPicking = room } label: { Circle().fill(color).frame(width: 10, height: 10).padding(3).contentShape(Circle()) }
                    .buttonStyle(.plain)
                    .help("Change color")
                    .popover(isPresented: Binding(get: { colorPicking == room }, set: { if !$0 { colorPicking = nil } })) { palette(room) }
            }
            Text(room.isEmpty ? "Unassigned" : room).font(.headline).foregroundStyle(.primary)
            Spacer()
            if let ratio { Text(formatLF(runs.reduce(0) { $0 + $1.1.inches(ratio) })).font(.headline).monospacedDigit().foregroundStyle(.secondary) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)))
        .overlay(dropTarget == room ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.3)) : nil)
        .contentShape(Rectangle())
        .padding(.top, first ? 0 : 10)
        .onTapGesture { model.selected = nil; model.focusRoom(room) }
        .help(hasBorder ? "Show on plan" : "")
        .dropDestination(for: String.self) { items, _ in drop(items, on: room) } isTargeted: { dropTarget = $0 ? room : (dropTarget == room ? nil : dropTarget) }
        .contextMenu {
            if !room.isEmpty {
                Button("Rename “\(room)”…") { model.renamingRoom = room }
                Button("Delete “\(room)”…", role: .destructive) { model.deletingRoom = room }
            }
        }
    }

    /** The predefined room colors; the current one is ringed. */
    private func palette(_ room: String) -> some View {
        let current = roomColor(room, model.job.roomColors)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 8), count: 5), spacing: 8) {
            ForEach(ROOM_PALETTE, id: \.self) { c in
                let ns = roomColor(room, [room: c])
                Button {
                    model.update(undoable: true) { $0.roomColors[room] = c }
                    colorPicking = nil
                } label: {
                    Circle().fill(Color(nsColor: ns)).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.primary, lineWidth: ns == current ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    @ViewBuilder private func runMenu(_ i: Int, _ r: Run) -> some View {
        Menu("Move to Room") {
            ForEach(model.allRooms, id: \.self) { room in
                Button(room.isEmpty ? "Unassigned" : room) { model.moveRun(i, to: room) }.disabled((r.room ?? "") == room)
            }
        }
        Divider()
        Button("Delete Run", role: .destructive) { model.deleteRun(r) }
    }

    private func drop(_ items: [String], on room: String) -> Bool {
        guard let i = items.first.flatMap(Int.init), i < model.job.runs.count, (model.job.runs[i].room ?? "") != room else { return false }
        model.moveRun(i, to: room)
        return true
    }
}
