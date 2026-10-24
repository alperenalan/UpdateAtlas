import Foundation

enum MenuBarSettings {
    static let enabledKey = "menuBar.enabled"
    static let showCountKey = "menuBar.showUpdateCount"
    // Keep the persisted key: the preference now controls icons in the update menu, not the status button.
    static let showAppIconsKey = "menuBar.showUpdateAppIcons"
    static let defaultEnabled = true
    static let defaultShowCount = true
    static let defaultShowAppIcons = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func showAppIcons(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showAppIconsKey) as? Bool ?? defaultShowAppIcons
    }
}

struct MenuBarUpdateSummary: Equatable {
    let applications: Int
    let games: Int
    let packages: Int

    var total: Int { applications + games + packages }

    static func count(_ installed: [InstalledApplication]) -> Self {
        var seenIDs = Set<String>()
        var applications = 0
        var games = 0
        var packages = 0

        for item in installed where item.updateCheck.availability == .updateAvailable && !item.isExcludedFromMainUpdateList {
            guard seenIDs.insert(item.id).inserted else { continue }
            if item.isPackageManagerItem {
                packages += 1
            } else if item.isGameRelated {
                games += 1
            } else {
                applications += 1
            }
        }

        return Self(applications: applications, games: games, packages: packages)
    }
}

/// The badge and actionable menu list share the same canonical set of confirmed updates.
enum MenuBarUpdateList {
    static func items(in installed: [InstalledApplication]) -> [InstalledApplication] {
        var seen = Set<String>()
        return installed.filter {
            $0.updateCheck.availability == .updateAvailable
                && !$0.isExcludedFromMainUpdateList
                && seen.insert($0.id).inserted
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

enum MenuBarUpdateAction: Equatable {
    case update
    case appStore
    case openManager
    case openApplication
    case openReleasePage
    case openWebsite
    case inspect

    static func safeWebURL(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        return url
    }

    static func releasePageURL(for application: InstalledApplication) -> URL? {
        safeWebURL(application.updateCheck.releaseNotesURL) ?? safeWebURL(application.releaseNotesURL)
    }

    static func choose(
        for application: InstalledApplication,
        updateAction: ManagerUpdatePolicy.Action?,
        managerAvailable: Bool,
        applicationAvailable: Bool
    ) -> Self {
        if updateAction == .appStorePage || application.mechanism == .appStore { return .appStore }
        if updateAction != nil { return .update }
        if managerAvailable { return .openManager }
        if applicationAvailable { return .openApplication }
        return .inspect
    }

    static func inlineOpen(
        for application: InstalledApplication,
        updateAction: ManagerUpdatePolicy.Action?,
        managerAvailable: Bool,
        applicationAvailable: Bool,
        releasePageAvailable: Bool = false,
        websiteAvailable: Bool = false
    ) -> Self? {
        guard application.updateCheck.availability == .updateAvailable,
              !application.isExcludedFromMainUpdateList,
              updateAction == nil, application.mechanism != .appStore else { return nil }
        if managerAvailable { return .openManager }
        if [.sparkle, .squirrel, .googleUpdater].contains(application.mechanism),
           applicationAvailable { return .openApplication }
        if releasePageAvailable { return .openReleasePage }
        if websiteAvailable { return .openWebsite }
        if applicationAvailable && application.mechanism != .externalManager
            && application.mechanism != .ideExtension { return .openApplication }
        return nil
    }
}
