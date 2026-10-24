import Foundation
import XCTest
@testable import UpdateAtlas

@MainActor
final class SelfMaintenanceTests: XCTestCase {
    private enum SimulatedUninstallError: Error {
        case appMove
        case dataCleanup
    }

    func testConfirmedUninstallTerminatesAfterAppMovesEvenIfCleanupFails() async {
        var events: [String] = []
        await SelfUninstallService.shared.performConfirmedUninstall(
            prepare: { events.append("prepare") },
            moveApp: { events.append("move app") },
            finish: {
                events.append("clean data")
                throw SimulatedUninstallError.dataCleanup
            },
            onError: { _ in events.append("show error") },
            terminate: { events.append("terminate") }
        )
        XCTAssertEqual(events, ["prepare", "move app", "clean data", "show error", "terminate"])
        XCTAssertTrue(SelfUninstallService.shared.hasMovedAppToTrash)
    }

    func testFailedAppMoveKeepsTheAppRunningForRetry() async {
        var events: [String] = []
        await SelfUninstallService.shared.performConfirmedUninstall(
            prepare: { events.append("prepare") },
            moveApp: {
                events.append("move app")
                throw SimulatedUninstallError.appMove
            },
            finish: { events.append("clean data") },
            onError: { _ in events.append("show error") },
            terminate: { events.append("terminate") }
        )
        XCTAssertEqual(events, ["prepare", "move app", "show error"])
        XCTAssertFalse(SelfUninstallService.shared.hasMovedAppToTrash)
    }


    func testRunningAppUsesTheConfiguredBundleIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, AppIdentity.bundleIdentifier)
    }

    func testUninstallTargetsOnlyExistingAppOwnedPaths() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }

        let appCache = home.appendingPathComponent("Library/Caches/\(AppIdentity.bundleIdentifier)")
        let otherCache = home.appendingPathComponent("Library/Caches/com.other.app")
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherCache, withIntermediateDirectories: true)

        let targets = SelfUninstallService.shared.ownedDataURLs(home: home)
        XCTAssertEqual(targets, [appCache.standardizedFileURL])
        XCTAssertFalse(targets.contains(otherCache))
    }

    func testCLIUninstallOnlyRemovesLinkToThisApp() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Update Atlas.app")
        let link = CLIInstallationService.installedLink(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: app.appendingPathComponent("Contents/MacOS/Helpers/update-atlas")
        )
        try CLIInstallationService.removeOwnedLink(for: app, home: home)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))

        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: home.appendingPathComponent("another-tool")
        )
        try CLIInstallationService.removeOwnedLink(for: app, home: home)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testRetainedCLIHasIndependentSignedHelperResourcesAndVersion() throws {
        let home = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".temporary_files/self-uninstall-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Update Atlas.app")
        let contents = app.appendingPathComponent("Contents")
        let tool = contents.appendingPathComponent("MacOS/Helpers/update-atlas")
        let catalog = contents.appendingPathComponent("Resources/BootstrapCatalog.json")
        let info = contents.appendingPathComponent("Info.plist")
        let link = CLIInstallationService.installedLink(home: home)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try Data("{}".utf8).write(to: catalog)
        try (NSDictionary(dictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "30"]))
            .write(to: info)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        try CLIInstallationService.retainOwnedCLI(for: app, home: home)
        let destination = link.resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
        XCTAssertFalse(destination.path.hasPrefix(app.path))
        XCTAssertEqual(BundledAppResources.bootstrapCatalogURL(executableURL: link)?.path,
                       destination.deletingLastPathComponent().appendingPathComponent("BootstrapCatalog.json").path)
        XCTAssertEqual(BundledAppResources.versionInfo(executableURL: link)?["CFBundleVersion"] as? String, "30")
    }

    func testPathDisplayAbbreviatesOnlyTheHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(SelfUninstallService.shared.displayPath(home.appendingPathComponent("Library/Caches/app"), home: home),
                       "~/Library/Caches/app")
        XCTAssertEqual(SelfUninstallService.shared.displayPath(URL(fileURLWithPath: "/Users/example2/App.app"), home: home),
                       "/Users/example2/App.app")
    }
}
