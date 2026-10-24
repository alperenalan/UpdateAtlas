import Foundation

enum OnboardingSettings {
    static let completedKey = "onboarding.completed-v1"
    static let resetRequestedNotification = Notification.Name("UpdateAtlasOnboardingResetRequested")

    static func shouldPresent(completed: Bool, uninstalling: Bool) -> Bool {
        !completed && !uninstalling
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: completedKey)
        NotificationCenter.default.post(name: resetRequestedNotification, object: nil)
    }
}

struct OnboardingPreferences: Equatable {
    var defaultView: DefaultInventoryView
    var includeSystemApplications: Bool
    var catalogMatchingEnabled: Bool
    var allowPrereleaseForStable: Bool
    var languageCode: String
    var menuBarEnabled: Bool
    var showMenuBarAppIcons: Bool
    var launchAtLogin: Bool
    var openInMenuBarOnly: Bool
    var hideSystemPythonPackages: Bool

    var excludeSystemApplications: Bool {
        get { !includeSystemApplications }
        set { includeSystemApplications = !newValue }
    }

    var showMenuBarIcons: Bool {
        get { showMenuBarAppIcons }
        set { showMenuBarAppIcons = newValue }
    }

    @MainActor
    mutating func setLaunchAtLogin(_ enabled: Bool, apply: (Bool) throws -> Void) throws {
        try apply(enabled)
        launchAtLogin = enabled
    }

    init(
        defaultView: DefaultInventoryView,
        includeSystemApplications: Bool,
        catalogMatchingEnabled: Bool,
        allowPrereleaseForStable: Bool,
        languageCode: String = LanguageSettings.systemLanguageCode,
        menuBarEnabled: Bool = MenuBarSettings.defaultEnabled,
        showMenuBarAppIcons: Bool = MenuBarSettings.defaultShowAppIcons,
        launchAtLogin: Bool = false,
        openInMenuBarOnly: Bool = LaunchAtLoginSettings.defaultOpenInMenuBarOnly,
        hideSystemPythonPackages: Bool = InventorySettings.defaultHideSystemPythonUpdates
    ) {
        self.defaultView = defaultView
        self.includeSystemApplications = includeSystemApplications
        self.catalogMatchingEnabled = catalogMatchingEnabled
        self.allowPrereleaseForStable = allowPrereleaseForStable
        self.languageCode = languageCode
        self.menuBarEnabled = menuBarEnabled
        self.showMenuBarAppIcons = showMenuBarAppIcons
        self.launchAtLogin = launchAtLogin
        self.openInMenuBarOnly = openInMenuBarOnly
        self.hideSystemPythonPackages = hideSystemPythonPackages
    }

    static func current(from defaults: UserDefaults = .standard) -> Self {
        let savedView = defaults.string(forKey: InventorySettings.defaultViewKey)
        let savedLanguage = defaults.string(forKey: LanguageSettings.languageKey)
        return Self(
            defaultView: DefaultInventoryView(rawValue: savedView ?? "")
                ?? InventorySettings.defaultView,
            includeSystemApplications: defaults.object(
                forKey: InventorySettings.includeSystemApplicationsKey
            ) as? Bool ?? InventorySettings.defaultIncludeSystemApplications,
            catalogMatchingEnabled: defaults.object(
                forKey: CatalogSettings.matchingEnabledKey
            ) as? Bool ?? CatalogSettings.defaultMatchingEnabled,
            allowPrereleaseForStable: defaults.object(
                forKey: ReleaseChannelSettings.allowPrereleaseForStableKey
            ) as? Bool ?? ReleaseChannelSettings.defaultAllowPrereleaseForStable,
            languageCode: LanguageSettings.normalizedCode(savedLanguage),
            menuBarEnabled: MenuBarSettings.isEnabled(in: defaults),
            showMenuBarAppIcons: MenuBarSettings.showAppIcons(in: defaults),
            launchAtLogin: defaults.bool(forKey: LaunchAtLoginSettings.enabledKey),
            openInMenuBarOnly: LaunchAtLoginSettings.openInMenuBarOnly(in: defaults),
            hideSystemPythonPackages: InventorySettings.hideSystemPythonUpdates(in: defaults)
        )
    }

    @MainActor
    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(defaultView.rawValue, forKey: InventorySettings.defaultViewKey)
        defaults.set(includeSystemApplications, forKey: InventorySettings.includeSystemApplicationsKey)
        defaults.set(catalogMatchingEnabled, forKey: CatalogSettings.matchingEnabledKey)
        defaults.set(allowPrereleaseForStable, forKey: ReleaseChannelSettings.allowPrereleaseForStableKey)
        defaults.set(menuBarEnabled, forKey: MenuBarSettings.enabledKey)
        defaults.set(showMenuBarAppIcons, forKey: MenuBarSettings.showAppIconsKey)
        defaults.set(openInMenuBarOnly, forKey: LaunchAtLoginSettings.openInMenuBarOnlyKey)
        defaults.set(hideSystemPythonPackages, forKey: InventorySettings.hideSystemPythonUpdatesKey)
        if defaults === UserDefaults.standard {
            LaunchAtLoginService.shared.openInMenuBarOnly = openInMenuBarOnly
            let pendingMacOSApproval = launchAtLogin && LaunchAtLoginService.shared.requiresApproval
            if launchAtLogin != defaults.bool(forKey: LaunchAtLoginSettings.enabledKey)
                || (launchAtLogin != LaunchAtLoginService.shared.isEnabled && !pendingMacOSApproval) {
                try LaunchAtLoginService.shared.setEnabled(launchAtLogin)
            }
        } else {
            defaults.set(launchAtLogin, forKey: LaunchAtLoginSettings.enabledKey)
        }
        if defaults === UserDefaults.standard {
            LanguageSettings.setLanguageCode(languageCode)
        } else {
            LanguageSettings.persist(languageCode, in: defaults)
        }
        defaults.set(true, forKey: OnboardingSettings.completedKey)
    }
}
