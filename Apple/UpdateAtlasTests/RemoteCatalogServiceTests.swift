import Foundation
import Testing
@testable import UpdateAtlas

@Suite("Remote catalog transport and cache")
struct RemoteCatalogServiceTests {
    @Test("A valid response is persisted and can be read without another request")
    func successfulRefreshUsesEndpointBoundCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 7), headers: ["ETag": "\"r7\""])

        let remote = await fixture.service.snapshot(for: .scan)
        #expect(remote.source == .remote(fixture.endpoint))
        #expect(remote.catalog.revision == 7)
        #expect(remote.warning == nil)
        #expect(FileManager.default.fileExists(atPath:
            fixture.cacheDirectory.appendingPathComponent("catalog-v1.cache.json").path))
        #expect(!FileManager.default.fileExists(atPath:
            fixture.cacheDirectory.appendingPathComponent("catalog-v1.metadata.json").path))

        let offline = await fixture.service.snapshot(for: .disabled)
        #expect(offline.source == .cache)
        #expect(offline.catalog.revision == 7)
        #expect(fixture.requests.count == 1)
    }

    @Test("Concurrent service instances persist one complete cache record")
    func concurrentInstancesKeepCacheReadable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let peer = RemoteCatalogService(session: fixture.session,
                                        cacheDirectory: fixture.cacheDirectory,
                                        endpointOverride: fixture.endpoint)
        fixture.respond(status: 200, data: try catalogData(revision: 7))

        async let first = fixture.service.snapshot(for: .scan)
        async let second = peer.snapshot(for: .scan)
        let results = await (first, second)
        #expect(results.0.catalog.revision == 7)
        #expect(results.1.catalog.revision == 7)

        let record = fixture.cacheDirectory.appendingPathComponent("catalog-v1.cache.json")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any]
        #expect(payload?["metadata"] != nil)
        #expect(payload?["payload"] != nil)
        let offline = await peer.snapshot(for: .disabled)
        #expect(offline.source == .cache)
        #expect(offline.catalog.revision == 7)
    }

    @Test("A 304 reuses the matching cached catalog and sends conditional headers")
    func notModifiedUsesConditionalRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(
            status: 200,
            data: try catalogData(revision: 7),
            headers: [
                "ETag": "\"r7\"",
                "Last-Modified": "Wed, 23 Sep 2026 12:00:00 GMT"
            ]
        )
        _ = await fixture.service.snapshot(for: .scan)
        fixture.respond(status: 304)

        let refreshed = await fixture.service.snapshot(for: .scan)
        #expect(refreshed.source == .cache)
        #expect(refreshed.catalog.revision == 7)
        #expect(refreshed.warning == nil)
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"r7\"")
        #expect(
            fixture.requests.last?.value(forHTTPHeaderField: "If-Modified-Since")
                == "Wed, 23 Sep 2026 12:00:00 GMT"
        )
    }

    @Test("An expired cached catalog stays visibly expired after a 304")
    func notModifiedKeepsExpirationWarning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 7,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_100)))
        let first = await fixture.service.snapshot(for: .scan)
        #expect(first.warning != nil)
        fixture.respond(status: 304)
        let second = await fixture.service.snapshot(for: .scan)
        #expect(second.source == .cache)
        #expect(second.warning != nil)
    }

    @Test("A changed document cannot reuse a revision")
    func reusedRevisionKeepsOriginalCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 7))
        _ = await fixture.service.snapshot(for: .scan)
        fixture.respond(status: 200, data: try catalogData(revision: 7, entries: [sampleEntry()]))
        let rejected = await fixture.service.snapshot(for: .scan)
        #expect(rejected.source == .cache)
        #expect(rejected.catalog.entries.isEmpty)
        #expect(rejected.warning != nil)
    }

    @Test("A higher revision cannot silently remove a persisted rule ID")
    func removedRuleKeepsOriginalCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 7, entries: [sampleEntry()]))
        _ = await fixture.service.snapshot(for: .scan)
        fixture.respond(status: 200, data: try catalogData(revision: 8))
        let rejected = await fixture.service.snapshot(for: .scan)
        #expect(rejected.source == .cache)
        #expect(rejected.catalog.entries.map(\.id) == ["sample"])
        #expect(rejected.warning != nil)
    }

    @Test("A failed refresh keeps the last valid catalog for the same endpoint")
    func failedRefreshFallsBackToMatchingCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 8))
        _ = await fixture.service.snapshot(for: .scan)
        fixture.respond(status: 500)

        let result = await fixture.service.snapshot(for: .scan)
        #expect(result.source == .cache)
        #expect(result.catalog.revision == 8)
        #expect(result.warning != nil)
    }

    @Test("Changing endpoints never exposes the previous source's cached catalog")
    func switchedEndpointDoesNotInheritOldCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 99))
        _ = await fixture.service.snapshot(for: .scan)

        fixture.respond(status: 500, at: fixture.otherEndpoint)
        let otherSource = RemoteCatalogService(session: fixture.session,
                                               cacheDirectory: fixture.cacheDirectory,
                                               endpointOverride: fixture.otherEndpoint)

        let failedRefresh = await otherSource.snapshot(for: .scan)
        #expect(failedRefresh.source == .bundled)
        #expect(failedRefresh.catalog.revision != 99)
        #expect(failedRefresh.warning != nil)

        let disabled = await otherSource.snapshot(for: .disabled)
        #expect(disabled.source == .bundled)
        #expect(disabled.catalog.revision != 99)
    }

    @Test("A saved legacy source cannot redirect the official catalog")
    func savedLegacySourceIsIgnored() async throws {
        #expect(CatalogSettings.officialRemoteURL ==
                "https://updateatlas.alperenalan.com/api/update-atlas/catalog-v1.json")
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let official = try #require(URL(string: CatalogSettings.officialRemoteURL))
        defer { CatalogStubStore.shared.remove(official) }
        fixture.defaults.set(fixture.endpoint.absoluteString, forKey: "catalog.remote-url")
        CatalogStubStore.shared.set(.init(status: 200, data: try catalogData(revision: 16,
            catalogID: "update-atlas-bootstrap", entries: bundledEntries()), headers: [:]), for: official)
        let service = RemoteCatalogService(session: fixture.session,
                                           cacheDirectory: fixture.cacheDirectory)

        let result = await service.snapshot(for: .scan)
        #expect(result.source == .remote(official))
        #expect(fixture.requests.isEmpty)
    }

    @Test("A legacy split cache is ignored because its source cannot be proven")
    func legacySplitCacheCannotBindAnotherEndpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try catalogData(revision: 99).write(to:
            fixture.cacheDirectory.appendingPathComponent("catalog-v1.json"))
        try JSONSerialization.data(withJSONObject: ["url": fixture.endpoint.absoluteString])
            .write(to: fixture.cacheDirectory.appendingPathComponent("catalog-v1.metadata.json"))
        fixture.respond(status: 500)

        let result = await fixture.service.snapshot(for: .scan)
        #expect(result.source == .bundled)
        #expect(result.catalog.revision == 15)
    }

    @Test("A lower revision cannot replace the matching cached catalog")
    func rollbackKeepsCachedRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 8))
        _ = await fixture.service.snapshot(for: .scan)
        fixture.respond(status: 200, data: try catalogData(revision: 7))

        let rejected = await fixture.service.snapshot(for: .scan)
        #expect(rejected.source == .cache)
        #expect(rejected.catalog.revision == 8)
        #expect(rejected.warning?.contains(
            CatalogValidationError.rollback(remote: 7, cached: 8).localizedDescription
        ) == true)

        let persisted = await fixture.service.snapshot(for: .disabled)
        #expect(persisted.catalog.revision == 8)
    }

    @Test("An older official catalog cannot replace newer bundled rules")
    func olderOfficialRevisionKeepsBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: try catalogData(revision: 12, catalogID: "update-atlas-bootstrap"))

        let rejected = await fixture.service.snapshot(for: .scan)
        #expect(rejected.source == .bundled)
        #expect(rejected.catalog.revision == 15)
        // A website that lags behind the app's bundled rules is expected and shows no warning.
        #expect(rejected.warning == nil)

        fixture.respond(status: 200, data: try catalogData(revision: 16, catalogID: "update-atlas-bootstrap",
            entries: bundledEntries()))
        let current = await fixture.service.snapshot(for: .scan)
        #expect(current.source == .remote(fixture.endpoint))
        #expect(current.catalog.revision == 16)
    }

    @Test("A cached official catalog from an older app cannot displace newer bundled rules")
    func olderOfficialCacheKeepsBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.cacheDirectory, withIntermediateDirectories: true)
        try catalogData(revision: 12, catalogID: "update-atlas-bootstrap")
            .write(to: fixture.cacheDirectory.appendingPathComponent("catalog-v1.json"))
        try JSONSerialization.data(withJSONObject: ["url": fixture.endpoint.absoluteString])
            .write(to: fixture.cacheDirectory.appendingPathComponent("catalog-v1.metadata.json"))

        let offline = await fixture.service.snapshot(for: .localOnly)
        #expect(offline.source == .bundled)
        #expect(offline.catalog.revision == 15)

        fixture.respond(status: 200, data: try catalogData(revision: 16, catalogID: "update-atlas-bootstrap",
            entries: bundledEntries()))
        let refreshed = await fixture.service.snapshot(for: .scan)
        #expect(refreshed.source == .remote(fixture.endpoint))
        #expect(fixture.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("An oversized response is rejected before decoding or persistence")
    func oversizedResponseFallsBackToBundle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.respond(status: 200, data: Data(repeating: 0x20, count: 2 * 1_024 * 1_024 + 1))

        let result = await fixture.service.snapshot(for: .scan)
        #expect(result.source == .bundled)
        #expect(result.warning != nil)
        #expect(fixture.requests.count == 1)
    }

    @Test("Disabling catalog matching does not disable official catalog checks")
    func disabledMatchingStillRefreshesBeforeUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: CatalogSettings.matchingEnabledKey)
        fixture.respond(status: 200, data: try catalogData(revision: 7))

        let result = await fixture.service.freshSnapshotBeforeUpdate()
        #expect(result.source == .remote(fixture.endpoint))
        #expect(fixture.requests.count == 1)
    }

    private func catalogData(revision: Int, catalogID: String = "transport-test",
                             expiresAt: Date? = nil, entries: [CatalogEntry] = []) throws -> Data {
        let catalog = RemoteCatalog(
            schemaVersion: RemoteCatalog.supportedSchemaVersion,
            catalogID: catalogID,
            revision: revision,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: expiresAt,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    private func sampleEntry() -> CatalogEntry {
        CatalogEntry(id: "sample", displayName: "Sample",
            match: CatalogMatch(bundleIdentifiers: ["com.example.sample"], teamIdentifiers: nil,
                                pathSuffixes: nil),
            mechanism: CatalogMechanism(type: .externalManager, name: "Manager", feedURL: nil,
                                        managerBundleIdentifier: nil),
            support: .managedExternally, vendorURL: nil, notes: nil)
    }

    private func bundledEntries() -> [CatalogEntry] {
        let url = BundledAppResources.bootstrapCatalogURL()!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RemoteCatalog.self, from: Data(contentsOf: url)).entries) ?? []
    }
}

private struct Fixture {
    let endpoint: URL
    let otherEndpoint: URL
    let defaults: UserDefaults
    let session: URLSession
    let cacheDirectory: URL
    let service: RemoteCatalogService
    private let identifier: String
    private let suiteName: String

    init() throws {
        identifier = UUID().uuidString.lowercased()
        suiteName = AppIdentity.bundleIdentifier + ".tests.catalog.\(identifier)"
        endpoint = try #require(URL(string: "https://\(identifier).example.test/catalog.json"))
        otherEndpoint = try #require(URL(string: "https://\(identifier).example.test/other.json"))
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogStubProtocol.self]
        session = URLSession(configuration: configuration)
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        cacheDirectory = projectRoot
            .appendingPathComponent(".temporary_files/catalog-tests/\(identifier)", isDirectory: true)
        service = RemoteCatalogService(
            session: session,
            cacheDirectory: cacheDirectory,
            endpointOverride: endpoint
        )
    }

    var requests: [URLRequest] {
        CatalogStubStore.shared.requests(for: endpoint)
    }

    func respond(
        status: Int,
        data: Data = Data(),
        headers: [String: String] = [:],
        at url: URL? = nil
    ) {
        CatalogStubStore.shared.set(
            .init(status: status, data: data, headers: headers),
            for: url ?? endpoint
        )
    }

    func cleanUp() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        CatalogStubStore.shared.remove(endpoint)
        CatalogStubStore.shared.remove(otherEndpoint)
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

private struct CatalogStubResponse {
    let status: Int
    let data: Data
    let headers: [String: String]
}

/// URLProtocol runs on URLSession threads; the lock protects parallel Swift Testing cases.
private final class CatalogStubStore: @unchecked Sendable {
    static let shared = CatalogStubStore()

    private let lock = NSLock()
    private var responses: [URL: CatalogStubResponse] = [:]
    private var recordedRequests: [URL: [URLRequest]] = [:]

    func set(_ response: CatalogStubResponse, for url: URL) {
        lock.withLock { responses[url] = response }
    }

    func response(for request: URLRequest) -> CatalogStubResponse? {
        lock.withLock {
            guard let url = request.url else { return nil }
            recordedRequests[url, default: []].append(request)
            return responses[url]
        }
    }

    func requests(for url: URL) -> [URLRequest] {
        lock.withLock { recordedRequests[url] ?? [] }
    }

    func remove(_ url: URL) {
        lock.withLock {
            responses.removeValue(forKey: url)
            recordedRequests.removeValue(forKey: url)
        }
    }
}

private final class CatalogStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let stub = CatalogStubStore.shared.response(for: request),
              let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.data.isEmpty {
            client?.urlProtocol(self, didLoad: stub.data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
