import XCTest
import AppKit
@testable import UpdateAtlas

final class OnboardingPreferencesTests: XCTestCase {
    func testClearingPreferencesDuringUninstallDoesNotPresentOnboarding() {
        XCTAssertTrue(OnboardingSettings.shouldPresent(completed: false, uninstalling: false))
        XCTAssertFalse(OnboardingSettings.shouldPresent(completed: true, uninstalling: false))
        XCTAssertFalse(OnboardingSettings.shouldPresent(completed: false, uninstalling: true))
    }

    func testFreshUserSeesExistingSafeDefaults() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = OnboardingPreferences.current(from: defaults)

        XCTAssertEqual(preferences.defaultView, InventorySettings.defaultView)
        XCTAssertEqual(preferences.includeSystemApplications, InventorySettings.defaultIncludeSystemApplications)
        XCTAssertTrue(preferences.excludeSystemApplications)
        XCTAssertEqual(preferences.catalogMatchingEnabled, CatalogSettings.defaultMatchingEnabled)
        XCTAssertEqual(preferences.allowPrereleaseForStable, ReleaseChannelSettings.defaultAllowPrereleaseForStable)
        XCTAssertEqual(preferences.menuBarEnabled, MenuBarSettings.defaultEnabled)
        XCTAssertEqual(preferences.showMenuBarIcons, MenuBarSettings.defaultShowAppIcons)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertEqual(preferences.openInMenuBarOnly, LaunchAtLoginSettings.defaultOpenInMenuBarOnly)
        XCTAssertEqual(preferences.hideSystemPythonPackages, InventorySettings.defaultHideSystemPythonUpdates)
        XCTAssertFalse(defaults.bool(forKey: OnboardingSettings.completedKey))
    }

    @MainActor
    func testChosenPreferencesPersistAndMarkOnboardingComplete() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = OnboardingPreferences(
            defaultView: .games,
            includeSystemApplications: true,
            catalogMatchingEnabled: false,
            allowPrereleaseForStable: true,
            languageCode: "tr",
            menuBarEnabled: false,
            showMenuBarAppIcons: false,
            launchAtLogin: true,
            openInMenuBarOnly: false,
            hideSystemPythonPackages: false
        )
        try preferences.save(to: defaults)

        XCTAssertEqual(OnboardingPreferences.current(from: defaults), preferences)
        XCTAssertFalse(OnboardingPreferences.current(from: defaults).excludeSystemApplications)
        XCTAssertEqual(defaults.string(forKey: InventorySettings.defaultViewKey), DefaultInventoryView.games.rawValue)
        XCTAssertTrue(defaults.bool(forKey: InventorySettings.includeSystemApplicationsKey))
        XCTAssertFalse(defaults.bool(forKey: CatalogSettings.matchingEnabledKey))
        XCTAssertTrue(ReleaseChannelSettings.current(from: defaults))
        XCTAssertFalse(MenuBarSettings.isEnabled(in: defaults))
        XCTAssertFalse(MenuBarSettings.showAppIcons(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginSettings.enabledKey))
        XCTAssertFalse(LaunchAtLoginSettings.openInMenuBarOnly(in: defaults))
        XCTAssertFalse(InventorySettings.hideSystemPythonUpdates(in: defaults))
        XCTAssertEqual(defaults.string(forKey: LanguageSettings.languageKey), "tr")
        XCTAssertTrue(defaults.bool(forKey: OnboardingSettings.completedKey))
    }

    @MainActor
    func testExcludeTogglePreservesExistingIncludePreference() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: InventorySettings.includeSystemApplicationsKey)

        var preferences = OnboardingPreferences.current(from: defaults)
        XCTAssertFalse(preferences.excludeSystemApplications)
        preferences.excludeSystemApplications = true
        XCTAssertFalse(preferences.includeSystemApplications)
        preferences.excludeSystemApplications = false
        XCTAssertTrue(preferences.includeSystemApplications)
        preferences.excludeSystemApplications = true
        try preferences.save(to: defaults)
        XCTAssertFalse(defaults.bool(forKey: InventorySettings.includeSystemApplicationsKey))
        XCTAssertTrue(OnboardingPreferences.current(from: defaults).excludeSystemApplications)
    }

    @MainActor
    func testManualLaunchKeepsWindowVisibleEvenWhenLoginItemIsEnabled() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = LaunchAtLoginService(defaults: defaults, isTesting: true)

        XCTAssertFalse(service.hasRecordedLaunchEvent)
        XCTAssertFalse(service.shouldStartQuietlyInMenuBar)
        try service.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginSettings.enabledKey))
        service.recordLaunchEvent(nil)
        XCTAssertTrue(service.hasRecordedLaunchEvent)
        XCTAssertFalse(service.shouldStartQuietlyInMenuBar)

        let manualLaunch = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        service.recordLaunchEvent(manualLaunch)
        XCTAssertFalse(service.shouldStartQuietlyInMenuBar)

        manualLaunch.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        service.recordLaunchEvent(manualLaunch)
        XCTAssertTrue(service.shouldStartQuietlyInMenuBar)
        defaults.set(false, forKey: MenuBarSettings.enabledKey)
        XCTAssertFalse(service.shouldStartQuietlyInMenuBar)
        try service.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginSettings.enabledKey))
    }

    @MainActor
    func testOnboardingLoginToggleAppliesBeforeScanningOrCompletingSetup() throws {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = LaunchAtLoginService(defaults: defaults, isTesting: true)
        var preferences = OnboardingPreferences.current(from: defaults)

        try preferences.setLaunchAtLogin(true, apply: service.setEnabled)
        XCTAssertTrue(preferences.launchAtLogin)
        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginSettings.enabledKey))
        XCTAssertFalse(defaults.bool(forKey: OnboardingSettings.completedKey))

        try preferences.setLaunchAtLogin(false, apply: service.setEnabled)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginSettings.enabledKey))
        XCTAssertFalse(defaults.bool(forKey: OnboardingSettings.completedKey))
    }

    @MainActor
    func testOnboardingLoginToggleKeepsPreviousSelectionWhenRegistrationFails() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = OnboardingPreferences.current(from: defaults)
        let original = preferences.launchAtLogin

        XCTAssertThrowsError(try preferences.setLaunchAtLogin(!original) { _ in
            throw NSError(domain: "test", code: 1)
        })
        XCTAssertEqual(preferences.launchAtLogin, original)
    }

}
