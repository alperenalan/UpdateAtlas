import AppKit

@MainActor
final class AppearanceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SelfUninstallService.shared.hasMovedAppToTrash { return .terminateNow }
        guard DirectUpdateService.shared.managerStatus != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Update in progress", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.informativeText = String(localized: "Keep Update Atlas open until the manager finishes.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.addButton(withTitle: String(localized: "OK", bundle: AppL10n.bundle, locale: AppL10n.locale))
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MenuBarSettings.isEnabled()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return true }
        if !flag {
            UpdateAtlasMenuBarController.shared.showMainWindow()
        }
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Retire previously selectable locales that never had a complete translation.
        LanguageSettings.persist(UserDefaults.standard.string(forKey: LanguageSettings.languageKey)
            ?? LanguageSettings.defaultLanguageCode)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            UpdateNotificationService.shared.configureNativeCenter()
        }
        AppearanceSettings.apply(
            UserDefaults.standard.string(forKey: AppearanceSettings.appearanceKey)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLoginService.shared.recordLaunchEvent(NSAppleEventManager.shared().currentAppleEvent)
        // Sparkle only asks for, and later schedules, the app's own update checks once its updater exists.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            _ = SelfUpdateService.shared
        }
    }
}
