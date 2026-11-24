import Foundation
import SwiftUI
import AppKit
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
    private(set) var store: JobStore
    /** The folder jobs sync through (nil = this Mac only); access to it is held while it's in use. */
    private(set) var syncFolder: URL?
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
        var failed = false
        var folder: URL?
        if let data = UserDefaults.standard.data(forKey: Self.syncKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                if stale, let d = try? url.bookmarkData(options: .withSecurityScope) { UserDefaults.standard.set(d, forKey: Self.syncKey) }
                folder = url
            } else { failed = true }
        }
        syncFolder = folder
        store = JobStore(dir: folder)
        watch(folder)
        if failed { error = "Couldn't open the sync folder, so these are the jobs saved on this Mac. Choose it again in File > Sync Folder…" }
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
        if let i = jobs.firstIndex(where: { $0.id == j.id }) { jobs[i] = j } else { jobs.insert(j, at: 0) } // new: a conflict copy
    }

    /** Picks up what another device synced: the list, and the open job if it changed (or closes it if it was deleted). */
    func refresh() {
        // One at a time: list() resolves sync copies (two at once would make two conflict jobs), and an older list could land last.
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        let store = store
        Task {
            defer {
                refreshing = false
                if refreshAgain { refreshAgain = false; refresh() }
            }
            // Off the main thread: in a cloud folder, reading an online-only file waits for its download.
            let list = await Task.detached { store.list() }.value
            guard store.dir == self.store.dir else { return } // switched folders meanwhile
            jobs = list
            guard let m = model else { return }
            replace(m.job) // the list may predate an edit made while it was read
            // Read now, not with the list: an older read would look like another device's version.
            if let disk = store.load(m.job.id) {
                if m.isNewer(disk) { if m.busy { scheduleRefresh() } else { m.reloadIfChanged(disk) } } // reload once the gesture ends
            } else if !store.exists(m.job.id) { selection = nil }
        }
    }

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    /**
     * Refreshes when the sync folder's entries change (a sync tool bringing a file in, atomic saves). Only the sync
     * folder: nothing else writes the local one. shortcut: an in-place rewrite of a file doesn't fire (activation still
     * catches it); switch to FSEvents with file events if a sync tool writes in place.
     */
    private func watch(_ folder: URL?) {
        watcher?.cancel()
        watcher = nil
        guard let folder else { return }
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return } // activation still refreshes
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleRefresh() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        watcher = s
    }

    /** Coalesces a burst of events (a sync, our own saves) into one refresh. */
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { refresh() }
        }
    }

    private static let syncKey = "syncFolder"

    /** Asks for a folder (one a sync tool shares, e.g. Google Drive), copies this Mac's jobs into it and uses it. */
    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message = "Choose a folder that syncs with your other devices, e.g. one in Google Drive. Your jobs are copied into it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.startAccessingSecurityScopedResource() else { error = "Couldn't open that folder."; return }
        do {
            let new = JobStore(dir: url)
            try new.adopt(store)
            UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope), forKey: Self.syncKey)
            use(new, folder: url)
        } catch {
            url.stopAccessingSecurityScopedResource()
            self.error = "Couldn't use that folder: \(error.localizedDescription)"
        }
    }

    /** Goes back to this Mac's own folder, copying in the jobs from the sync folder first. */
    func stopSyncing() {
        let local = JobStore()
        do { try local.adopt(store) } catch { self.error = "Couldn't copy the jobs back: \(error.localizedDescription)"; return }
        UserDefaults.standard.removeObject(forKey: Self.syncKey)
        use(local, folder: nil)
    }

    private func use(_ new: JobStore, folder: URL?) {
        model?.close()
        model = nil
        syncFolder?.stopAccessingSecurityScopedResource()
        syncFolder = folder
        store = new
        watch(folder)
        jobs = store.list()
        if jobs.contains(where: { $0.id == selection }) { open(selection) } else { selection = nil }
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
        j.updated = Int64(Date().timeIntervalSince1970 * 1000) // so the other device's save check and adopt see it
        try? store.save(j)
        replace(j)
    }
}
