import AppKit
import Testing
@testable import UpdateAtlas

@Suite("One-item update refresh")
@MainActor
struct ApplicationRefreshTests {
    private func item(path: String = "/Applications/Fixture.app", id: String = "fixture",
                      bundleID: String = "test.fixture", kind: InventoryItemKind = .application,
                      platform: GamePlatformKind? = nil, parent: String? = nil,
                      mechanism: UpdateMechanismKind = .sparkle, provenance: PackageProvenance? = nil,
                      availability: UpdateAvailability = .updateAvailable) -> InstalledApplication {
        InstalledApplication(inventoryID: id, path: path, name: id, bundleIdentifier: bundleID,
            displayVersion: "1.0", buildVersion: "1", teamIdentifier: nil, status: .supported,
            mechanism: mechanism, mechanismName: "Fixture updater", confidence: .verified, evidence: [],
            parentInventoryID: parent, parentManagerBundleIdentifier: nil, parentManagerName: nil,
            vendorURL: nil, catalogEntryID: nil, notes: "", kind: kind, gamePlatform: platform,
            packageProvenance: provenance, updateCheck: .init(availability: availability,
                installedVersion: "1.0", latestVersion: "2.0", checkedAt: nil, source: nil, detail: ""))
    }
    private func candidate(_ item: InstalledApplication, version: String = "2.0") -> ApplicationCandidate {
        ApplicationCandidate(inventoryID: item.id, path: item.path, name: item.name,
            bundleIdentifier: item.bundleIdentifier, displayVersion: version, buildVersion: version,
            teamIdentifier: nil, parentInventoryID: item.parentInventoryID,
            parentManagerBundleIdentifier: nil, isSystemApplication: false, info: [:], kind: item.kind,
            gamePlatform: item.gamePlatform, packageProvenance: item.packageProvenance)
    }
    private func provenance(_ manager: PackageManagerKind = .homebrewFormula) -> PackageProvenance {
        .init(identifier: "fixture", manager: manager, managerExecutablePath: "/opt/homebrew/bin/brew",
            installLocation: nil, explicitlyInstalled: true, homepage: nil, summary: nil,
            isOutdated: true, latestVersion: "2.0", installedVersion: "1.0")
    }
    private func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".temporary_files/item-refresh-tests/" + UUID().uuidString)
    }
    private func writeBundle(_ path: URL, version: String, bundleID: String = "test.fixture") throws {
        let info: [String: String] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Fixture",
            "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundlePackageType": "APPL"]
        try FileManager.default.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Contents/Info.plist"))
    }

    @Test("Global status views include Prism, games and manager packages consistently with the menu")
    func globalUpdates() {
        let prism = item(id: "prism", bundleID: "org.prismlauncher.PrismLauncher", platform: .standalone)
        let game = item(id: "game", kind: .game, platform: .steam)
        let package = item(id: "package", kind: .commandLineTool, mechanism: .homebrew, provenance: provenance())
        let pending = item(id: "pending", availability: .sourcePending)
        let model = AppInventoryViewModel(initialApplications: [prism, game, package, pending])
        model.selectedFilterID = "update.updateAvailable"
        #expect(Set(model.visibleApplications.map(\.id)) == Set(MenuBarUpdateList.items(in: model.applications).map(\.id)))
        #expect(model.updateStatusFilters.first(where: { $0.id == "update.updateAvailable" })?.count == 3)
        model.selectedFilterID = "update.sourcePending"
        #expect(model.visibleApplications.map(\.id) == [pending.id])
        // The separate Applications category keeps its original category meaning.
        #expect(!InventoryScope.applications.includes(prism))
    }

    @Test("Only the target is reread/checked and siblings, children and full-scan timestamp remain unchanged")
    func onlyTargetChanges() async {
        let target = item(id: "owner")
        let child = item(id: "child", parent: target.id)
        let other = item(id: "other")
        let fresh = candidate(target)
        let model = AppInventoryViewModel(initialApplications: [other, target, child])
        model.selectedFilterID = InventoryScope.allInOne.id
        model.expandedManagerIDs.insert(target.id)
        model.selectedApplicationID = target.id
        await model.refreshApplication(target, read: { item, _ in
            #expect(item == target)
            return fresh
        }, check: { apps, _ in
            #expect(apps.count == 1)
            #expect(apps.first?.id == target.id)
            var result = apps
            result[0].updateCheck = .init(availability: .upToDate, installedVersion: "2.0",
                latestVersion: "2.0", checkedAt: Date(), source: nil, detail: "Verified fixture")
            return result
        })
        #expect(model.applications.map(\.id) == [other.id, target.id, child.id])
        #expect(model.applications[0] == other)
        #expect(model.applications[2] == child)
        #expect(model.applications[1].displayVersion == "2.0")
        #expect(model.managedUpdateCount(for: model.applications[1]) == 1)
        #expect(model.selectedApplicationID == target.id)
        #expect(model.expandedManagerIDs.contains(target.id))
        #expect(model.lastScanDate == nil)
        #expect(!model.isScanning)
    }

    @Test("One-item refresh presents scan progress only while it is active")
    func refreshProgressLifetime() async {
        let target = item()
        let fresh = candidate(target)
        let model = AppInventoryViewModel(initialApplications: [target])
        let gate = BackgroundTestGate()
        let task = Task {
            await model.refreshApplication(target, read: { _, _ in
                await gate.wait()
                return fresh
            }, check: { apps, _ in apps })
        }
        await gate.waitUntilEntered()
        #expect(model.isScanning)
        #expect(model.isForegroundScan)
        gate.release()
        await task.value
        #expect(!model.isScanning)
        #expect(!model.isForegroundScan)
    }

    @Test("Canceled/skipped installation with unchanged metadata retains the available update")
    func unchangedInstallation() async {
        let target = item()
        let fresh = candidate(target, version: "1.0")
        let model = AppInventoryViewModel(initialApplications: [target])
        await model.refreshApplication(target, read: { _, _ in fresh }, check: { apps, _ in
            var result = apps
            result[0].updateCheck = target.updateCheck
            return result
        })
        #expect(model.applications[0].displayVersion == "1.0")
        #expect(model.applications[0].updateCheck.availability == .updateAvailable)
    }

    @Test("Unreadable or replaced target becomes failed; unrelated rows are retained")
    func failedRefresh() async {
        let target = item()
        let other = item(id: "other")
        let wrong = candidate(other)
        let model = AppInventoryViewModel(initialApplications: [target, other])
        await model.refreshApplication(target, read: { _, _ in wrong }, check: { _, _ in
            Issue.record("A changed identity must never be checked as the target")
            return []
        })
        #expect(model.applications[0].updateCheck.availability == .checkFailed)
        #expect(model.applications[0].updateCheck.latestVersion == nil)
        #expect(model.applications[1] == other)
        await model.refreshApplication(target, read: { _, _ in throw ApplicationRefreshService.Failure.managerUnreadable })
        #expect(model.applications[0].updateCheck.availability == .checkFailed)
        #expect(!model.isScanning)
    }

    @Test("Cancellation preserves the prior inventory and releases the scanning lock")
    func cancelledRefresh() async {
        let target = item()
        let fresh = candidate(target)
        let model = AppInventoryViewModel(initialApplications: [target])
        await model.refreshApplication(target, read: { _, control in
            control.cancel()
            return fresh
        }, check: { _, _ in
            Issue.record("Canceled refresh must not contact update sources")
            return []
        })
        #expect(model.applications == [target])
        #expect(!model.isScanning)
        #expect(!model.isForegroundScan)
        #expect(model.scanError != nil)
    }

    @Test("Fresh bundle metadata bypasses the cached Bundle and retains inventory ownership")
    func bundleReplacement() async throws {
        let directory = root()
        let url = directory.appendingPathComponent("Fixture.app")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeBundle(url, version: "1.0")
        let cached = try #require(Bundle(url: url))
        _ = cached.infoDictionary
        try writeBundle(url, version: "2.0")
        let target = item(path: url.path, id: "stable-id", parent: "owner")
        let fresh = try await ApplicationRefreshService().read(target, control: ScanControl(), run: { _, _ in
            Issue.record("Standalone bundle refresh must not run any package manager")
            throw ApplicationRefreshService.Failure.managerUnreadable
        })
        #expect(fresh.displayVersion == "2.0")
        #expect(fresh.inventoryID == target.id)
        #expect(fresh.parentInventoryID == "owner")
        try writeBundle(url, version: "3.0", bundleID: "test.replacement")
        await #expect(throws: (any Error).self) {
            try await ApplicationRefreshService().read(target, control: ScanControl())
        }
    }

    @Test("Formula refresh reads only its token and accepts a changed Cellar version path")
    func formulaRefresh() async throws {
        let p = provenance()
        let id = "package:homebrewFormula:/opt/homebrew/bin/brew:fixture"
        let target = item(path: "/opt/homebrew/Cellar/fixture/1.0", id: id, bundleID: "fixture",
                          kind: .commandLineTool, mechanism: .homebrew, provenance: p)
        let payload = Data("""
        {"formulae":[{"name":"fixture","installed":[{"version":"2.0","installed_on_request":true}],
        "versions":{"stable":"2.0"},"outdated":false,"pinned":false}],"casks":[]}
        """.utf8)
        let fresh = try await ApplicationRefreshService().read(target, control: ScanControl(), run: { cmd, _ in
            #expect(cmd.arguments == ["info", "--json=v2", "--formula", "fixture"])
            #expect(cmd.executable == "/opt/homebrew/bin/brew")
            #expect(cmd.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
            return .init(output: payload, terminationStatus: 0)
        })
        #expect(fresh.inventoryID == target.id)
        #expect(fresh.path == "/opt/homebrew/Cellar/fixture/2.0")
        #expect(fresh.packageProvenance?.isOutdated == false)
        let checked = await UpdateCheckService().check(UpdateDetectionEngine().classify([fresh],
            catalog: .init(schemaVersion: 1, catalogID: "fixture", revision: 1, generatedAt: Date(), expiresAt: nil, entries: [])))
        #expect(checked.first?.updateCheck.availability == .upToDate)
    }

    @Test("Cask refresh rereads bundle and receipt, and rejects a changed artifact owner")
    func caskRefresh() async throws {
        let directory = root()
        let url = directory.appendingPathComponent("Fixture.app")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeBundle(url, version: "2.0")
        let target = item(path: url.path, provenance: provenance(.homebrewCask))
        let payload = try JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [
            ["token": "fixture", "installed": "2.0", "version": "2.0", "outdated": false,
             "artifacts": [["app": ["Fixture.app"], "target": url.path]]]
        ]])
        let fresh = try await ApplicationRefreshService().read(target, control: ScanControl(), run: { cmd, _ in
            #expect(cmd.arguments == ["info", "--json=v2", "--cask", "fixture"])
            return .init(output: payload, terminationStatus: 0)
        })
        #expect(fresh.inventoryID == target.id)
        #expect(fresh.displayVersion == "2.0")
        #expect(fresh.packageProvenance?.installedVersion == "2.0")
        #expect(fresh.packageProvenance?.isOutdated == false)
        let wrong = try JSONSerialization.data(withJSONObject: ["formulae": [], "casks": [
            ["token": "fixture", "installed": "2.0", "version": "2.0", "outdated": false,
             "artifacts": [["app": ["/Applications/Other.app"]]]]
        ]])
        await #expect(throws: (any Error).self) {
            try await ApplicationRefreshService().read(target, control: ScanControl(), run: { _, _ in
                .init(output: wrong, terminationStatus: 0)
            })
        }
    }

    @Test("Wrong manager records and failed commands cannot mark an installation current")
    func invalidManagerRefresh() async {
        let target = item(id: "package:homebrewFormula:/opt/homebrew/bin/brew:fixture", bundleID: "fixture",
                          kind: .commandLineTool, provenance: provenance())
        for response in [PackageCommandResult(output: Data("{}".utf8), terminationStatus: 0),
            .init(output: Data(), terminationStatus: 1),
            .init(output: Data("{\"formulae\":[{\"name\":\"wrong\"}],\"casks\":[]}".utf8), terminationStatus: 0)] {
            await #expect(throws: (any Error).self) {
                try await ApplicationRefreshService().read(target, control: ScanControl(), run: { _, _ in response })
            }
        }
    }

    @Test("Inline update excludes App Store, unsupported managers and items with no confirmed update")
    func inlineEligibility() {
        #expect(ManagerUpdatePolicy.offersInlineUpdate(for: item(mechanism: .homebrew, provenance: provenance()), executableExists: { _ in true }))
        #expect(!ManagerUpdatePolicy.offersInlineUpdate(for: item(mechanism: .appStore)))
        #expect(!ManagerUpdatePolicy.offersInlineUpdate(for: item(provenance: provenance(.pythonPip)), executableExists: { _ in true }))
        #expect(!ManagerUpdatePolicy.offersInlineUpdate(for: item(mechanism: .homebrew, provenance: provenance(), availability: .upToDate), executableExists: { _ in true }))
    }

    @Test("Native menu uses small app images and kind symbols for packages")
    func menuIcons() throws {
        let directory = root()
        let url = directory.appendingPathComponent("Fixture.app")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeBundle(url, version: "1.0")
        let application = item(path: url.path)
        let installed = try #require(ApplicationIconImage.installedImage(for: application))
        let native = try #require(ApplicationIconImage.menuImage(for: application))
        #expect(native !== installed)
        #expect(!native.isTemplate)
        #expect(native.size == NSSize(width: 18, height: 18))
        let image = ApplicationIconImage.menuImage(for: item(kind: .commandLineTool))
        #expect(image?.size == NSSize(width: 18, height: 18))
        #expect(image?.isTemplate == true)
    }
}
