import Foundation

/// A local observation log. Dates describe when Update Atlas saw a change, not when an
/// installer ran; a first scan cannot reconstruct installations that happened earlier.
struct InstallationHistoryEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case newlyDetected, reappeared, versionChanged }

    let id: UUID
    let itemID: String
    let name: String
    let kind: Kind
    let observedAt: Date
    let previousVersion: String?
    let version: String?
}

struct InstallationHistoryStore {
    private struct Observation: Codable {
        var name: String
        var version: String?
        var isPresent: Bool
    }

    private struct Document: Codable {
        var schemaVersion = 1
        var hasBaseline = false
        var observations: [String: Observation] = [:]
        var events: [InstallationHistoryEvent] = []
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("UpdateAtlas", isDirectory: true)
            .appendingPathComponent("installation-history-v1.json")
    }

    private let fileURL: URL?
    private var document: Document
    let loadError: Error?

    /// A nil URL is an in-memory store, useful for previews and injected inventory tests.
    init(fileURL: URL? = InstallationHistoryStore.defaultURL) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            document = Document()
            loadError = nil
            return
        }
        do {
            let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard decoded.schemaVersion == 1 else { throw HistoryError.unsupportedSchema }
            document = decoded
            loadError = nil
        } catch {
            // Never overwrite a history file that we cannot read.
            document = Document()
            loadError = error
        }
    }

    enum HistoryError: Error { case unsupportedSchema }

    var events: [InstallationHistoryEvent] {
        document.events.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func events(for itemID: String) -> [InstallationHistoryEvent] {
        events.filter { $0.itemID == itemID }
    }

    mutating func recordScan(_ items: [InstalledApplication], at date: Date, isComplete: Bool) throws {
        if let loadError { throw loadError }
        guard isComplete, !items.isEmpty else { return }
        var next = document
        let tracked = items.filter(Self.isTracked).reduce(into: [String: InstalledApplication]()) {
            $0[$1.id] = $1
        }
        for id in tracked.keys.sorted() {
            guard let item = tracked[id] else { continue }
            let version = Self.knownVersion(item)
            if let old = next.observations[id] {
                if !old.isPresent {
                    next.events.append(.init(id: UUID(), itemID: id, name: item.name,
                        kind: .reappeared, observedAt: date, previousVersion: nil, version: version))
                } else if let prior = old.version, let version, prior != version {
                    next.events.append(.init(id: UUID(), itemID: id, name: item.name,
                        kind: .versionChanged, observedAt: date, previousVersion: prior, version: version))
                }
            } else if next.hasBaseline {
                next.events.append(.init(id: UUID(), itemID: id, name: item.name,
                    kind: .newlyDetected, observedAt: date, previousVersion: nil, version: version))
            }
            next.observations[id] = Observation(name: item.name, version: version, isPresent: true)
        }
        for id in Array(next.observations.keys) where tracked[id] == nil {
            next.observations[id]?.isPresent = false
        }
        next.hasBaseline = true
        try save(next)
        document = next
    }

    mutating func recordRefresh(_ item: InstalledApplication, previous: InstalledApplication, at date: Date) throws {
        if let loadError { throw loadError }
        guard Self.isTracked(item), item.id == previous.id else { return }
        var next = document
        let oldVersion = next.observations[item.id]?.version ?? Self.knownVersion(previous)
        let newVersion = Self.knownVersion(item)
        if let oldVersion, let newVersion, oldVersion != newVersion {
            next.events.append(.init(id: UUID(), itemID: item.id, name: item.name,
                kind: .versionChanged, observedAt: date, previousVersion: oldVersion, version: newVersion))
        }
        next.observations[item.id] = Observation(name: item.name, version: newVersion, isPresent: true)
        try save(next)
        document = next
    }

    private func save(_ next: Document) throws {
        guard let fileURL else { return }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func knownVersion(_ item: InstalledApplication) -> String? {
        let version = item.displayVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version != "Unknown", version != "—" else { return nil }
        let build = item.buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return build.isEmpty || build == version ? version : "\(version) (\(build))"
    }

    private static func isTracked(_ item: InstalledApplication) -> Bool {
        switch item.kind {
        case .containerContext, .composeProject, .container, .containerImage, .containerVolume,
             .wineBottle, .virtualMachine: false
        default: true
        }
    }
}
