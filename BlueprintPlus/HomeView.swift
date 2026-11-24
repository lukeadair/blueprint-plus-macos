import SwiftUI
import UniformTypeIdentifiers

/** The window: jobs in the sidebar, the open job's plan in the detail, its runs in the inspector. */
struct ContentView: View {
    @Bindable var app: AppState
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $app.sidebar) {
            JobList(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let model = app.model {
                JobView(model: model)
                    .id(model.job.id)
            } else {
                ContentUnavailableView {
                    Label(app.jobs.isEmpty ? "No Jobs Yet" : "No Job Selected", systemImage: "ruler")
                } description: {
                    Text(app.jobs.isEmpty ? "Drop a plan PDF here, or choose New Job to pick one." : "Choose a job in the sidebar, or drop a plan PDF here.")
                } actions: {
                    Button("New Job…") { app.importing = true }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.tint, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            app.create(from: url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $app.importing, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { app.create(from: url) }
        }
        .alert("Couldn't Create the Job", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") {}
        } message: { Text(app.error ?? "") }
    }
}

private struct JobList: View {
    @Bindable var app: AppState
    @AppStorage("sort") private var sort = JobSort.recent
    @State private var renaming: Job?
    @State private var newName = ""

    var body: some View {
        List(selection: $app.selection) {
            ForEach(sort.sorted(app.jobs)) { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).lineLimit(1)
                    Text(summary(job)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(job.id)
                .contextMenu {
                    Button("Rename…") { newName = job.name; renaming = job }
                    Divider()
                    Button("Delete…", role: .destructive) { app.deleting = job }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Divider() // continues the toolbar's bottom line over the sidebar
                Picker("Sort By", selection: $sort) {
                    ForEach(JobSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Sort jobs")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .onDeleteCommand { app.deleting = app.jobs.first { $0.id == app.selection } }
        .overlay { if app.creating { ProgressView().controlSize(.large) } }
        .toolbar {
            ToolbarItem {
                Button { app.importing = true } label: { Label("New Job", systemImage: "plus") }
                    .help("New job from a plan PDF (⌘N)")
            }
        }
        .confirmationDialog("Delete “\(app.deleting?.name ?? "")”?", isPresented: Binding(get: { app.deleting != nil }, set: { if !$0 { app.deleting = nil } })) {
            Button("Delete", role: .destructive) { if let j = app.deleting { app.delete(j) } }
        } message: {
            Text("Its measurements and its copy of the PDF will be removed. This can't be undone.")
        }
        .alert("Rename Job", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let j = renaming { app.rename(j, to: newName) } }
                .disabled(newName.trimmed.isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func summary(_ job: Job) -> String {
        let total = job.totalInches().map(formatLF) ?? "scale not set"
        let date = sort == .created
            ? "created " + Date(timeIntervalSince1970: Double(job.created) / 1000).formatted(date: .abbreviated, time: .omitted)
            : Date(timeIntervalSince1970: Double(job.updated) / 1000).formatted(date: .abbreviated, time: .shortened)
        return "\(job.runs.count) runs · \(total) · \(date)"
    }
}
