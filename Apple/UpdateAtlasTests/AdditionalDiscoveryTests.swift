import Foundation
import Testing
@testable import UpdateAtlas

struct AdditionalDiscoveryTests {
    @Test func epicRejectsRemovedIncompleteAndEscapingLaunchers() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("binary", root.appendingPathComponent("Game.app/Contents/MacOS/Game"))
        var record: [String: Any] = ["AppName": "epic-test", "DisplayName": "Example Game", "InstallLocation": root.path,
            "AppVersionString": "1.2.3", "LaunchExecutable": "Game.app/Contents/MacOS/Game", "bIsIncompleteInstall": false]
        let installed = try LocalDiscoveryProvider.epicGames(data: json(record))
        #expect(installed.count == 1)
        #expect(installed.first?.gamePlatform == .epic)
        #expect(installed.first?.displayVersion == "1.2.3")
        record["bIsIncompleteInstall"] = true
        #expect(try LocalDiscoveryProvider.epicGames(data: json(record)).isEmpty)
        record["bIsIncompleteInstall"] = false
        record["LaunchExecutable"] = "../outside.exe"
        #expect(try LocalDiscoveryProvider.epicGames(data: json(record)).isEmpty)
        record["LaunchExecutable"] = "Game.app/Contents/MacOS/Game"
        try FileManager.default.removeItem(at: root.appendingPathComponent("Game.app"))
        #expect(try LocalDiscoveryProvider.epicGames(data: json(record)).isEmpty)
    }

    @Test func heroicSeparatesTwoInstallationsAndOmitsDownloadsAndDLC() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("binary", root.appendingPathComponent("External/Game/game.exe"))
        try write("binary", root.appendingPathComponent("Internal/Game/game.exe"))
        let records: [String: Any] = [
            "a": ["app_name": "same-title", "install_path": root.appendingPathComponent("External/Game").path,
                  "title": "Example", "version": "1.0", "executable": "game.exe"],
            "b": ["app_name": "same-title", "install_path": root.appendingPathComponent("Internal/Game").path,
                  "title": "Example", "version": "2.0", "executable": "game.exe"],
            "download": ["app_name": "download", "install_path": root.path, "is_preloaded": true],
            "dlc": ["app_name": "dlc", "install_path": root.path, "is_dlc": true],
            "removed": ["app_name": "removed", "install_path": root.appendingPathComponent("Gone").path]
        ]
        let items = try LocalDiscoveryProvider.heroicGames(data: json(records), platform: .epic)
        #expect(items.count == 2)
        #expect(Set(items.map(\.inventoryID)).count == 2)
        #expect(items.allSatisfy { $0.parentManagerBundleIdentifier == "com.heroicgameslauncher.hgl" })
    }

    @Test func heroicFilterKeepsStoreIdentityWhileIncludingItsManager() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("binary", root.appendingPathComponent("game.exe"))
        let games = try LocalDiscoveryProvider.heroicGames(data: json(["installed": [
            ["appName": "123", "install_path": root.path, "version": "1.0", "executable": "game.exe"]
        ]]), platform: .gog)
        let catalog = RemoteCatalog(schemaVersion: 1, catalogID: "test", revision: 0, generatedAt: Date(), expiresAt: nil, entries: [])
        let game = try #require(UpdateDetectionEngine().classify(games, catalog: catalog).first)
        #expect(game.gamePlatform == .gog)
        #expect(GamePlatformKind.gog.includes(game))
        #expect(GamePlatformKind.heroic.includes(game))
        #expect(game.parentManagerName == "Heroic")
    }

    @Test func heroicGOGRequiresPayloadEvenWhenExecutableIsEmpty() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let row: [String: Any] = ["appName": "123", "install_path": root.path, "version": "3.2", "executable": ""]
        #expect(try LocalDiscoveryProvider.heroicGames(data: json(["installed": [row]]), platform: .gog).isEmpty)
        try write("binary", root.appendingPathComponent("bin/Game.exe"))
        let items = try LocalDiscoveryProvider.heroicGames(data: json(["installed": [row]]), platform: .gog)
        #expect(items.count == 1)
        #expect(items.first?.displayVersion == "3.2")
        #expect(throws: (any Error).self) { try LocalDiscoveryProvider.heroicGames(data: Data("{}".utf8), platform: .gog) }
    }

    @Test func gogManifestDoesNotUseSchemaVersionAsGameVersion() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("binary", root.appendingPathComponent("bin/game.exe"))
        let record: [String: Any] = ["gameId": "123456", "name": "Example", "version": 1,
            "playTasks": [["type": "FileTask", "path": "bin\\game.exe"]]]
        let item = try #require(try LocalDiscoveryProvider.gogGame(data: json(record), root: root))
        #expect(item.displayVersion == "Unknown")
        let catalog = RemoteCatalog(schemaVersion: 1, catalogID: "test", revision: 0, generatedAt: Date(), expiresAt: nil, entries: [])
        let classified = try #require(UpdateDetectionEngine().classify([item], catalog: catalog).first)
        #expect(classified.status == .managedExternally)
        #expect(classified.updateCheck.availability != .upToDate)
    }

    @Test func galaxyReadsOnlyLiveInstallationsAndRetainsUnknownVersion() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("binary", root.appendingPathComponent("game.exe"))
        let items = try LocalDiscoveryProvider.galaxyGames(data: json([
            ["productId": 123, "installationPath": root.path],
            ["productId": 456, "installationPath": root.appendingPathComponent("Removed").path]
        ]))
        #expect(items.count == 1)
        #expect(items.first?.displayVersion == "Unknown")
    }

    @Test func galaxyDatabaseUsesReadOnlyInstalledTableAndReportsBadSchema() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("Shared")
        let db = shared.appendingPathComponent("GOG.com/Galaxy/Storage/galaxy-2.0.db")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        let game = root.appendingPathComponent("Game")
        try write("binary", game.appendingPathComponent("Game.exe"))
        let path = game.path.replacingOccurrences(of: "'", with: "''")
        let created = try PackageCommandRunner.run(executable: "/usr/bin/sqlite3", arguments: [db.path,
            "CREATE TABLE InstalledBaseProducts(productId INTEGER, installationPath TEXT); INSERT INTO InstalledBaseProducts VALUES(123, '\(path)');"], control: ScanControl())
        #expect(created.terminationStatus == 0)
        let before = try Data(contentsOf: db)
        let provider = LocalDiscoveryProvider(home: root, shared: shared, applicationRoots: [])
        let result = provider.scan(configuration: .init(), control: ScanControl())
        #expect(result.candidates.count == 1)
        #expect(result.diagnostics.isEmpty)
        #expect(try Data(contentsOf: db) == before)
        let cleared = try PackageCommandRunner.run(executable: "/usr/bin/sqlite3", arguments: [db.path,
            "DELETE FROM InstalledBaseProducts;"], control: ScanControl())
        #expect(cleared.terminationStatus == 0)
        let empty = provider.scan(configuration: .init(), control: ScanControl())
        #expect(empty.candidates.isEmpty && empty.diagnostics.isEmpty)
        let dropped = try PackageCommandRunner.run(executable: "/usr/bin/sqlite3", arguments: [db.path,
            "DROP TABLE InstalledBaseProducts;"], control: ScanControl())
        #expect(dropped.terminationStatus == 0)
        let failure = provider.scan(configuration: .init(), control: ScanControl()).diagnostics.first
        #expect(failure?.source == "GOG Galaxy")
        #expect(failure?.reason == .commandFailed)
        #expect(failure?.operation == .gogInstalledTable)
    }

    @Test func selectedFoldersIgnoreNestedBundlesSymlinksAndCapTraversal() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try bundle(root.appendingPathComponent("Main.app"), id: "test.main")
        try bundle(root.appendingPathComponent("Main.app/Contents/Helper.app"), id: "test.helper")
        try bundle(root.appendingPathComponent("Nested/Other.app"), id: "test.other")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        var diagnostics: [ScanDiagnostic] = []
        let files = LocalDiscoveryProvider.walk(root: root, control: ScanControl(), source: "Fixture", diagnostics: &diagnostics)
        #expect(files.filter { $0.pathExtension == "app" }.count == 2)
        #expect(!files.contains { $0.lastPathComponent == "Helper.app" })
        diagnostics = []
        _ = LocalDiscoveryProvider.walk(root: root, maximumEntries: 1, control: ScanControl(), source: "Fixture", diagnostics: &diagnostics)
        #expect(diagnostics.contains { $0.reason == .outputTooLarge })
        #expect(LocalDiscoveryProvider.walk(root: root, control: ScanControl(timeout: 0), source: "Fixture", diagnostics: &diagnostics).isEmpty)
    }

    @Test func foldersAndManagerRootsDiscoverBundlesWithoutGuessingOwnership() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try bundle(apps.appendingPathComponent("Setapp/Example.app"), id: "test.setapp")
        try bundle(apps.appendingPathComponent("Adobe Photoshop 2026/Photoshop.app"), id: "com.adobe.Photoshop")
        try bundle(root.appendingPathComponent("Library/Application Support/JetBrains/Toolbox/apps/IDE/ch-0/123/IDE.app"), id: "com.jetbrains.intellij")
        try bundle(root.appendingPathComponent("External/Apps/Extra.app"), id: "test.extra")
        let result = LocalDiscoveryProvider(home: root, shared: root.appendingPathComponent("Shared"), applicationRoots: [apps])
            .scan(configuration: .init(folders: [root.appendingPathComponent("External")]), control: ScanControl())
        #expect(result.bundles.count == 4)
        #expect(result.bundles.first { $0.source == "Setapp" }?.manager == "com.setapp.DesktopClient")
        #expect(result.bundles.first { $0.source == "Adobe" }?.manager == nil)
        #expect(result.bundles.first { $0.source == "JetBrains Toolbox" }?.manager == "com.jetbrains.toolbox")
    }

    @Test func wineBottlesUseNativeMetadataAndNeverInventWindowsPrograms() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cross = root.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Work")
        try write("[Bottle]\n", cross.appendingPathComponent("cxbottle.conf"))
        try FileManager.default.createDirectory(at: cross.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let whisky = root.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles/uuid")
        try FileManager.default.createDirectory(at: whisky.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try writePlist(["info": ["name": "Gaming"]], whisky.appendingPathComponent("Metadata.plist"))
        try writePlist(["info": ["name": "Removed"]], whisky.deletingLastPathComponent().appendingPathComponent("stale/Metadata.plist"))
        let result = LocalDiscoveryProvider(home: root, shared: root.appendingPathComponent("Shared"), applicationRoots: [])
            .scan(configuration: .init(), control: ScanControl())
        #expect(result.candidates.count == 2)
        #expect(Set(result.candidates.map(\.name)) == ["Work", "Gaming"])
        #expect(result.candidates.allSatisfy { $0.kind == .wineBottle && $0.displayVersion == "Unknown" })
    }

    @Test func whiskyRegistryFindsExternalBottlesAndSkipsStaleReferences() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("External Drive/Gaming")
        try FileManager.default.createDirectory(at: external.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        try writePlist(["info": ["name": "External Bottle"]], external.appendingPathComponent("Metadata.plist"))
        struct Registry: Encodable { let paths: [URL] }
        let registry = root.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/BottleVM.plist")
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Registry(paths: [external, root.appendingPathComponent("Removed")])).write(to: registry)
        let result = LocalDiscoveryProvider(home: root, shared: root.appendingPathComponent("Shared"), applicationRoots: [])
            .scan(configuration: .init(), control: ScanControl())
        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.name == "External Bottle")
    }

    @Test func additionalBundlesRequireTheirActualExecutableAndCannotEscapeTheirBundle() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Gone.app")
        try bundle(app, id: "test.gone")
        #expect(LocalDiscoveryProvider.installedBundle(app))
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/Example"))
        #expect(!LocalDiscoveryProvider.installedBundle(app))
        try write("binary", root.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/MacOS/Example"), withDestinationURL: root.appendingPathComponent("outside"))
        #expect(!LocalDiscoveryProvider.installedBundle(app))
    }

    @Test func overlappingGameManifestPreservesExistingBundleIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let existing = ApplicationCandidate(inventoryID: "old-native-ID", path: root.appendingPathComponent("Game.app").path,
            name: "Example", bundleIdentifier: "test.game", displayVersion: "1.0", buildVersion: "1.0", teamIdentifier: nil,
            parentManagerBundleIdentifier: nil, isSystemApplication: false, info: [:], kind: .game)
        let added = ApplicationCandidate(inventoryID: "new-manifest-ID", path: root.path, name: "Example",
            bundleIdentifier: "epic-game:123", displayVersion: "1.1", buildVersion: "1.1", teamIdentifier: nil,
            parentManagerBundleIdentifier: "com.epicgames.EpicGamesLauncher", isSystemApplication: false,
            info: ["DiscoverySource": "Epic Games"], kind: .game, gamePlatform: .epic)
        let reconciled = ApplicationScanner.reconcileAdditional([added], with: [existing.inventoryID: existing])
        #expect(reconciled.count == 1)
        #expect(reconciled["old-native-ID"]?.displayVersion == "1.0")
    }

    @Test func preferencesAreSharedAndCLIFolderOptionsDoNotPersist() throws {
        let suite = "discovery-fixture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/Volumes/Apps", "/Volumes/Apps"], forKey: DiscoveryConfiguration.foldersKey)
        defaults.set(true, forKey: DiscoveryConfiguration.dockerKey)
        #expect(DiscoveryConfiguration.current(from: defaults).folders.count == 1)
        #expect(DiscoveryConfiguration.current(from: defaults).includeDocker)
        let query = try CLIInventoryQuery(arguments: ["scan", "--folder", "/Volumes/Other Apps", "--folder", "/Applications", "--no-docker"])
        #expect(query.folders.count == 2)
        #expect(query.docker == false)
        #expect(defaults.stringArray(forKey: DiscoveryConfiguration.foldersKey)?.count == 2)
        #expect(throws: (any Error).self) { try CLIInventoryQuery(arguments: ["scan", "--folder", "relative"]) }
        #expect(throws: (any Error).self) { try CLIInventoryQuery(arguments: ["scan", "--docker", "--no-docker"]) }
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".temporary_files/discovery/fixtures/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func writePlist(_ value: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }
    private func bundle(_ url: URL, id: String) throws {
        try writePlist(["CFBundleIdentifier": id, "CFBundleName": "Example", "CFBundleShortVersionString": "1.0", "CFBundleExecutable": "Example"], url.appendingPathComponent("Contents/Info.plist"))
        try write("binary", url.appendingPathComponent("Contents/MacOS/Example"))
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
