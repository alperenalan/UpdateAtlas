import Foundation
import XCTest
@testable import UpdateAtlas

final class DetectionEngineTests: XCTestCase {
    func testAppStoreReceiptTakesPrecedenceOverBundledSparkle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/_MASReceipt", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("Contents/_MASReceipt/receipt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/Frameworks/Sparkle.framework", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let application = UpdateDetectionEngine().classify(
            [candidate(path: root.path)],
            catalog: emptyCatalog
        ).first

        XCTAssertEqual(application?.mechanism, .appStore)
        XCTAssertEqual(application?.status, .supported)
    }

    func testNestedUnityEditorIsManagedExternally() {
        let application = UpdateDetectionEngine().classify(
            [candidate(path: "/Applications/Unity/Hub/Editor/6000.1.4f1/Unity.app", parent: "com.unity3d.unityhub")],
            catalog: emptyCatalog
        ).first

        XCTAssertEqual(application?.mechanism, .externalManager)
        XCTAssertEqual(application?.status, .managedExternally)
        XCTAssertEqual(application?.parentManagerName, "Unity Hub")
    }

    func testSteamGameIsManagedBySteam() {
        let steamGame = ApplicationCandidate(
            path: "/Users/example/Library/Application Support/Steam/steamapps/common/Example/Example.app",
            name: "Example",
            bundleIdentifier: "com.example.game",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: nil,
            parentManagerBundleIdentifier: GamePlatformKind.steam.managerBundleIdentifier,
            isSystemApplication: false,
            info: [:],
            kind: .game,
            gamePlatform: .steam
        )

        let application = UpdateDetectionEngine().classify([steamGame], catalog: emptyCatalog).first

        XCTAssertEqual(application?.kind, .game)
        XCTAssertEqual(application?.gamePlatform, .steam)
        XCTAssertEqual(application?.mechanism, .externalManager)
        XCTAssertEqual(application?.status, .managedExternally)
        XCTAssertEqual(application?.parentManagerName, "Steam")
        XCTAssertEqual(application?.updateCheck.availability, .managedExternally)
    }

    func testSteamLocalTargetBuildShowsManagerOwnedUpdate() async {
        let game = ApplicationCandidate(
            path: "/Users/example/Library/Application Support/Steam/steamapps/common/Game",
            name: "Game",
            bundleIdentifier: "steam-app:123",
            displayVersion: "100",
            buildVersion: "100",
            teamIdentifier: nil,
            parentManagerBundleIdentifier: "com.valvesoftware.steam",
            isSystemApplication: false,
            info: [
                "SteamBuildID": "100", "SteamTargetBuildID": "101",
                "SteamManifestPath": "/Users/example/Steam/steamapps/appmanifest_123.acf"
            ],
            kind: .game,
            gamePlatform: .steam
        )
        let detected = UpdateDetectionEngine().classify([game], catalog: emptyCatalog)
        XCTAssertEqual(detected.first?.updateCheck.availability, .updateAvailable)
        let checked = await UpdateCheckService().check(detected)
        XCTAssertEqual(checked.first?.updateCheck.source, .steamManifest)
        XCTAssertEqual(checked.first?.updateCheck.installedVersion, "100")
        XCTAssertEqual(checked.first?.updateCheck.latestVersion, "101")
        XCTAssertTrue(checked.first?.evidence.contains(where: { $0.detail.hasSuffix("appmanifest_123.acf") }) == true)
    }

    func testGoogleUpdaterNeedsCatalogWithoutAnActiveRule() {
        let googleApplication = ApplicationCandidate(
            path: "/Applications/Google Chrome.app",
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            displayVersion: "153.0.8010.48",
            buildVersion: "8010.48",
            teamIdentifier: "EQHXZ8M8AV",
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: ["KSUpdateURL": "https://tools.google.com/service/update2"]
        )

        let application = UpdateDetectionEngine().classify(
            [googleApplication],
            catalog: emptyCatalog
        ).first

        XCTAssertEqual(application?.mechanism, .googleUpdater)
        XCTAssertEqual(application?.status, .needsCatalog)
        XCTAssertEqual(application?.updateCheck.availability, .sourcePending)
        XCTAssertNil(application?.catalogEntryID)
    }

    func testManagedComfyUIChildCanStillHaveIndependentUpdateProvider() {
        let provider = CatalogVersionProvider(
            type: .githubLatestRelease,
            url: URL(string: "https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest")!,
            channel: "stable"
        )
        let entry = CatalogEntry(
            id: "comfyui",
            displayName: "ComfyUI",
            match: CatalogMatch(
                bundleIdentifiers: ["org.comfy.ComfyUI"],
                teamIdentifiers: nil,
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .externalManager,
                name: "Comfy Desktop · Stable",
                feedURL: nil,
                managerBundleIdentifier: "com.todesktop.241012ess7yxs0e",
                provider: provider
            ),
            support: .supported,
            vendorURL: URL(string: "https://github.com/Comfy-Org/ComfyUI"),
            notes: nil
        )
        let catalog = RemoteCatalog(
            schemaVersion: 1,
            catalogID: "test",
            revision: 1,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            entries: [entry]
        )
        let child = ApplicationCandidate(
            path: "/Users/example/ComfyUI",
            name: "ComfyUI",
            bundleIdentifier: "org.comfy.ComfyUI",
            displayVersion: "v0.35.1",
            buildVersion: "v0.35.1",
            teamIdentifier: nil,
            parentManagerBundleIdentifier: "com.todesktop.241012ess7yxs0e",
            isSystemApplication: false,
            info: ["UpdateChannel": "stable"],
            kind: .managedComponent
        )

        let application = UpdateDetectionEngine().classify([child], catalog: catalog).first

        XCTAssertEqual(application?.status, .supported)
        XCTAssertEqual(application?.mechanism, .externalManager)
        XCTAssertEqual(application?.parentManagerName, "Comfy Desktop")
        XCTAssertEqual(application?.versionProvider, provider)
        XCTAssertEqual(application?.kind, .managedComponent)
    }

    func testVisualStudioCodeExtensionIsASeparatelyCheckableExtension() throws {
        let extensionCandidate = ApplicationCandidate(
            inventoryID: "extension:vscode:ms-python.python",
            path: "/Users/example/.vscode/extensions/ms-python.python-2026.6.0",
            name: "Python",
            bundleIdentifier: "vscode-extension:ms-python.python",
            displayVersion: "2026.6.0",
            buildVersion: "2026.6.0",
            teamIdentifier: nil,
            parentManagerBundleIdentifier: "com.microsoft.VSCode",
            isSystemApplication: false,
            info: [
                "ManagedComponentType": "vscode-extension",
                "ExtensionIdentifier": "ms-python.python",
                "TargetPlatform": "darwin-arm64",
                "HostVersion": "1.138.0",
                "IncludePrerelease": "false"
            ],
            kind: .extension
        )

        let application = try XCTUnwrap(
            UpdateDetectionEngine().classify([extensionCandidate], catalog: emptyCatalog).first
        )

        XCTAssertEqual(application.status, .supported)
        XCTAssertEqual(application.mechanism, .ideExtension)
        XCTAssertEqual(application.parentManagerName, "Visual Studio Code")
        XCTAssertEqual(application.kind, .extension)
        XCTAssertEqual(application.versionProvider?.type, .visualStudioMarketplace)
        XCTAssertEqual(application.versionProvider?.identifier, "ms-python.python")
        XCTAssertEqual(application.versionProvider?.targetPlatform, "darwin-arm64")
        XCTAssertEqual(application.versionProvider?.hostVersion, "1.138.0")
        XCTAssertEqual(application.versionProvider?.includePrerelease, false)
    }

    private var emptyCatalog: RemoteCatalog {
        RemoteCatalog(
            schemaVersion: 1,
            catalogID: "test",
            revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            entries: []
        )
    }

    private func candidate(path: String, parent: String? = nil) -> ApplicationCandidate {
        ApplicationCandidate(
            path: path,
            name: "Example",
            bundleIdentifier: "com.example.app",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: "TEAM123",
            parentManagerBundleIdentifier: parent,
            isSystemApplication: false,
            info: [:]
        )
    }
}
