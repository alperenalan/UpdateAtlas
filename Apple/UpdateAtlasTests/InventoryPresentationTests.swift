import Testing
import Foundation
@testable import UpdateAtlas

@Suite("Inventory presentation")
@MainActor
struct InventoryPresentationTests {
    @Test("Installed-version sorting is numeric and reverses on a second header click")
    func installedVersionSortIsNumeric() {
        let old = application(id: "old", name: "Beta", version: "1.0")
        let nine = application(id: "nine", name: "Zeta", version: "2.0.9")
        let ten = application(id: "ten", name: "Alpha", version: "2.0.10")
        let model = AppInventoryViewModel(initialApplications: [nine, ten, old])
        model.selectedFilterID = InventoryScope.allInOne.id

        model.sort(by: .installedVersion)
        #expect(model.visibleApplications.map(\.id) == [old.id, nine.id, ten.id])

        model.sort(by: .installedVersion)
        #expect(model.visibleApplications.map(\.id) == [ten.id, nine.id, old.id])
    }

    @Test("Searching for a child preserves its owner in the displayed hierarchy")
    func childSearchIncludesParent() {
        let parent = application(id: "manager", name: "Manager", version: "1.0")
        let child = application(
            id: "extension", name: "Extension", version: "2.0",
            parentInventoryID: parent.id, kind: .extension
        )
        let unrelated = application(id: "other", name: "Other", version: "1.0")
        let model = AppInventoryViewModel(initialApplications: [unrelated, child, parent])
        model.selectedFilterID = InventoryScope.allInOne.id
        model.expandedManagerIDs.insert(parent.id)
        model.searchText = "com.example.extension"

        #expect(model.visibleApplications.map(\.id) == [parent.id, child.id])
        #expect(model.visibleApplications.count == 2)
    }

    @Test("Primary navigation has distinct destinations and the inventory has no duplicate category headers")
    func primaryNavigationShowsOneFlatInventory() {
        let standard = application(id: "standard", name: "Standard", version: "1")
        let apple = application(id: "apple", name: "Apple App", version: "1", mechanism: .system)
        let vm = application(id: "vm", name: "Guest", version: "1", kind: .virtualMachine)
        let brew = application(id: "brew", name: "brew", version: "1", kind: .package,
                               packageManager: .homebrewFormula)
        let pip = application(id: "pip", name: "pip", version: "1", kind: .package,
                              packageManager: .pythonPip)
        let model = AppInventoryViewModel(initialApplications: [standard, apple, vm, brew, pip])
        model.selectedFilterID = InventoryScope.allInOne.id

        let primary = model.primaryStatusFilters + model.primaryLibraryFilters
        #expect(Set(primary.map(\.id)).count == primary.count)
        #expect(Set(primary.map(\.id)).isDisjoint(with: model.additionalFilters.map(\.id)))
        #expect(Set((primary + model.additionalFilters).map(\.id)) == Set(model.filters.map(\.id)))
        #expect(model.primaryLibraryFilters.map(\.id) == [
            InventoryScope.allInOne.id, InventoryScope.applications.id, InventoryScope.games.id,
            InventoryScope.packageManagers.id, InventoryScope.commandLineTools.id,
            InventoryScope.virtualMachinesAndBottles.id
        ])
        #expect(NativeInventoryRow.snapshot(from: model).compactMap(\.application?.id).count == 5)

        model.selectedFilterID = InventoryScope.applications.id
        #expect(model.scopeFilters.first { $0.id == InventoryScope.applications.id }?.count == 3)
        #expect(NativeInventoryRow.snapshot(from: model).compactMap(\.application?.id).count == 3)

        model.selectedFilterID = InventoryScope.packageManagers.id
        #expect(model.packageManagerFilters.first?.count == 2)
        #expect(NativeInventoryRow.snapshot(from: model).compactMap(\.application?.id).count == 2)
    }

    @Test("An active filter remains visible when its count reaches zero")
    func selectedEmptyFilterRemainsReachable() {
        let model = AppInventoryViewModel(initialApplications: [application(id: "app", name: "App", version: "1")])
        model.selectedFilterID = "update.checkFailed"
        #expect(model.primaryStatusFilters.first { $0.id == model.selectedFilterID }?.count == 0)
        #expect(model.visibleApplications.isEmpty)

        model.selectedFilterID = "game-platform.\(GamePlatformKind.steam.rawValue)"
        #expect(model.additionalFilters.first { $0.id == model.selectedFilterID }?.count == 0)

        model.selectedFilterID = "package-manager.\(PackageManagerKind.homebrewFormula.rawValue)"
        #expect(model.additionalFilters.first { $0.id == model.selectedFilterID }?.count == 0)
    }

    @Test("Up To Date excludes outdated owners and owners with updated children")
    func upToDateOnlyShowsCurrentItems() {
        var code = application(id: "code", name: "Code", version: "1")
        code.updateCheck = updateResult(.updateAvailable)
        var extensionItem = application(id: "extension", name: "Extension", version: "1",
                                        parentInventoryID: code.id, kind: .extension)
        extensionItem.updateCheck = updateResult(.upToDate)
        var comfy = application(id: "comfy", name: "Comfy Desktop", version: "1")
        comfy.updateCheck = updateResult(.upToDate)
        var comfyUI = application(id: "comfyui", name: "ComfyUI", version: "1",
                                  parentInventoryID: comfy.id, kind: .managedComponent)
        comfyUI.updateCheck = updateResult(.updateAvailable)
        let model = AppInventoryViewModel(initialApplications: [code, extensionItem, comfy, comfyUI])
        model.selectedFilterID = DefaultInventoryView.upToDate.filterID
        model.expandedManagerIDs = [code.id, comfy.id]

        #expect(model.visibleApplications.map(\.id) == [extensionItem.id])
        #expect(model.updateStatusFilters.first(where: { $0.id == "update.upToDate" })?.count == 1)
        let rows = NativeInventoryRow.snapshot(from: model)
        #expect(rows.count == 1)
        if let row = rows.first,
           case .application(let item, let depth, let hasChildren, _, _) = row {
            #expect(item.id == extensionItem.id)
            #expect(depth == 0)
            #expect(!hasChildren)
        } else { Issue.record("Expected an application row") }

        model.selectedFilterID = DefaultInventoryView.updateAvailable.filterID
        let updateRows = NativeInventoryRow.snapshot(from: model)
        #expect(updateRows.compactMap(\.application?.id).contains(comfyUI.id))
        #expect(updateRows.contains { row in
            if case .application(let item, _, let hasChildren, _, _) = row {
                return item.id == comfy.id && hasChildren
            }
            return false
        })
    }

    @Test("An owner chevron appears only when this filter can reveal a child")
    func chevronFollowsFilteredChildren() {
        var parent = application(id: "parent", name: "Parent", version: "1")
        parent.updateCheck = updateResult(.upToDate)
        var child = application(id: "child", name: "Child", version: "1",
                                parentInventoryID: parent.id, kind: .managedComponent)
        child.updateCheck = updateResult(.upToDate)
        let model = AppInventoryViewModel(initialApplications: [parent, child])
        model.selectedFilterID = DefaultInventoryView.upToDate.filterID

        let collapsed = NativeInventoryRow.snapshot(from: model)
        #expect(collapsed.count == 1)
        if let row = collapsed.first,
           case .application(_, _, let hasChildren, _, let expanded) = row {
            #expect(hasChildren && !expanded)
        } else { Issue.record("Expected an application row") }
        model.toggleExpanded(parent)
        #expect(NativeInventoryRow.snapshot(from: model).compactMap(\.application?.id) == [parent.id, child.id])
    }

    @Test("A selection is cleared when the current filter no longer displays it")
    func hiddenSelectionIsCleared() {
        let application = application(id: "selected", name: "Selected", version: "1.0")
        let model = AppInventoryViewModel(initialApplications: [application])
        model.selectedFilterID = InventoryScope.allInOne.id
        model.selectedApplicationID = application.id

        model.selectedFilterID = "update.updateAvailable"
        model.clearSelectionIfHidden()

        #expect(model.visibleApplications.isEmpty)
        #expect(model.selectedApplicationID == nil)
    }

    @Test("Menu update selection clears filters and expands its owner")
    func menuSelectionRevealsChild() {
        let owner = application(id: "manager", name: "Manager", version: "1")
        let child = application(id: "child", name: "Child", version: "1", parentInventoryID: owner.id)
        let model = AppInventoryViewModel(initialApplications: [owner, child])
        model.searchText = "unrelated"
        model.selectedFilterID = "update.upToDate"
        model.revealApplication(id: child.id)
        #expect(model.searchText.isEmpty)
        #expect(model.selectedFilterID == InventoryScope.allInOne.id)
        #expect(model.expandedManagerIDs.contains(owner.id))
        #expect(model.visibleTableApplicationIDs.contains(child.id))
        #expect(model.selectedApplicationID == child.id)
    }

    @Test("Menu list includes only confirmed updates once and sorts by name")
    func menuListUsesConfirmedUpdates() {
        var zeta = application(id: "z", name: "Zeta", version: "1")
        var alpha = application(id: "a", name: "Alpha", version: "1")
        let pending = application(id: "pending", name: "Pending", version: "1")
        zeta.updateCheck = UpdateCheckResult(availability: .updateAvailable, installedVersion: "1", latestVersion: "2", checkedAt: nil, source: nil, detail: "")
        alpha.updateCheck = zeta.updateCheck
        let items = [zeta, pending, alpha, zeta]
        #expect(MenuBarUpdateList.items(in: items).map(\.id) == ["a", "z"])
        #expect(MenuBarUpdateSummary.count(items).total == 2)
    }

    @Test("Menu update clicks prefer a verified updater, then the store, manager, app, or inspector")
    func menuUpdateActionRouting() {
        let app = application(id: "app", name: "App", version: "1")
        let store = application(id: "store", name: "Store App", version: "1", mechanism: .appStore)
        #expect(MenuBarUpdateAction.choose(for: app, updateAction: .sparkleConfirmation,
                                           managerAvailable: true, applicationAvailable: true) == .update)
        #expect(MenuBarUpdateAction.choose(for: store, updateAction: .appStorePage,
                                           managerAvailable: false, applicationAvailable: true) == .appStore)
        #expect(MenuBarUpdateAction.choose(for: app, updateAction: nil,
                                           managerAvailable: true, applicationAvailable: true) == .openManager)
        #expect(MenuBarUpdateAction.choose(for: app, updateAction: nil,
                                           managerAvailable: false, applicationAvailable: true) == .openApplication)
        #expect(MenuBarUpdateAction.choose(for: app, updateAction: nil,
                                           managerAvailable: false, applicationAvailable: false) == .inspect)
    }

    @Test("Inline actions prefer an updater, then a release or vendor page, then the app")
    func inlineOpenActionRouting() {
        var app = application(id: "app", name: "App", version: "1")
        app.updateCheck = updateResult(.updateAvailable)
        let current = application(id: "current", name: "Current", version: "1")
        var store = application(id: "store", name: "Store", version: "1", mechanism: .appStore)
        store.updateCheck = updateResult(.updateAvailable)
        var managed = application(id: "managed", name: "Managed", version: "1", mechanism: .externalManager)
        managed.updateCheck = updateResult(.updateAvailable)
        var releasePage = application(id: "release", name: "Release Page", version: "1", mechanism: .githubReleases)
        releasePage.updateCheck = updateResult(.updateAvailable)

        #expect(MenuBarUpdateAction.inlineOpen(for: app, updateAction: nil,
                                               managerAvailable: true, applicationAvailable: false) == .openManager)
        #expect(MenuBarUpdateAction.inlineOpen(for: app, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: true) == .openApplication)
        #expect(MenuBarUpdateAction.inlineOpen(for: app, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: false) == nil)
        #expect(MenuBarUpdateAction.inlineOpen(for: managed, updateAction: nil,
                                               managerAvailable: true, applicationAvailable: false) == .openManager)
        #expect(MenuBarUpdateAction.inlineOpen(for: managed, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: true) == nil)
        #expect(MenuBarUpdateAction.inlineOpen(for: app, updateAction: .sparkleConfirmation,
                                               managerAvailable: true, applicationAvailable: true) == nil)
        #expect(MenuBarUpdateAction.inlineOpen(for: store, updateAction: .appStorePage,
                                               managerAvailable: false, applicationAvailable: true) == nil)
        #expect(MenuBarUpdateAction.inlineOpen(for: current, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: true) == nil)
        #expect(MenuBarUpdateAction.inlineOpen(for: releasePage, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: true,
                                               releasePageAvailable: true, websiteAvailable: true) == .openReleasePage)
        #expect(MenuBarUpdateAction.inlineOpen(for: releasePage, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: false,
                                               websiteAvailable: true) == .openWebsite)
        #expect(MenuBarUpdateAction.inlineOpen(for: releasePage, updateAction: nil,
                                               managerAvailable: false, applicationAvailable: true) == .openApplication)
        #expect(MenuBarUpdateAction.safeWebURL(URL(string: "https://github.com/example/app/releases/tag/2")) != nil)
        #expect(MenuBarUpdateAction.safeWebURL(URL(string: "file:///tmp/fake-release")) == nil)
        #expect(MenuBarUpdateAction.safeWebURL(URL(string: "https://user:pass@example.com/release")) == nil)
    }

    @Test("GitHub release and vendor-backed apps get visible row actions")
    func releaseBackedRowActions() {
        var jellyfin = application(id: "jellyfin", name: "Jellyfin Server", version: "12.2",
                                    mechanism: .githubReleases,
                                    releaseNotesURL: URL(string: "https://github.com/jellyfin/jellyfin/releases/tag/v12.3"))
        jellyfin.updateCheck = UpdateCheckResult(
            availability: .updateAvailable, installedVersion: "12.2", latestVersion: "12.3",
            checkedAt: nil, source: nil, detail: "",
            releaseNotesURL: URL(string: "file:///tmp/untrusted-release")
        )
        var openDesign = application(id: "open-design", name: "Open Design", version: "0.21.1",
                                      mechanism: .githubReleases,
                                      vendorURL: URL(string: "https://github.com/nexu-io/open-design"))
        openDesign.updateCheck = updateResult(.updateAvailable)
        let model = AppInventoryViewModel(initialApplications: [jellyfin, openDesign])

        #expect(model.inlineOpenAction(for: jellyfin) == .openReleasePage)
        #expect(MenuBarUpdateAction.releasePageURL(for: jellyfin) == jellyfin.releaseNotesURL)
        #expect(model.inlineOpenAction(for: openDesign) == .openWebsite)
    }

    @Test("Managed update opens its inventoried parent even without Launch Services registration")
    func inventoriedManagerRoute() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scratch = project.appendingPathComponent(".temporary_files/manager-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("Manager.app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.manager", "CFBundlePackageType": "APPL",
                    "CFBundleExecutable": "Manager"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let manager = application(id: "manager", name: "Manager", version: "1", path: bundle.path)
        var child = application(id: "child", name: "Managed", version: "1",
                                parentInventoryID: manager.id,
                                parentManagerBundleIdentifier: manager.bundleIdentifier,
                                kind: .managedComponent, mechanism: .externalManager)
        child.updateCheck = updateResult(.updateAvailable)
        let model = AppInventoryViewModel(initialApplications: [manager, child])
        #expect(model.managerApplicationURL(for: child)?.path == bundle.path)
        #expect(model.inlineOpenAction(for: child) == .openManager)
    }

    @Test("Menu preference defaults on and preserves an existing off preference")
    func menuPreferenceUpgrade() {
        let name = "test.menu." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MenuBarSettings.isEnabled(in: defaults))
        defaults.set(false, forKey: MenuBarSettings.enabledKey)
        #expect(!MenuBarSettings.isEnabled(in: defaults))
        defaults.set(true, forKey: MenuBarSettings.enabledKey)
        #expect(MenuBarSettings.isEnabled(in: defaults))
    }

    private func application(
        id: String,
        name: String,
        version: String,
        path: String? = nil,
        parentInventoryID: String? = nil,
        parentManagerBundleIdentifier: String? = nil,
        kind: InventoryItemKind = .application,
        mechanism: UpdateMechanismKind = .sparkle,
        packageManager: PackageManagerKind? = nil,
        vendorURL: URL? = nil,
        releaseNotesURL: URL? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: id,
            path: path ?? "/Applications/\(name).app",
            name: name,
            bundleIdentifier: "com.example.\(id)",
            displayVersion: version,
            buildVersion: version,
            teamIdentifier: nil,
            status: .supported,
            mechanism: mechanism,
            mechanismName: "Sparkle",
            confidence: .verified,
            evidence: [],
            parentInventoryID: parentInventoryID,
            parentManagerBundleIdentifier: parentManagerBundleIdentifier,
            parentManagerName: nil,
            vendorURL: vendorURL,
            catalogEntryID: nil,
            releaseNotesURL: releaseNotesURL,
            notes: "",
            kind: kind,
            packageProvenance: packageManager.map {
                PackageProvenance(identifier: id, manager: $0, managerExecutablePath: "/usr/bin/\($0.rawValue)",
                                  installLocation: nil, explicitlyInstalled: true, homepage: nil,
                                  summary: nil, isOutdated: nil)
            }
        )
    }

    private func updateResult(_ availability: UpdateAvailability) -> UpdateCheckResult {
        UpdateCheckResult(availability: availability, installedVersion: "1", latestVersion: "2",
                          checkedAt: nil, source: nil, detail: "")
    }
}
