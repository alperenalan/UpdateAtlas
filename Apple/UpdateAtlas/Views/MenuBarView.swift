import AppKit
import Combine

// Keep the optional menu outside SwiftUI SceneBuilder: MenuBarExtra(isInserted:)
// spun the main view graph at launch on macOS 27 even when its binding was false.
@MainActor
final class UpdateAtlasMenuBarController: NSObject, NSMenuDelegate {
    static let shared = UpdateAtlasMenuBarController()

    private weak var viewModel: AppInventoryViewModel?
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var openMainWindow: (() -> Void)?
    private var openSettingsWindow: (() -> Void)?

    func attach(
        viewModel: AppInventoryViewModel,
        openMainWindow: @escaping () -> Void,
        openSettingsWindow: @escaping () -> Void
    ) {
        self.openMainWindow = openMainWindow
        self.openSettingsWindow = openSettingsWindow
        guard self.viewModel !== viewModel else {
            refresh()
            return
        }
        self.viewModel = viewModel
        subscriptions.removeAll()
        Publishers.CombineLatest3(
            viewModel.$applications,
            viewModel.$isScanning,
            viewModel.$lastScanDate
        )
        .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            self?.refresh()
        }
        .store(in: &subscriptions)
        refresh()
    }

    func refresh() {
        let enabled = MenuBarSettings.isEnabled()
        guard enabled else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }

        let showCount = UserDefaults.standard.object(forKey: MenuBarSettings.showCountKey) as? Bool
            ?? MenuBarSettings.defaultShowCount
        let count = viewModel?.menuBarUpdateSummary.total ?? 0
        let hasConfirmedUpdates = viewModel?.isScanning == false
            && viewModel?.lastScanDate != nil
            && count > 0
        let showsBadge = showCount && hasConfirmedUpdates
        if let button = statusItem?.button {
            let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "Update Atlas")
            symbol?.isTemplate = true
            button.image = symbol
            button.imagePosition = .imageLeading
            button.title = showsBadge ? " \(count)" : ""
            button.toolTip = hasConfirmedUpdates
                ? "Update Atlas · " + plural("%lld updates available", singular: "%lld update available", count: count)
                : "Update Atlas"
        }
    }

    func showMainWindow() {
        openApp()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        #if DEBUG
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        addLabel(localized("Debug build") + " · \(version) (\(build))", to: menu)
        menu.addItem(.separator())
        #endif
        if let viewModel {
            let summary = viewModel.menuBarUpdateSummary
            if viewModel.isScanning {
                addLabel(localized("Scanning…"), to: menu)
            } else if viewModel.lastScanDate == nil {
                addLabel(localized("Not scanned yet"), to: menu)
            } else if summary.total == 0 {
                addLabel(localized("No Updates Available"), to: menu)
            } else {
                addLabel(plural("%lld updates available", singular: "%lld update available", count: summary.total), to: menu)
                let updates = MenuBarUpdateList.items(in: viewModel.applications)
                for application in updates.prefix(Self.maximumUpdateRows) {
                    let version = application.updateCheck.latestVersion.map { " → " + $0 } ?? ""
                    let item = addAction(application.name + version, selector: #selector(openUpdate(_:)), to: menu)
                    if MenuBarSettings.showAppIcons() {
                        item.attributedTitle = ApplicationIconImage.menuTitle(
                            for: application, text: application.name + version
                        )
                    }
                    item.representedObject = application.id
                    item.toolTip = tooltip(for: preferredAction(for: application), application: application)
                }
                if updates.count > Self.maximumUpdateRows {
                    addAction(localized("Show All Updates…"), selector: #selector(showAllUpdates), to: menu)
                }
            }
        }
        menu.addItem(.separator())
        addAction(localized("Open Update Atlas"), selector: #selector(openApp), symbol: "macwindow", to: menu)
        let scanItem = addAction(localized("Scan Now"), selector: #selector(scanNow), symbol: "arrow.clockwise", to: menu)
        scanItem.isEnabled = viewModel?.isScanning == false
            && UserDefaults.standard.bool(forKey: OnboardingSettings.completedKey)
        addAction(localized("Settings…"), selector: #selector(openSettings), symbol: "gearshape", to: menu)
            .keyEquivalent = ","
        menu.addItem(.separator())
        addAction(localized("Quit Update Atlas"), selector: #selector(quit), symbol: "power", to: menu)
            .keyEquivalent = "q"
    }

    /// Longer lists stay readable; the full list is one click away in the main window.
    private static let maximumUpdateRows = 12

    private func localized(_ key: String.LocalizationValue) -> String {
        let selectedCode = UserDefaults.standard.string(forKey: LanguageSettings.languageKey)
        return String(localized: key, bundle: AppL10n.bundle, locale: LanguageSettings.effectiveLocale(for: selectedCode ?? LanguageSettings.defaultLanguageCode))
    }

    private func plural(_ key: String, singular: String, count: Int) -> String {
        let selectedCode = UserDefaults.standard.string(forKey: LanguageSettings.languageKey)
        return AppL10n.plural(key, singular: singular, count: count,
                              locale: LanguageSettings.effectiveLocale(for: selectedCode ?? LanguageSettings.defaultLanguageCode))
    }

    private func addLabel(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ title: String, selector: Selector, symbol: String? = nil, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.image?.isTemplate = true
        }
        menu.addItem(item)
        return item
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let viewModel,
              let application = viewModel.applications.first(where: {
                  $0.id == id && $0.updateCheck.availability == .updateAvailable
                      && !$0.isExcludedFromMainUpdateList
              }) else { return }
        if viewModel.isScanning || DirectUpdateService.shared.activeApplicationID != nil {
            viewModel.revealApplication(id: id)
            openApp()
            return
        }
        switch preferredAction(for: application) {
        case .update:
            viewModel.revealApplication(id: id)
            openApp()
            viewModel.requestUpdate(application)
        case .appStore:
            viewModel.requestUpdate(application)
        case .openManager:
            viewModel.openManager(for: application)
        case .openApplication:
            viewModel.openApplication(application)
        case .openReleasePage:
            if let url = MenuBarUpdateAction.releasePageURL(for: application) {
                viewModel.openURL(url)
            }
        case .openWebsite:
            if let url = MenuBarUpdateAction.safeWebURL(application.vendorURL) { viewModel.openURL(url) }
        case .inspect:
            viewModel.revealApplication(id: id)
            openApp()
        }
    }

    private func preferredAction(for application: InstalledApplication) -> MenuBarUpdateAction {
        let managerAvailable = viewModel?.managerApplicationURL(for: application) != nil
        return MenuBarUpdateAction.choose(
            for: application,
            updateAction: ManagerUpdatePolicy.action(for: application),
            managerAvailable: managerAvailable,
            applicationAvailable: application.path.hasSuffix(".app") && application.existsOnDisk
        )
    }

    private func tooltip(for action: MenuBarUpdateAction, application: InstalledApplication) -> String {
        switch action {
        case .update: localized("Update Application…")
        case .appStore: localized("Open App Store Page")
        case .openManager: String(format: localized("Open %@"), application.parentManagerName ?? application.name)
        case .openApplication: localized("Open Application")
        case .openReleasePage: localized("View Version Changelog")
        case .openWebsite: localized("Open Website")
        case .inspect: application.mechanismName
        }
    }

    @objc private func openApp() {
        openMainWindow?()
        NSApp.activate()
    }

    @objc private func showAllUpdates() {
        viewModel?.showUpdateList()
        openApp()
    }

    @objc private func openSettings() {
        openSettingsWindow?()
        NSApp.activate()
    }

    @objc private func scanNow() {
        guard let viewModel else { return }
        Task { await viewModel.scan() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
