import Foundation
import Testing
@testable import UpdateAtlas

@Suite("Local installation and update history")
struct InstallationHistoryTests {
    private func item(_ id: String, version: String, kind: InventoryItemKind = .application) -> InstalledApplication {
        InstalledApplication(inventoryID: id, path: "/Applications/\(id).app", name: id,
            bundleIdentifier: "test.\(id)", displayVersion: version, buildVersion: version,
            teamIdentifier: nil, status: .supported, mechanism: .unknown, mechanismName: "Fixture",
            confidence: .verified, evidence: [], parentManagerBundleIdentifier: nil,
            parentManagerName: nil, vendorURL: nil, catalogEntryID: nil, notes: "", kind: kind,
            packageProvenance: nil)
    }

    private func file() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".temporary_files/history-tests/\(UUID().uuidString)/history.json")
    }

    @Test("First complete scan establishes a baseline; later scans persist new and changed versions")
    func recordsAndReloads() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var store = InstallationHistoryStore(fileURL: url)
        try store.recordScan([item("old", version: "1")], at: start, isComplete: true)
        #expect(store.events.isEmpty)
        try store.recordScan([item("old", version: "1"), item("new", version: "2")],
                             at: start.addingTimeInterval(60), isComplete: true)
        try store.recordScan([item("old", version: "3"), item("new", version: "2")],
                             at: start.addingTimeInterval(120), isComplete: true)
        let events = InstallationHistoryStore(fileURL: url).events
        #expect(events.count == 2)
        #expect(events[0].kind == .versionChanged)
        #expect(events[0].previousVersion == "1")
        #expect(events[0].version == "3")
        #expect(events[1].kind == .newlyDetected)
        #expect(events[1].observedAt == start.addingTimeInterval(60))
    }

    @Test("Partial scans cannot create new or replacement events")
    func partialAndReappearance() throws {
        var store = InstallationHistoryStore(fileURL: nil)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordScan([item("first", version: "1")], at: date, isComplete: false)
        #expect(store.events.isEmpty)
        try store.recordScan([item("first", version: "1")], at: date, isComplete: true)
        try store.recordScan([], at: date, isComplete: false)
        try store.recordScan([item("first", version: "2")], at: date, isComplete: true)
        #expect(store.events.map(\.kind) == [.versionChanged])
        try store.recordScan([item("other", version: "1")], at: date, isComplete: true)
        try store.recordScan([item("first", version: "2")], at: date, isComplete: true)
        #expect(store.events.contains { $0.itemID == "first" && $0.kind == .reappeared })
    }

    @Test("One-item reread records the installed version and repeated values do not duplicate it")
    func oneItemRefresh() throws {
        var store = InstallationHistoryStore(fileURL: nil)
        let before = item("app", version: "1")
        let after = item("app", version: "2")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.recordScan([before], at: date, isComplete: true)
        try store.recordRefresh(after, previous: before, at: date.addingTimeInterval(30))
        try store.recordScan([after], at: date.addingTimeInterval(60), isComplete: true)
        #expect(store.events.count == 1)
        #expect(store.events[0].previousVersion == "1")
        #expect(store.events[0].version == "2")
    }

    @Test("An unreadable existing file is preserved")
    func unreadableFile() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("corrupt".utf8)
        try original.write(to: url)
        var store = InstallationHistoryStore(fileURL: url)
        #expect(store.loadError != nil)
        #expect(throws: (any Error).self) {
            try store.recordScan([item("new", version: "1")], at: Date(), isComplete: true)
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
