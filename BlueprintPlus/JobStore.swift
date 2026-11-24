import Foundation
import PDFKit

/**
 * Each job is `<id>.json` plus its own copy of the plan at `<id>.pdf`, in Application Support's `jobs`, or in the sync
 * folder the user picked (a folder a sync tool shares with the phone).
 */
struct JobStore: Sendable {
    let dir: URL

    init(dir: URL? = nil) {
        let base = dir ?? URL.applicationSupportDirectory.appending(path: "Blueprint+/jobs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dir = base
    }

    func pdf(_ id: String) -> URL { dir.appending(path: "\(id).pdf") }
    private func json(_ id: String) -> URL { dir.appending(path: "\(id).json") }

    /**
     * The jobs whose PDF is here (a sync tool may bring the JSON first). A JSON not named `<id>.json` is a sync tool's
     * copy (`<id> (1).json`, `<id>.sync-conflict-….json`): the same as the job, it's deleted; different, it becomes its
     * own "(conflict)" job; with no `<id>.json`, it takes that name.
     */
    func list() -> [Job] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { $0.pathExtension == "json" }
        var jobs: [String: Job] = [:]
        var strays: [(URL, Job)] = []
        for f in files {
            guard let j = (try? Data(contentsOf: f)).flatMap({ try? jobFromJson($0) }) else { continue }
            if f.deletingPathExtension().lastPathComponent == j.id { jobs[j.id] = j } else { strays.append((f, j)) }
        }
        for (f, j) in strays where fm.fileExists(atPath: pdf(j.id).path) {
            if jobs[j.id] == nil {
                if (try? fm.moveItem(at: f, to: json(j.id))) != nil { jobs[j.id] = j }
            } else if jobs[j.id] == j {
                try? fm.removeItem(at: f)
            } else if let c = try? saveAsConflict(j) {
                jobs[c.id] = c
                try? fm.removeItem(at: f)
            }
        }
        return jobs.values.filter { fm.fileExists(atPath: pdf($0.id).path) }.sorted { $0.updated > $1.updated }
    }

    func load(_ id: String) -> Job? { (try? Data(contentsOf: json(id))).flatMap { try? jobFromJson($0) } }

    /** Atomic: a crash mid-write leaves the previous version intact. */
    func save(_ job: Job) throws { try jobToJson(job).write(to: json(job.id), options: .atomic) }

    /**
     * Saves unless another device changed the file since this one last loaded or saved it (`seen`, that version's
     * `updated`): then throws `changedElsewhere`. Compared for equality, so the devices' clocks don't matter.
     */
    func save(_ job: Job, seen: Int64) throws {
        // Writing it back would leave a JSON no device lists once its PDF is gone.
        guard exists(job.id) else { throw StoreError.deletedElsewhere }
        // shortcut: a sync landing between this check and the write is still overwritten; it's a few ms wide.
        // A half-synced JSON throws here (not overwritten); the next edit tries again.
        if try jobFromJson(Data(contentsOf: json(job.id))).updated != seen { throw StoreError.changedElsewhere }
        try save(job)
    }

    /** Both of the job's files are here; a delete on another device removes them, maybe one sync at a time. */
    func exists(_ id: String) -> Bool { [json(id), pdf(id)].allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }

    /** Saves `job` as a new job named "<name> (conflict)", with its own copy of the PDF. */
    func saveAsConflict(_ job: Job) throws -> Job {
        var c = job
        c.id = UUID().uuidString.lowercased()
        c.name = job.name + " (conflict)"
        try FileManager.default.copyItem(at: pdf(job.id), to: pdf(c.id))
        do { try save(c) } catch { try? FileManager.default.removeItem(at: pdf(c.id)); throw error }
        return c
    }

    /** Copies `other`'s jobs in; a job both have keeps the later-saved copy. `other` is left as it was. */
    func adopt(_ other: JobStore) throws {
        let fm = FileManager.default
        let here = Dictionary(uniqueKeysWithValues: list().map { ($0.id, $0.updated) })
        for j in other.list() where j.updated > here[j.id] ?? .min {
            if !fm.fileExists(atPath: pdf(j.id).path) { try fm.copyItem(at: other.pdf(j.id), to: pdf(j.id)) }
            try save(j)
        }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: json(id))
        try? FileManager.default.removeItem(at: pdf(id))
    }

    /** Copies the PDF in (the picked file may move or vanish) and creates a job named after the file. */
    func create(from url: URL) throws -> Job {
        let id = UUID().uuidString.lowercased()
        let dest = pdf(id)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            // Fail now, not on open, if it's corrupt or password-protected.
            guard let doc = PDFDocument(url: dest), !doc.isLocked, doc.pageCount > 0 else { throw StoreError.unreadable }
            let name = url.deletingPathExtension().lastPathComponent
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let found = findPlanScale(dest, doc)
            let job = Job(id: id, name: name.isEmpty ? "New job" : name, scale: found ?? Job(id: id, name: name).scale,
                          updated: now, created: now, scaleSet: false, foundScale: found)
            try save(job)
            return job
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    /**
     * The scale saved in the PDF's own data, else page by page (`pickPlanScale`: the first page with a `= 1'` scale,
     * so detail sheets' callouts can't outvote the plan and a site sheet before it doesn't win); nil if none.
     */
    private func findPlanScale(_ url: URL, _ doc: PDFDocument) -> String? {
        // shortcut: scaleInPdf holds ~3x the file in memory, so bigger files (mostly scans) skip it; stream it if a
        // large calibrated plan needs it.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if size <= 32 << 20, let data = try? Data(contentsOf: url), let s = scaleInPdf(data) { return s }
        let texts = (0..<doc.pageCount).lazy.map { doc.page(at: $0)?.string }
        // a drawing's own caption (`Scale 3/16" = 1'`) beats a bare title-block field, which can be a template left at 1/4"
        return pickPlanScale(texts.map { $0.flatMap { findScale($0, captioned: true) } }) ?? pickPlanScale(texts.map { $0.flatMap { findScale($0) } })
    }

    enum StoreError: LocalizedError {
        case unreadable, changedElsewhere, deletedElsewhere
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't a PDF that can be opened (it may be damaged or password-protected)."
            case .changedElsewhere: "The job was changed on another device."
            case .deletedElsewhere: "The job was deleted on another device."
            }
        }
    }
}
