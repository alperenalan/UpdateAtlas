import AppKit
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()
    static let enabledKey = LaunchAtLoginSettings.enabledKey
    static let openInMenuBarOnlyKey = LaunchAtLoginSettings.openInMenuBarOnlyKey
    static let defaultOpenInMenuBarOnly = LaunchAtLoginSettings.defaultOpenInMenuBarOnly

    static func isEnabled() -> Bool {
        shared.isEnabled
    }

    static func openInMenuBarOnly() -> Bool {
        shared.openInMenuBarOnly
    }

    static func setEnabled(_ enabled: Bool) throws {
        try shared.setEnabled(enabled)
    }

    @Published private(set) var isEnabled: Bool
    @Published var openInMenuBarOnly: Bool {
        didSet {
            defaults.set(openInMenuBarOnly, forKey: LaunchAtLoginSettings.openInMenuBarOnlyKey)
        }
    }
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasRecordedLaunchEvent = false
    private(set) var wasLaunchedAsLoginItem = false

    var requiresApproval: Bool {
        !isTesting && SMAppService.mainApp.status == .requiresApproval
    }

    private let defaults: UserDefaults
    private let isTesting: Bool

    init(defaults: UserDefaults = .standard,
         isTesting: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) {
        self.defaults = defaults
        self.isTesting = isTesting
        self.openInMenuBarOnly = LaunchAtLoginSettings.openInMenuBarOnly(in: defaults)
        if isTesting {
            self.isEnabled = defaults.bool(forKey: LaunchAtLoginSettings.enabledKey)
        } else {
            let serviceStatus = SMAppService.mainApp.status
            self.isEnabled = serviceStatus == .enabled
            if serviceStatus == .requiresApproval {
                self.statusMessage = String(localized: "Allow Update Atlas in System Settings > General > Login Items.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }
    }

    func refreshStatus() {
        guard !isTesting else {
            isEnabled = defaults.bool(forKey: LaunchAtLoginSettings.enabledKey)
            return
        }
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
            statusMessage = nil
        case .requiresApproval:
            isEnabled = false
            statusMessage = String(localized: "Allow Update Atlas in System Settings > General > Login Items.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        default:
            isEnabled = false
            statusMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard !isTesting else {
            defaults.set(enabled, forKey: LaunchAtLoginSettings.enabledKey)
            isEnabled = enabled
            statusMessage = nil
            enableMenuBarIfNeeded(enabled)
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            refreshStatus()
            statusMessage = String(localized: "Could not update Login Items setting in macOS.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            throw error
        }
        defaults.set(enabled, forKey: LaunchAtLoginSettings.enabledKey)
        enableMenuBarIfNeeded(enabled)
        refreshStatus()
    }

    private func enableMenuBarIfNeeded(_ enabled: Bool) {
        guard enabled, openInMenuBarOnly, !MenuBarSettings.isEnabled(in: defaults) else { return }
        defaults.set(true, forKey: MenuBarSettings.enabledKey)
        if defaults === UserDefaults.standard {
            UpdateAtlasMenuBarController.shared.refresh()
        }
    }

    func recordLaunchEvent(_ event: NSAppleEventDescriptor?) {
        // Registration status says the app may launch at login, not why this process launched.
        // macOS marks the actual kAEOpenApplication event with keyAELaunchedAsLogInItem.
        wasLaunchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        hasRecordedLaunchEvent = true
    }

    /// Returns true when the app should start quietly in the menu bar without bringing the main window forward.
    var shouldStartQuietlyInMenuBar: Bool {
        guard wasLaunchedAsLoginItem, isEnabled, openInMenuBarOnly,
              MenuBarSettings.isEnabled(in: defaults) else { return false }
        return true
    }
}
