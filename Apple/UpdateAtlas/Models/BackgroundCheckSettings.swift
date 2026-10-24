import Foundation

enum BackgroundCheckSettings {
    static let enabledKey = "background-checks.enabled-v1"
    static let intervalKey = "background-checks.interval-v1"
    static let lastAttemptKey = "background-checks.last-attempt-v1"
    static let checkOnLaunchKey = "background-checks.check-on-launch-v1"
    static let defaultEnabled = false
    static let defaultInterval = CheckInterval.sixHours
    static let defaultCheckOnLaunch = true

    static func interval(in defaults: UserDefaults) -> CheckInterval {
        CheckInterval(rawValue: defaults.integer(forKey: intervalKey)) ?? defaultInterval
    }

    static func checkOnLaunch(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: checkOnLaunchKey) as? Bool ?? defaultCheckOnLaunch
    }

    static func nextCheck(in defaults: UserDefaults, now: Date) -> Date {
        let interval = interval(in: defaults).seconds
        let saved = defaults.object(forKey: lastAttemptKey) as? Date ?? now
        // Recover from clock changes or a corrupt/future preference without delaying indefinitely.
        let anchor = min(saved, now)
        return anchor.addingTimeInterval(interval)
    }
}

enum CheckInterval: Int, CaseIterable, Identifiable {
    case hourly = 1, threeHours = 3, sixHours = 6, twelveHours = 12, daily = 24
    var id: Int { rawValue }
    var seconds: TimeInterval { Double(rawValue) * 3_600 }
    var title: String {
        switch self {
        case .hourly: String(localized: "Every hour", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .threeHours: String(localized: "Every 3 hours", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .sixHours: String(localized: "Every 6 hours", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .twelveHours: String(localized: "Every 12 hours", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .daily: String(localized: "Every day", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

enum UpdateNotificationSettings {
    static let enabledKey = "notifications.updates-enabled-v1"
    static let soundKey = "notifications.sound-enabled-v1"
    static let notifyAppsKey = "notifications.notify-apps-v1"
    static let notifyGamesKey = "notifications.notify-games-v1"
    static let notifyPackagesKey = "notifications.notify-packages-v1"
    static let notifiedVersionsKey = "notifications.notified-versions-v1"
    static let defaultEnabled = true
    static let defaultSound = false
    static let defaultNotifyApps = true
    static let defaultNotifyGames = true
    static let defaultNotifyPackages = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func notifyApps(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notifyAppsKey) as? Bool ?? defaultNotifyApps
    }

    static func notifyGames(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notifyGamesKey) as? Bool ?? defaultNotifyGames
    }

    static func notifyPackages(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notifyPackagesKey) as? Bool ?? defaultNotifyPackages
    }
}

struct UpdateNotificationCandidate: Equatable {
    let id: String
    let fingerprint: String
    let name: String
    let version: String
}

/// Only a successfully accepted notification advances the persisted ledger.
struct UpdateNotificationLedger {
    let defaults: UserDefaults

    func pending(in items: [InstalledApplication]) -> [UpdateNotificationCandidate] {
        let sent = defaults.dictionary(forKey: UpdateNotificationSettings.notifiedVersionsKey) as? [String: [String]] ?? [:]
        let allowApps = UpdateNotificationSettings.notifyApps(in: defaults)
        let allowGames = UpdateNotificationSettings.notifyGames(in: defaults)
        let allowPackages = UpdateNotificationSettings.notifyPackages(in: defaults)
        var seen = Set<String>()
        return items.compactMap { item in
            guard item.updateCheck.availability == .updateAvailable,
                  !item.isExcludedFromMainUpdateList,
                  let version = item.updateCheck.latestVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !version.isEmpty, seen.insert(item.id).inserted else { return nil }
            if item.isPackageManagerItem {
                guard allowPackages else { return nil }
            } else if item.isGameRelated {
                guard allowGames else { return nil }
            } else {
                guard allowApps else { return nil }
            }
            let id = CLIInventoryQuery.opaqueID(item.id)
            let channel = item.updateCheck.releaseChannel ?? item.releaseChannel
            let fingerprint = CLIInventoryQuery.opaqueID(channel.rawValue + "\u{0}" + version)
            guard !(sent[id] ?? []).contains(fingerprint) else { return nil }
            return UpdateNotificationCandidate(id: id, fingerprint: fingerprint, name: item.name, version: version)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func record(_ candidates: [UpdateNotificationCandidate]) {
        var sent = defaults.dictionary(forKey: UpdateNotificationSettings.notifiedVersionsKey) as? [String: [String]] ?? [:]
        for candidate in candidates {
            sent[candidate.id] = Array(Set((sent[candidate.id] ?? []) + [candidate.fingerprint])).sorted()
        }
        defaults.set(sent, forKey: UpdateNotificationSettings.notifiedVersionsKey)
    }
}
