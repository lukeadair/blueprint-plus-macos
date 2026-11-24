import Foundation
import SwiftUI
import Observation

enum JobSort: String, CaseIterable, Identifiable {
    case recent, name, created
    var id: Self { self }
    var label: String { switch self { case .recent: "Recent Activity"; case .name: "Name"; case .created: "Date Created" } }
    func sorted(_ jobs: [Job]) -> [Job] {
        switch self {
        case .recent: jobs.sorted { $0.updated > $1.updated }
        case .name: jobs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created: jobs.sorted { $0.created > $1.created }
        }
    }
}

/** The job list and the one open job. */
@MainActor @Observable
final class AppState {
    let store = JobStore()
    private(set) var jobs: [Job] = []
    private(set) var model: JobModel?
    var importing = false
    var sidebar: NavigationSplitViewVisibility = .all // the job list; focus mode hides it
    var creating = false
    var error: String?
    var deleting: Job?

    var selection: String? {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection, forKey: "openJob")
            open(selection)
        }
    }

    init() {
        jobs = store.list()
        let last = UserDefaults.standard.string(forKey: "openJob")
        selection = jobs.contains { $0.id == last } ? last : nil
        open(selection)
    }

    private func open(_ id: String?) {
        model?.close()
        model = id.flatMap(store.load).map { job in
            let m = JobModel(store: store, job: job)
            m.onSaved = { [weak self] j in self?.replace(j) }
            return m
        }
    }

    private func replace(_ j: Job) {
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j }
    }

    /** Copies the PDF in as a new job and opens it. */
    func create(from url: URL) {
        guard !creating else { return }
        creating = true
        let store = store
        Task {
            defer { creating = false }
            do {
                let job = try await Task.detached { try store.create(from: url) }.value
                jobs.insert(job, at: 0)
                selection = job.id
            } catch {
                self.error = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func delete(_ job: Job) {
        if selection == job.id { selection = nil }
        store.delete(job.id)
        jobs.removeAll { $0.id == job.id }
    }

    func rename(_ job: Job, to name: String) {
        if let m = model, m.job.id == job.id { m.rename(name); return }
        let n = name.trimmed
        guard !n.isEmpty, var j = store.load(job.id) else { return }
        j.name = n
        try? store.save(j)
        replace(j)
    }
}
