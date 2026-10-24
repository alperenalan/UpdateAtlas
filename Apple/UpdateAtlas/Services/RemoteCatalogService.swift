import Foundation
import Darwin

actor RemoteCatalogService {
    static let shared = RemoteCatalogService()

    private static let maximumCatalogSize = 2 * 1_024 * 1_024
    private let fileManager = FileManager.default
    private let session: URLSession
    private let endpointOverride: URL?
    private let cacheDirectoryOverride: URL?
    private let bundledCatalogURL: URL?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        session: URLSession? = nil,
        cacheDirectory: URL? = nil,
        bundledCatalogURL: URL? = BundledAppResources.bootstrapCatalogURL(),
        endpointOverride: URL? = nil
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
        self.endpointOverride = endpointOverride
        cacheDirectoryOverride = cacheDirectory
        self.bundledCatalogURL = bundledCatalogURL
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func snapshot(for purpose: CatalogLoadPurpose) async -> CatalogSnapshot {
        let bundled = loadBundledCatalog()
        let cached = usableCache(against: bundled)
        let endpoint = configuredEndpoint()

        if purpose.requiresRemoteRefresh,
           let endpoint {
            // A cached catalog only belongs to the endpoint that produced it. This
            // prevents a source change from silently inheriting another source's
            // rules or revision history when the new endpoint is unavailable.
            let endpointCache = cached?.metadata.url == endpoint.absoluteString ? cached : nil
            do {
                return try await fetchRemoteCatalog(from: endpoint, cached: endpointCache, bundled: bundled)
            } catch CatalogValidationError.rollback(let remote, let newer)
                        where newer == bundled.revision && remote < newer
                        && (endpointCache?.catalog.revision ?? 0) <= bundled.revision {
                // A newly released app can ship rules newer than the website's copy. That is expected,
                // not a failure: keep the bundled rules and say nothing until the site catches up.
                return CatalogSnapshot(catalog: bundled, source: .bundled, loadedAt: Date(), warning: nil)
            } catch {
                if configuredEndpoint() != endpoint {
                    return CatalogSnapshot(catalog: bundled, source: .bundled, loadedAt: Date(),
                                           warning: String(localized: "Remote catalog could not be loaded:", bundle: AppL10n.bundle, locale: AppL10n.locale)
                                            + " \(error.localizedDescription)")
                }
                // Another GUI or CLI request may have committed a newer catalog while
                // this request was in flight. Read that complete record again.
                let latest = usableCache(against: bundled)
                if let fallback = latest?.metadata.url == endpoint.absoluteString ? latest : endpointCache {
                    return CatalogSnapshot(
                        catalog: fallback.catalog,
                        source: .cache,
                        loadedAt: Date(),
                        warning: String(localized: "Remote catalog could not be refreshed:", bundle: AppL10n.bundle, locale: AppL10n.locale)
                            + " \(error.localizedDescription)"
                    )
                }

                return CatalogSnapshot(
                    catalog: bundled,
                    source: .bundled,
                    loadedAt: Date(),
                    warning: String(localized: "Remote catalog could not be loaded:", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        + " \(error.localizedDescription)"
                )
            }
        }

        if let endpoint,
           let cached,
           cached.metadata.url == endpoint.absoluteString {
            return CatalogSnapshot(
                catalog: cached.catalog,
                source: .cache,
                loadedAt: Date(),
                warning: purpose == .disabled
                    ? String(localized: "Catalog matching is disabled in Settings.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    : staleWarning(for: cached.catalog)
            )
        }

        return CatalogSnapshot(
            catalog: bundled,
            source: .bundled,
            loadedAt: Date(),
            warning: purpose == .disabled
                ? String(localized: "Catalog matching is disabled in Settings.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                : nil
        )
    }

    /// Future catalog-based install flows must call this before resolving a catalog update candidate.
    /// It intentionally bypasses URLSession caches and enforces revision rollback protection.
    func freshSnapshotBeforeUpdate() async -> CatalogSnapshot {
        await snapshot(for: .beforeUpdate)
    }

    private func configuredEndpoint() -> URL? {
        endpointOverride ?? CatalogSettings.validatedRemoteURL(CatalogSettings.officialRemoteURL)
    }

    private func fetchRemoteCatalog(
        from endpoint: URL,
        cached: CachedCatalogRecord?,
        bundled: RemoteCatalog
    ) async throws -> CatalogSnapshot {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("UpdateAtlas/1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        if let cached {
            if let etag = cached.metadata.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = cached.metadata.lastModified {
                request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https" else {
            throw URLError(.badServerResponse)
        }
        guard configuredEndpoint() == endpoint else { throw URLError(.cancelled) }

        if http.statusCode == 304, let cached {
            let latest = usableCache(against: bundled)
            let selected = latest.flatMap { $0.metadata.url == endpoint.absoluteString ? $0 : nil } ?? cached
            return CatalogSnapshot(catalog: selected.catalog, source: .cache, loadedAt: Date(), warning: staleWarning(for: selected.catalog))
        }

        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(Self.maximumCatalogSize) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(http.expectedContentLength), Self.maximumCatalogSize))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumCatalogSize {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }

        let catalog = try decoder.decode(RemoteCatalog.self, from: data)
        try CatalogValidator.validate(catalog, cached: cached?.catalog)
        try CatalogValidator.validate(catalog, cached: bundled)
        try rejectReusedRevision(catalog, comparedWith: cached?.catalog)
        try rejectReusedRevision(catalog, comparedWith: bundled)
        let record = CachedCatalogRecord(
            payload: data,
            metadata: CacheMetadata(
                url: endpoint.absoluteString,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            ),
            catalog: catalog
        )
        try withExclusiveCacheLock {
            guard configuredEndpoint() == endpoint else { throw URLError(.cancelled) }
            if let latest = usableCache(against: bundled), latest.metadata.url == endpoint.absoluteString {
                try CatalogValidator.validate(catalog, cached: latest.catalog)
                try rejectReusedRevision(catalog, comparedWith: latest.catalog)
            }
            try encoder.encode(StoredCacheRecord(payload: record.payload, metadata: record.metadata))
                .write(to: cacheRecordURL, options: .atomic)
        }

        return CatalogSnapshot(
            catalog: catalog,
            source: .remote(endpoint),
            loadedAt: Date(),
            warning: staleWarning(for: catalog)
        )
    }

    private func loadBundledCatalog() -> RemoteCatalog {
        guard let url = bundledCatalogURL,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumCatalogSize,
              let catalog = try? decoder.decode(RemoteCatalog.self, from: data),
              (try? CatalogValidator.validate(catalog)) != nil else {
            return RemoteCatalog(
                schemaVersion: RemoteCatalog.supportedSchemaVersion,
                catalogID: "bootstrap",
                revision: 0,
                generatedAt: Date(timeIntervalSince1970: 0),
                expiresAt: nil,
                entries: []
            )
        }
        return catalog
    }

    private func usableCache(against bundled: RemoteCatalog) -> CachedCatalogRecord? {
        guard let record = loadCacheRecord(),
              !(record.catalog.catalogID == bundled.catalogID && record.catalog.revision < bundled.revision),
              (try? CatalogValidator.validate(record.catalog, cached: bundled)) != nil,
              (try? rejectReusedRevision(record.catalog, comparedWith: bundled)) != nil else { return nil }
        return record
    }

    private func loadCacheRecord() -> CachedCatalogRecord? {
        guard let data = try? Data(contentsOf: cacheRecordURL),
              data.count <= 3 * Self.maximumCatalogSize,
              let stored = try? decoder.decode(StoredCacheRecord.self, from: data),
              stored.payload.count <= Self.maximumCatalogSize,
              let catalog = try? decoder.decode(RemoteCatalog.self, from: stored.payload),
              (try? CatalogValidator.validate(catalog)) != nil else { return nil }
        return CachedCatalogRecord(payload: stored.payload, metadata: stored.metadata, catalog: catalog)
    }

    private func rejectReusedRevision(_ catalog: RemoteCatalog, comparedWith existing: RemoteCatalog?) throws {
        guard let existing, existing.catalogID == catalog.catalogID,
              existing.revision == catalog.revision else { return }
        let oldContent = try encoder.encode(existing)
        let newContent = try encoder.encode(catalog)
        if oldContent != newContent {
            throw CatalogValidationError.reusedRevision(catalog.revision)
        }
    }

    private func staleWarning(for catalog: RemoteCatalog) -> String? {
        catalog.expiresAt.map { $0 < Date() } == true
            ? String(localized: "The remote catalog has expired.", bundle: AppL10n.bundle, locale: AppL10n.locale) : nil
    }

    private func withExclusiveCacheLock<T>(_ body: () throws -> T) throws -> T {
        try ensureCacheDirectory()
        let descriptor = cacheLockURL.path.withCString {
            open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return try body()
    }

    private struct CacheMetadata: Codable {
        let url: String
        let etag: String?
        let lastModified: String?
    }

    private struct StoredCacheRecord: Codable {
        let payload: Data
        let metadata: CacheMetadata
    }

    private struct CachedCatalogRecord {
        let payload: Data
        let metadata: CacheMetadata
        let catalog: RemoteCatalog
    }

    private func ensureCacheDirectory() throws {
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
    }

    private var cacheDirectoryURL: URL {
        if let cacheDirectoryOverride { return cacheDirectoryOverride }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("UpdateAtlas", isDirectory: true)
    }

    private var cacheRecordURL: URL {
        cacheDirectoryURL.appendingPathComponent("catalog-v1.cache.json")
    }

    private var cacheLockURL: URL {
        cacheDirectoryURL.appendingPathComponent("catalog-v1.lock")
    }
}
