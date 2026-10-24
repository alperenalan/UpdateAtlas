import Foundation

struct DiscoveryConfiguration: Sendable, Equatable {
    static let foldersKey = "discovery.application-folders"
    static let dockerKey = "discovery.docker-enabled"
    let folders: [URL]
    let includeDocker: Bool

    init(folders: [URL] = [], includeDocker: Bool = false) {
        self.folders = Array(Set(folders.filter { $0.isFileURL && $0.path.hasPrefix("/") }
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() })).sorted { $0.path < $1.path }
        self.includeDocker = includeDocker
    }

    static func current(from defaults: UserDefaults = .standard) -> Self {
        Self(folders: (defaults.stringArray(forKey: foldersKey) ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }, includeDocker: defaults.bool(forKey: dockerKey))
    }
}

// Additive shared facts, deliberately excluding paths, launch arguments, labels,
// environment variables and credentials. The CLI exposes the same local facts.
struct DiscoveryFacts: Codable, Hashable, Sendable {
    let source: String
    var role: String?
    var platform: String?
    var state: String?
    var imageID: String?
    var imageReference: String?
    var service: String?
    var storeGameID: String?
    var manifestVersion: String?

    var sourceTitle: String {
        switch source {
        case "Custom folder": String(localized: "Custom Folder", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "Application managers": String(localized: "Application Managers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "GOG manifest": String(localized: "GOG Manifest", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "Wine bottles": String(localized: "Wine Bottles", bundle: AppL10n.bundle, locale: AppL10n.locale)
        default: source
        }
    }
    var stateTitle: String? {
        switch state {
        case "running": String(localized: "Running", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "exited": String(localized: "Stopped", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "paused": String(localized: "Paused", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "restarting": String(localized: "Restarting", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "created": String(localized: "Created", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "removing": String(localized: "Removing", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "dead": String(localized: "Dead", bundle: AppL10n.bundle, locale: AppL10n.locale)
        default: state
        }
    }

    init?(_ info: [String: String]) {
        guard let source = info["DiscoverySource"] else { return nil }
        self.source = source
        role = info["DiscoveryRole"]
        platform = info["DiscoveryPlatform"]
        state = info["DiscoveryState"]
        imageID = info["DockerImageID"]
        imageReference = info["DockerImageReference"]
        service = info["ComposeService"]
        storeGameID = info["StoreGameID"]
        manifestVersion = info["ManifestVersion"].flatMap { $0 == "Unknown" ? nil : $0 }
    }
}
