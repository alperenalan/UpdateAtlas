import Foundation

/// Shared persisted defaults used by the app and its standalone CLI.
enum LaunchAtLoginSettings {
    static let enabledKey = "launchAtLogin.enabled"
    static let openInMenuBarOnlyKey = "launchAtLogin.openInMenuBarOnly"
    static let defaultOpenInMenuBarOnly = true

    static func openInMenuBarOnly(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: openInMenuBarOnlyKey) as? Bool ?? defaultOpenInMenuBarOnly
    }
}
