import Foundation
import Testing
@testable import BlueprintPlus

// The sync-folder rules in JobStore: half-synced jobs, sync tools' copies, saves over another device's version.

private func tempStore() -> JobStore {
    JobStore(dir: FileManager.default.temporaryDirectory.appending(path: "JobStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory))
}

private func job(_ id: String, updated: Int64, name: String = "Smith") -> Job { Job(id: id, name: name, updated: updated, created: 1) }

private func addPdf(_ s: JobStore, _ id: String) throws { try Data("%PDF".utf8).write(to: s.pdf(id)) }

private func files(_ s: JobStore) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: s.dir.path)) ?? [])
}

@Suite struct JobStoreTests {
    @Test func jobWithoutItsPdfIsHidden() throws {
        let s = tempStore()
        try s.save(job("a", updated: 5))
        #expect(s.list().isEmpty)
        try addPdf(s, "a")
        #expect(s.list().map(\.id) == ["a"])
    }

    @Test func differentCopyBecomesAConflictJob() throws {
        let s = tempStore()
        try addPdf(s, "a")
        try s.save(job("a", updated: 5))
        try jobToJson(job("a", updated: 9)).write(to: s.dir.appending(path: "a (1).json"))
        let jobs = s.list()
        #expect(jobs.count == 2)
        let c = try #require(jobs.first { $0.id != "a" })
        #expect(c.name == "Smith (conflict)" && c.updated == 9)
        #expect(files(s) == ["a.json", "a.pdf", "\(c.id).json", "\(c.id).pdf"])
        #expect(s.list().count == 2) // not imported twice
    }

    @Test func identicalCopyIsDeleted() throws {
        let s = tempStore()
        try addPdf(s, "a")
        try s.save(job("a", updated: 5))
        try jobToJson(job("a", updated: 5)).write(to: s.dir.appending(path: "a.sync-conflict-20261123-120000-ABC.json"))
        #expect(s.list().map(\.id) == ["a"])
        #expect(files(s) == ["a.json", "a.pdf"])
    }

    @Test func copyWithoutTheOriginalTakesItsName() throws {
        let s = tempStore()
        try addPdf(s, "a")
        try jobToJson(job("a", updated: 5)).write(to: s.dir.appending(path: "a (1).json"))
        #expect(s.list().map(\.id) == ["a"])
        #expect(files(s) == ["a.json", "a.pdf"])
    }

    @Test func saveRefusesToOverwriteAnotherDevicesVersion() throws {
        let s = tempStore()
        try addPdf(s, "a")
        try s.save(job("a", updated: 5))
        try s.save(job("a", updated: 6), seen: 5) // ours: fine
        #expect(throws: JobStore.StoreError.changedElsewhere) { try s.save(job("a", updated: 7), seen: 5) }
        #expect(s.load("a")?.updated == 6)
    }

    @Test func saveRefusesToRecreateAJobDeletedElsewhere() throws {
        let s = tempStore()
        #expect(throws: JobStore.StoreError.deletedElsewhere) { try s.save(job("a", updated: 2), seen: 1) }
        try s.save(job("a", updated: 1)) // JSON synced back, PDF already deleted
        #expect(throws: JobStore.StoreError.deletedElsewhere) { try s.save(job("a", updated: 2), seen: 1) }
        try addPdf(s, "b") // PDF still here, JSON already deleted
        #expect(throws: JobStore.StoreError.deletedElsewhere) { try s.save(job("b", updated: 2), seen: 1) }
        #expect(files(s) == ["a.json", "b.pdf"])
    }

    @Test func saveLeavesAHalfSyncedFileAlone() throws {
        let s = tempStore()
        try addPdf(s, "a")
        let half = Data("{\"id\":\"a\",\"na".utf8)
        try half.write(to: s.dir.appending(path: "a.json"))
        #expect(throws: (any Error).self) { try s.save(job("a", updated: 2), seen: 1) }
        #expect(try Data(contentsOf: s.dir.appending(path: "a.json")) == half)
    }

    @Test func adoptKeepsTheLaterCopy() throws {
        let local = tempStore(), synced = tempStore()
        for (s, id, t) in [(local, "a", Int64(9)), (synced, "a", 5), (local, "b", 3), (synced, "c", 4)] {
            try addPdf(s, id); try s.save(job(id, updated: t))
        }
        try synced.adopt(local)
        #expect(Dictionary(uniqueKeysWithValues: synced.list().map { ($0.id, $0.updated) }) == ["a": 9, "b": 3, "c": 4])
        #expect(Set(local.list().map(\.id)) == ["a", "b"]) // left as it was
    }
}
