import Foundation
import PDFKit

/** Each job is `jobs/<id>.json` plus its own copy of the plan at `jobs/<id>.pdf`, in Application Support. */
struct JobStore: Sendable {
    let dir: URL

    init(dir: URL? = nil) {
        let base = dir ?? URL.applicationSupportDirectory.appending(path: "Blueprint+/jobs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dir = base
    }

    func pdf(_ id: String) -> URL { dir.appending(path: "\(id).pdf") }
    private func json(_ id: String) -> URL { dir.appending(path: "\(id).json") }

    func list() -> [Job] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { load($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.updated > $1.updated }
    }

    func load(_ id: String) -> Job? { (try? Data(contentsOf: json(id))).flatMap { try? jobFromJson($0) } }

    /** Atomic: a crash mid-write leaves the previous version intact. */
    func save(_ job: Job) throws { try jobToJson(job).write(to: json(job.id), options: .atomic) }

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
        case unreadable
        var errorDescription: String? { "The file isn't a PDF that can be opened (it may be damaged or password-protected)." }
    }
}
