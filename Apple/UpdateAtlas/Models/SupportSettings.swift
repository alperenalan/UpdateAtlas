import Foundation

enum AboutLinks {
    static let repositoryURL = URL(string: "https://github.com/alperenalan/UpdateAtlas")!
    static let newIssueURL = URL(string: "https://github.com/alperenalan/UpdateAtlas/issues/new/choose")!
    static let websiteURL = URL(string: "https://alperenalan.com/")!
}

// A single reviewed destination for every support entry point. Leave blank until live.
enum SupportSettings {
    static var configuredURL: URL? {
        validatedURL(Bundle.main.object(forInfoDictionaryKey: "UASupportURL") as? String)
    }

    static func validatedURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct SupportPreferences {
    static let countKey = "support.successful-scan-count-v1"
    static let shownKey = "support.reminder-shown-v1"
    static let dismissedKey = "support.reminder-dismissed-v1"
    static let threshold = 3

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var successfulScanCount: Int {
        min(Self.threshold, max(0, defaults.integer(forKey: Self.countKey)))
    }

    var hasShownReminder: Bool { defaults.bool(forKey: Self.shownKey) }
    var hasDismissedReminder: Bool { defaults.bool(forKey: Self.dismissedKey) }

    func recordCompletedScan(successful: Bool, itemCount: Int) {
        guard successful, itemCount > 0 else { return }
        defaults.set(min(Self.threshold, successfulScanCount + 1), forKey: Self.countKey)
    }

    func shouldPresentReminder(destination: URL?) -> Bool {
        destination != nil && successfulScanCount >= Self.threshold
            && !hasShownReminder && !hasDismissedReminder
    }

    func markReminderShown() {
        defaults.set(true, forKey: Self.shownKey)
    }

    func dismissReminder() {
        markReminderShown()
        defaults.set(true, forKey: Self.dismissedKey)
    }
}
