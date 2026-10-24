import Foundation
import XCTest
@testable import UpdateAtlas

final class CLIContractTests: XCTestCase {
    func testPartialAndCancellationTakePriorityOverUpdates() throws {
        XCTAssertEqual(CLIContract.scanExit(diagnostics: [], failedChecks: 0, catalogWarning: false,
            cancelled: false, updates: 2, failOnUpdates: false), .success)
        XCTAssertEqual(CLIContract.scanExit(diagnostics: [], failedChecks: 0, catalogWarning: false,
            cancelled: false, updates: 2, failOnUpdates: true), .updatesAvailable)
        XCTAssertEqual(CLIContract.scanExit(diagnostics: [.init(source: "npm", reason: .commandFailed)],
            failedChecks: 0, catalogWarning: false, cancelled: false, updates: 2, failOnUpdates: true), .partial)
        XCTAssertEqual(CLIContract.scanExit(diagnostics: [.init(source: "Docker", reason: .offlineSkipped)],
            failedChecks: 0, catalogWarning: false, cancelled: false, updates: 0, failOnUpdates: true), .success)
        XCTAssertEqual(CLIContract.scanExit(diagnostics: [], failedChecks: 1, catalogWarning: false,
            cancelled: false, updates: 0, failOnUpdates: false), .partial)
        XCTAssertEqual(CLIContract.scanExit(diagnostics: [], failedChecks: 0, catalogWarning: true,
            cancelled: true, updates: 0, failOnUpdates: false), .cancelled)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CLIContract.Failure("invalid_arguments", message: "Invalid input", exit: .usage))) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual((json["error"] as? [String: Any])?["exitCode"] as? Int, 2)
    }

    func testOfflineAndUpdateExitFlagsAreExplicitAndRejectDuplicates() throws {
        let query = try CLIInventoryQuery(arguments: ["check", "--offline", "--fail-on-updates"])
        XCTAssertTrue(query.offline)
        XCTAssertTrue(query.failOnUpdates)
        XCTAssertThrowsError(try CLIInventoryQuery(arguments: ["scan", "--offline", "--offline"]))
    }

    func testPreferencesUseExistingDomainKeysAndPreserveUnrelatedValues() throws {
        let suite = "CLIContractTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated")
        defaults.set(true, forKey: InventorySettings.includeSystemApplicationsKey)
        let preferences = CLIPreferences(defaults: defaults)
        XCTAssertEqual(try preferences.get("include-system"), .bool(true))
        try preferences.set("include-system", value: "false")
        XCTAssertFalse(defaults.bool(forKey: InventorySettings.includeSystemApplicationsKey))
        try preferences.reset("include-system")
        XCTAssertNil(defaults.object(forKey: InventorySettings.includeSystemApplicationsKey))
        XCTAssertThrowsError(try preferences.set("include-system", value: "yes"))
        XCTAssertThrowsError(try preferences.set("check-interval-hours", value: "2"))
        XCTAssertThrowsError(try preferences.set("unrelated", value: "change"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testMenuIconCLISettingUsesTheOnboardingAndMenuKey() throws {
        let suite = "CLIContractTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CLIPreferences(defaults: defaults)

        defaults.set(false, forKey: MenuBarSettings.showAppIconsKey)
        XCTAssertEqual(try preferences.get("menu-bar-icons"), .bool(false))
        try preferences.set("menu-bar-icons", value: "true")
        XCTAssertTrue(MenuBarSettings.showAppIcons(in: defaults))
        XCTAssertNil(defaults.object(forKey: "menuBar.showAppIcons"))
    }

    @MainActor
    func testCLILinkRequiresAnExecutableTargetBeforeClaimingInstalled() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let home = project.appendingPathComponent(".temporary_files/CLIContractTests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let tool = home.appendingPathComponent("Update Atlas.app/Contents/MacOS/Helpers/update-atlas")
        let link = CLIInstallationService.installedLink(home: home)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        XCTAssertTrue(CLIInstallationService.installationState(home: home, bundledTool: tool).isInstalled)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.path)
        XCTAssertEqual(CLIInstallationService.installationState(home: home, bundledTool: tool),
                       .installedNeedsRepair(tool.path))
        try FileManager.default.removeItem(at: tool)
        XCTAssertEqual(CLIInstallationService.installationState(home: home, bundledTool: tool),
                       .installedNeedsRepair(tool.path))
        try FileManager.default.removeItem(at: link)
        let foreign = home.appendingPathComponent("other-tool")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
        XCTAssertEqual(CLIInstallationService.installationState(home: home, bundledTool: tool),
                       .installedNeedsRepair(foreign.path))
    }

    @MainActor
    func testPATHCardRecognizesOnlyAnActualLocalBinComponent() {
        let home = URL(fileURLWithPath: "/Users/test-user")
        XCTAssertTrue(CLIInstallationService.isLocalBinInPATH("/usr/bin:/Users/test-user/.local/bin", home: home))
        XCTAssertTrue(CLIInstallationService.isLocalBinInPATH("/usr/bin:~/.local/bin", home: home))
        XCTAssertFalse(CLIInstallationService.isLocalBinInPATH("/usr/bin:/Users/test-user/.local/bin-old", home: home))
        XCTAssertFalse(CLIInstallationService.isLocalBinInPATH("/opt/~/.local/bin", home: home))
    }

    func testFolderMutationCanonicalizesAndRemovesOnlyTheSelectedFolder() throws {
        let suite = "CLIContractTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".temporary_files/CLIContractTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = CLIPreferences(defaults: defaults)
        try preferences.folder("add", path: root.path)
        try preferences.folder("add", path: root.appendingPathComponent(".").path)
        XCTAssertEqual(DiscoveryConfiguration.current(from: defaults).folders.count, 1)
        XCTAssertThrowsError(try preferences.folder("add", path: "relative"))
        try preferences.folder("remove", path: root.path)
        XCTAssertEqual(DiscoveryConfiguration.current(from: defaults).folders.count, 0)
    }

    func testOfflineReceiptsKeepInstalledVersionsButNeverClaimLatest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".temporary_files/CLIContractTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let formula = root.appendingPathComponent("Cellar/test-tool/1.2.3")
        let package = root.appendingPathComponent("lib/node_modules/@scope/tool")
        for path in [formula, package] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data(#"{"installed_on_request":true,"source":{"versions":{"stable":"9.0.0"}}}"#.utf8)
            .write(to: formula.appendingPathComponent("INSTALL_RECEIPT.json"))
        try Data(#"{"name":"@scope/tool","version":"2.0.0"}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        let snapshot = OfflinePackageInventory.scan(home: root, prefixes: [root])
        XCTAssertEqual(snapshot.candidates.count, 2)
        XCTAssertEqual(Set(snapshot.candidates.map(\.displayVersion)), ["1.2.3", "2.0.0"])
        XCTAssertTrue(snapshot.candidates.allSatisfy { $0.packageProvenance?.latestVersion == nil && $0.packageProvenance?.isOutdated == nil })
        let classified = UpdateDetectionEngine().classify(snapshot.candidates,
            catalog: RemoteCatalog(schemaVersion: 1, catalogID: "test", revision: 1,
                generatedAt: Date(), expiresAt: nil, entries: []))
        XCTAssertTrue(classified.allSatisfy { $0.updateCheck.availability != .upToDate && $0.updateCheck.availability != .updateAvailable })
        XCTAssertEqual(snapshot.diagnostics.map(\.reason), [.offlineSkipped])
    }
}
