import Foundation

struct RemoteCatalog: Codable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let catalogID: String
    let revision: Int
    let generatedAt: Date
    let expiresAt: Date?
    let entries: [CatalogEntry]
}

struct CatalogEntry: Codable, Identifiable, Sendable {
    let id: String
    let displayName: String?
    /// Presentation-only company or brand. It never participates in matching or rule identity.
    let publisher: String?
    let match: CatalogMatch
    let mechanism: CatalogMechanism
    let support: CatalogSupport
    let vendorURL: URL?
    let openSource: Bool?
    let sourceCodeURL: URL?
    let releaseNotesURL: URL?
    let notes: String?

    init(
        id: String,
        displayName: String?,
        publisher: String? = nil,
        match: CatalogMatch,
        mechanism: CatalogMechanism,
        support: CatalogSupport,
        vendorURL: URL?,
        openSource: Bool? = nil,
        sourceCodeURL: URL? = nil,
        releaseNotesURL: URL? = nil,
        notes: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.publisher = publisher
        self.match = match
        self.mechanism = mechanism
        self.support = support
        self.vendorURL = vendorURL
        self.openSource = openSource
        self.sourceCodeURL = sourceCodeURL
        self.releaseNotesURL = releaseNotesURL
        self.notes = notes
    }
}

/// Presentation groups use stable mechanism IDs; catalog/rule identities stay unchanged.
struct CatalogPublisherGroup: Identifiable {
    enum Category: String, CaseIterable {
        case githubReleases, builtInUpdater, managedSoftware, vendorWebsite, other

        var title: String {
            switch self {
            case .githubReleases: "GitHub Releases"
            case .builtInUpdater: String(localized: "Built-in Updaters", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .managedSoftware: String(localized: "Managed Software", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .vendorWebsite: String(localized: "Vendor Websites", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .other: String(localized: "Other Sources", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }

        static func category(for entry: CatalogEntry) -> Self {
            switch entry.mechanism.type {
            case .sparkle, .squirrel, .googleUpdater: return .builtInUpdater
            case .githubReleases: return .githubReleases
            case .externalManager:
                return entry.mechanism.managerBundleIdentifier == nil ? .builtInUpdater : .managedSoftware
            case .appStore, .system, .homebrew, .npm, .python,
                 .pipx, .uvTool, .cargo, .ideExtension: return .managedSoftware
            default:
                if entry.mechanism.versionProviders.first?.type == .githubLatestRelease {
                    return .githubReleases
                }
                if entry.mechanism.type == .website {
                    // Presentation-only distinction for vendor checks of self-updating apps.
                    return entry.mechanism.name.localizedStandardContains("Updater") ? .builtInUpdater : .vendorWebsite
                }
                return .other
            }
        }
    }

    let category: Category
    let entries: [CatalogEntry]
    var id: String { category.rawValue }
    var title: String { category.title }

    static func matching(_ entries: [CatalogEntry], query: String) -> [Self] {
        matching(sorted(entries), query: query)
    }

    static func matching(_ groups: [Self], query: String) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            if query.isEmpty || group.title.localizedStandardContains(query) { return group }
            let matches = group.entries.filter { entry in
                [entry.displayName ?? "", entry.publisher ?? "", entry.id, entry.mechanism.name]
                    .contains { $0.localizedStandardContains(query) }
                    || (entry.match.bundleIdentifiers ?? []).contains { $0.localizedStandardContains(query) }
            }
            return matches.isEmpty ? nil : Self(category: group.category, entries: matches)
        }
    }

    static func automaticallyExpandedIDs(in matches: [Self], limit: Int = 40) -> Set<String> {
        let resultCount = matches.reduce(0) { $0 + $1.entries.count }
        return resultCount <= limit ? Set(matches.map(\.id)) : []
    }

    static func sorted(_ entries: [CatalogEntry]) -> [Self] {
        let grouped = Dictionary(grouping: entries, by: Category.category(for:))
        return Category.allCases.compactMap { category in
            guard let rules = grouped[category] else { return nil }
            return Self(category: category, entries: rules.sorted {
                let order = ($0.displayName ?? $0.id).localizedStandardCompare($1.displayName ?? $1.id)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            })
        }
    }
}

struct CatalogMatch: Codable, Sendable {
    let bundleIdentifiers: [String]?
    let teamIdentifiers: [String]?
    let pathSuffixes: [String]?
    let executableNames: [String]?

    init(
        bundleIdentifiers: [String]?,
        teamIdentifiers: [String]?,
        pathSuffixes: [String]?,
        executableNames: [String]? = nil
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.teamIdentifiers = teamIdentifiers
        self.pathSuffixes = pathSuffixes
        self.executableNames = executableNames
    }

    func matches(_ candidate: ApplicationCandidate) -> Bool {
        let configuredBundles = bundleIdentifiers?.filter { !$0.isEmpty } ?? []
        let configuredTeams = teamIdentifiers?.filter { !$0.isEmpty } ?? []
        let configuredPaths = pathSuffixes?.filter { !$0.isEmpty } ?? []
        let configuredExecutables = executableNames?.filter { !$0.isEmpty } ?? []

        let teamMatches: Bool = {
            guard !configuredTeams.isEmpty else { return true }
            guard let teamIdentifier = candidate.teamIdentifier else { return false }
            return configuredTeams.contains { Self.identityEquals($0, teamIdentifier) }
        }()

        if !configuredBundles.isEmpty {
            let bundleMatches = configuredBundles.contains {
                Self.identityEquals($0, candidate.bundleIdentifier)
            }
            // A stable bundle identifier is the primary identity. Paths and localized
            // display names must never be additional requirements for this branch.
            return bundleMatches && teamMatches
        }

        guard teamMatches else { return false }

        let executableMatches = !configuredExecutables.isEmpty
            && candidate.info["CFBundleExecutable"].map { executable in
                configuredExecutables.contains { Self.identityEquals($0, executable) }
            } == true
        let pathMatches = !configuredPaths.isEmpty
            && configuredPaths.contains { Self.normalizedPath(candidate.path).hasSuffix(Self.normalizedPath($0)) }

        if !configuredExecutables.isEmpty || !configuredPaths.isEmpty {
            return executableMatches || pathMatches
        }

        return !configuredTeams.isEmpty
    }

    private static func identityEquals(_ lhs: String, _ rhs: String) -> Bool {
        normalizedIdentity(lhs) == normalizedIdentity(rhs)
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizedPath(_ value: String) -> String {
        normalizedIdentity(value.replacingOccurrences(of: "\\", with: "/"))
    }
}

struct CatalogMechanism: Codable, Sendable {
    let type: UpdateMechanismKind
    let name: String
    let feedURL: URL?
    let managerBundleIdentifier: String?
    let provider: CatalogVersionProvider?
    let providers: [CatalogVersionProvider]?

    var versionProviders: [CatalogVersionProvider] {
        if let providers, !providers.isEmpty { return providers }
        return provider.map { [$0] } ?? []
    }

    init(
        type: UpdateMechanismKind,
        name: String,
        feedURL: URL?,
        managerBundleIdentifier: String?,
        provider: CatalogVersionProvider? = nil,
        providers: [CatalogVersionProvider]? = nil
    ) {
        self.type = type
        self.name = name
        self.feedURL = feedURL
        self.managerBundleIdentifier = managerBundleIdentifier
        self.provider = provider
        self.providers = providers
    }
}

struct CatalogVersionProvider: Codable, Hashable, Sendable {
    let type: CatalogVersionProviderKind
    let url: URL
    let channel: String?
    let identifier: String?
    let targetPlatform: String?
    let hostVersion: String?
    let includePrerelease: Bool?
    let versionPrefix: String?
    let versionRegex: String?
    let releaseChannel: ReleaseChannel?

    init(
        type: CatalogVersionProviderKind,
        url: URL,
        channel: String?,
        identifier: String? = nil,
        targetPlatform: String? = nil,
        hostVersion: String? = nil,
        includePrerelease: Bool? = nil,
        versionPrefix: String? = nil,
        versionRegex: String? = nil,
        releaseChannel: ReleaseChannel? = nil
    ) {
        self.type = type
        self.url = url
        self.channel = channel
        self.identifier = identifier
        self.targetPlatform = targetPlatform
        self.hostVersion = hostVersion
        self.includePrerelease = includePrerelease
        self.versionPrefix = versionPrefix
        self.versionRegex = versionRegex
        self.releaseChannel = releaseChannel
    }
}

enum CatalogVersionProviderKind: String, Codable, Sendable {
    case sparkleAppcast
    case chromeVersionHistory
    case githubLatestRelease
    case platformDownloadPage
    case githubCommitCompare
    case electronYAML
    case visualStudioCode
    case blenderDownloadPage
    case homebrewCask
    case androidStudioReleasePage
    case canonSupportRelease
    case appleAppStoreLookup
    case jsonVersion
    case visualStudioMarketplace
    case minecraftVersionManifest
}

enum CatalogSupport: String, Codable, Sendable {
    case supported
    case managedExternally
    case needsCatalog
    case unsupported

    var appStatus: UpdateSupportStatus {
        switch self {
        case .supported: .supported
        case .managedExternally: .managedExternally
        case .needsCatalog: .needsCatalog
        case .unsupported: .unsupported
        }
    }
}

enum CatalogLoadPurpose: Equatable, Sendable {
    case applicationLaunch
    case scan
    case localOnly
    case beforeUpdate
    case disabled

    var requiresRemoteRefresh: Bool {
        switch self {
        case .applicationLaunch, .scan, .beforeUpdate: true
        case .localOnly, .disabled: false
        }
    }
}

enum CatalogSnapshotSource: Equatable, Sendable {
    case remote(URL)
    case cache
    case bundled

    var title: String {
        switch self {
        case .remote: String(localized: "Remote catalog", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .cache: String(localized: "Cached catalog", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .bundled: String(localized: "Built-in catalog", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

struct CatalogSnapshot: Sendable {
    let catalog: RemoteCatalog
    let source: CatalogSnapshotSource
    let loadedAt: Date
    let warning: String?

    var isStale: Bool {
        guard let expiresAt = catalog.expiresAt else { return false }
        return expiresAt < Date()
    }
}

enum CatalogSettings {
    static let officialRemoteURL = "https://updateatlas.alperenalan.com/api/update-atlas/catalog-v1.json"
    static let matchingEnabledKey = "catalog.matching-enabled"
    static let defaultMatchingEnabled = true
    static let disabledRuleKeysKey = "catalog.disabled-rule-keys"

    static func validatedRemoteURL(_ value: String) -> URL? {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
}

enum CatalogActivationPolicy {
    static func ruleKey(catalogID: String, entryID: String) -> String {
        "\(catalogID)::\(entryID)"
    }

    static func applying(
        to catalog: RemoteCatalog,
        matchingEnabled: Bool,
        disabledRuleKeys: Set<String>
    ) -> RemoteCatalog {
        let activeEntries = matchingEnabled
            ? catalog.entries.filter { entry in
                !disabledRuleKeys.contains(
                    ruleKey(catalogID: catalog.catalogID, entryID: entry.id)
                )
            }
            : []

        return RemoteCatalog(
            schemaVersion: catalog.schemaVersion,
            catalogID: catalog.catalogID,
            revision: catalog.revision,
            generatedAt: catalog.generatedAt,
            expiresAt: catalog.expiresAt,
            entries: activeEntries
        )
    }
}

enum CatalogValidationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case emptyCatalogID
    case invalidRevision
    case generatedInFuture
    case duplicateEntryID(String)
    case emptyBundleIdentifiers(String)
    case invalidPublisher(String)
    case insecureURL(String)
    case missingVersionProvider(String)
    case invalidPlatformProvider(String)
    case rollback(remote: Int, cached: Int)
    case removedEntryID(String)
    case reusedRevision(Int)
    case invalidMatchIdentity(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): String(format: String(localized: "Catalog schema %d is not supported.", bundle: AppL10n.bundle, locale: AppL10n.locale), version)
        case .emptyCatalogID: String(localized: "Catalog ID cannot be empty.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .invalidRevision: String(localized: "Catalog revision must be zero or greater.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .generatedInFuture: String(localized: "Catalog generation date is unexpectedly in the future.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .duplicateEntryID(let id): String(format: String(localized: "Catalog contains duplicate entry ID: %@.", bundle: AppL10n.bundle, locale: AppL10n.locale), id)
        case .emptyBundleIdentifiers(let id): String(format: String(localized: "Catalog entry %@ has no bundle identifier.", bundle: AppL10n.bundle, locale: AppL10n.locale), id)
        case .invalidPublisher(let id): String(format: String(localized: "Catalog entry %@ has an invalid publisher label.", bundle: AppL10n.bundle, locale: AppL10n.locale), id)
        case .insecureURL(let value): String(format: String(localized: "Catalog URL must use HTTPS: %@.", bundle: AppL10n.bundle, locale: AppL10n.locale), value)
        case .missingVersionProvider(let id): String(format: String(localized: "Supported catalog entry %@ must provide a version provider.", bundle: AppL10n.bundle, locale: AppL10n.locale), id)
        case .invalidPlatformProvider(let id): String(format: String(localized: "Platform download provider in %@ must declare a platform and a valid version capture.", bundle: AppL10n.bundle, locale: AppL10n.locale), id)
        case .rollback(let remote, let cached): String(format: String(localized: "Remote catalog revision %d is older than available revision %d.", bundle: AppL10n.bundle, locale: AppL10n.locale), remote, cached)
        case .removedEntryID(_), .reusedRevision(_), .invalidMatchIdentity(_):
            String(localized: "Catalog content failed integrity checks.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

enum CatalogValidator {
    static func validate(_ catalog: RemoteCatalog, cached: RemoteCatalog? = nil, now: Date = Date()) throws {
        guard catalog.schemaVersion == RemoteCatalog.supportedSchemaVersion else {
            throw CatalogValidationError.unsupportedSchema(catalog.schemaVersion)
        }
        guard !catalog.catalogID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogValidationError.emptyCatalogID
        }
        guard catalog.revision >= 0 else { throw CatalogValidationError.invalidRevision }
        guard catalog.generatedAt <= now.addingTimeInterval(5 * 60) else {
            throw CatalogValidationError.generatedInFuture
        }

        var ids = Set<String>()
        for entry in catalog.entries {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(entry.id).inserted else {
                throw CatalogValidationError.duplicateEntryID(entry.id)
            }
            if let publisher = entry.publisher {
                let trimmed = publisher.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, publisher.count <= 120 else {
                    throw CatalogValidationError.invalidPublisher(entry.id)
                }
            }
            let hasBundleIdentity = !(entry.match.bundleIdentifiers?.isEmpty ?? true)
            let hasPathIdentity = !(entry.match.pathSuffixes?.isEmpty ?? true)
            let hasExecutableIdentity = !(entry.match.executableNames?.isEmpty ?? true)
            guard hasBundleIdentity || hasPathIdentity || hasExecutableIdentity else {
                throw CatalogValidationError.emptyBundleIdentifiers(entry.id)
            }
            let identities = [entry.match.bundleIdentifiers, entry.match.teamIdentifiers,
                              entry.match.pathSuffixes, entry.match.executableNames]
                .compactMap { $0 }.flatMap { $0 }
            guard identities.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  hasBundleIdentity || !(entry.match.teamIdentifiers?.isEmpty ?? true) else {
                throw CatalogValidationError.invalidMatchIdentity(entry.id)
            }
            if let providers = entry.mechanism.providers, providers.isEmpty {
                throw CatalogValidationError.missingVersionProvider(entry.id)
            }
            if entry.support == .supported,
               entry.mechanism.versionProviders.isEmpty,
               entry.mechanism.feedURL == nil,
               entry.mechanism.type != .appStore {
                throw CatalogValidationError.missingVersionProvider(entry.id)
            }
            let providerURLs = entry.mechanism.versionProviders.map(\.url)
            for provider in entry.mechanism.versionProviders where provider.type == .platformDownloadPage {
                guard let platform = provider.targetPlatform, !platform.isEmpty, platform.count <= 40,
                      let pattern = provider.versionRegex, pattern.count <= 200,
                      let expression = try? NSRegularExpression(pattern: pattern),
                      expression.numberOfCaptureGroups >= 1 else {
                    throw CatalogValidationError.invalidPlatformProvider(entry.id)
                }
            }
            for url in ([
                entry.mechanism.feedURL,
                entry.vendorURL,
                entry.sourceCodeURL,
                entry.releaseNotesURL
            ].compactMap({ $0 }) + providerURLs) {
                guard url.scheme?.lowercased() == "https", url.host != nil,
                      url.user == nil, url.password == nil else {
                    throw CatalogValidationError.insecureURL(url.absoluteString)
                }
            }
        }

        if let cached,
           cached.catalogID == catalog.catalogID,
           catalog.revision < cached.revision {
            throw CatalogValidationError.rollback(remote: catalog.revision, cached: cached.revision)
        }
        if let cached, cached.catalogID == catalog.catalogID {
            let ids = Set(catalog.entries.map(\.id))
            if let removed = cached.entries.first(where: { !ids.contains($0.id) }) {
                throw CatalogValidationError.removedEntryID(removed.id)
            }
        }
    }
}
