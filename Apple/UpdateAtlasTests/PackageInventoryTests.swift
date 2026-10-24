import Foundation
import XCTest
@testable import UpdateAtlas

final class PackageInventoryTests: XCTestCase {
    func testHomebrewIncludesRequestedFormulaAndMapsCaskTarget() throws {
        let json = #"""
        {
          "formulae": [
            {
              "name": "wanted-tool",
              "desc": "A requested CLI",
              "homepage": "https://example.com/wanted",
              "installed": [{"version": "2.4.0", "installed_on_request": true}],
              "outdated": false
            },
            {
              "name": "dependency-only",
              "installed": [{"version": "1.0.0", "installed_on_request": false}],
              "outdated": false
            }
          ],
          "casks": [
            {
              "token": "sample-app",
              "name": ["Sample App"],
              "desc": "A sample app",
              "homepage": "https://example.com/sample",
              "installed": "3.1.0",
              "outdated": true,
              "artifacts": [{"app": ["Sample App.app"], "target": "/Applications/Sample App.app"}]
            }
          ]
        }
        """#

        let snapshot = PackageInventoryScanner.parseHomebrew(
            data: Data(json.utf8),
            executablePath: "/opt/homebrew/bin/brew"
        )

        XCTAssertEqual(snapshot.candidates.map(\.name), ["wanted-tool"])
        XCTAssertEqual(snapshot.candidates.first?.packageProvenance?.manager, .homebrewFormula)
        XCTAssertEqual(
            snapshot.caskApplicationsByPath["/Applications/Sample App.app"]?.identifier,
            "sample-app"
        )
        XCTAssertEqual(
            snapshot.caskApplicationsByPath["/Applications/Sample App.app"]?.isOutdated,
            true
        )
    }

    func testNPMParsesOnlyGlobalTopLevelDependenciesAndSkipsNPMItself() {
        let json = #"""
        {
          "dependencies": {
            "npm": {"version": "11.0.0"},
            "@scope/tool": {"version": "1.2.3"}
          }
        }
        """#

        let candidates = PackageInventoryScanner.parseNPM(
            data: Data(json.utf8),
            executablePath: "/opt/homebrew/bin/npm",
            globalRoot: "/opt/homebrew/lib/node_modules"
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.name, "@scope/tool")
        XCTAssertEqual(candidates.first?.displayVersion, "1.2.3")
        XCTAssertEqual(candidates.first?.packageProvenance?.manager, .npm)
    }

    func testNPMOutdatedMetadataIncludesLatestVersion() {
        let installed = #"{"dependencies":{"sample":{"version":"2.0.9"}}}"#
        let outdated = #"{"sample":{"current":"2.0.9","wanted":"2.1.0","latest":"2.1.0"}}"#

        let candidate = PackageInventoryScanner.parseNPM(
            data: Data(installed.utf8),
            executablePath: "/opt/homebrew/bin/npm",
            globalRoot: nil,
            outdatedData: Data(outdated.utf8)
        ).first

        XCTAssertEqual(candidate?.packageProvenance?.isOutdated, true)
        XCTAssertEqual(candidate?.packageProvenance?.latestVersion, "2.1.0")
    }

    func testPythonParserExcludesBootstrapPackagingTools() {
        let json = #"""
        [
          {"name": "pip", "version": "25.0"},
          {"name": "wheel", "version": "0.45"},
          {"name": "requests", "version": "2.32.5"}
        ]
        """#

        let candidates = PackageInventoryScanner.parsePythonPip(
            data: Data(json.utf8),
            executablePath: "/Users/example/.pyenv/shims/python3"
        )

        XCTAssertEqual(candidates.map(\.name), ["requests"])
        XCTAssertEqual(candidates.first?.packageProvenance?.manager, .pythonPip)
    }

    func testPipOutdatedMetadataIncludesLatestVersion() {
        let installed = #"[{"name":"requests","version":"2.32.5"}]"#
        let outdated = #"[{"name":"requests","version":"2.32.5","latest_version":"2.33.0"}]"#

        let candidate = PackageInventoryScanner.parsePythonPip(
            data: Data(installed.utf8),
            executablePath: "/opt/homebrew/bin/python3",
            outdatedData: Data(outdated.utf8)
        ).first

        XCTAssertEqual(candidate?.packageProvenance?.isOutdated, true)
        XCTAssertEqual(candidate?.packageProvenance?.latestVersion, "2.33.0")
    }

    func testSelectionNavigatorClampsAtListEdges() {
        let ids = ["one", "two", "three"]

        XCTAssertEqual(SelectionNavigator.adjacentID(in: ids, current: "two", offset: 1), "three")
        XCTAssertEqual(SelectionNavigator.adjacentID(in: ids, current: "three", offset: 1), "three")
        XCTAssertEqual(SelectionNavigator.adjacentID(in: ids, current: "one", offset: -1), "one")
        XCTAssertEqual(SelectionNavigator.adjacentID(in: ids, current: nil, offset: 1), "one")
    }

    func testVerifiedCaskProvenanceIsShownAsHomebrewCask() {
        let provenance = PackageProvenance(
            identifier: "sample-app",
            manager: .homebrewCask,
            managerExecutablePath: "/opt/homebrew/bin/brew",
            installLocation: "/Applications/Sample App.app",
            explicitlyInstalled: true,
            homepage: nil,
            summary: nil,
            isOutdated: false
        )
        let candidate = ApplicationCandidate(
            path: "/Applications/Sample App.app",
            name: "Sample App",
            bundleIdentifier: "com.example.sample",
            displayVersion: "3.1.0",
            buildVersion: "3.1.0",
            teamIdentifier: nil,
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [:],
            packageProvenance: provenance
        )
        let catalog = RemoteCatalog(
            schemaVersion: 1,
            catalogID: "test",
            revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            entries: []
        )

        let result = UpdateDetectionEngine().classify([candidate], catalog: catalog).first

        XCTAssertEqual(result?.mechanism, .homebrew)
        XCTAssertEqual(result?.mechanismName, "Homebrew Cask · sample-app")
        XCTAssertEqual(result?.confidence, .verified)
    }

    func testLibraryScopesSeparateRegularAppsFromPackageManagerItems() {
        let normalApplication = installedItem(id: "normal", kind: .application, provenance: nil)
        let steamGame = installedItem(
            id: "steam-game",
            kind: .game,
            provenance: nil,
            gamePlatform: .steam
        )
        let gogLauncher = installedItem(
            id: "gog-launcher",
            kind: .application,
            provenance: nil,
            gamePlatform: .gog
        )
        let caskProvenance = PackageProvenance(
            identifier: "managed-app",
            manager: .homebrewCask,
            managerExecutablePath: "/opt/homebrew/bin/brew",
            installLocation: "/Applications/Managed.app",
            explicitlyInstalled: true,
            homepage: nil,
            summary: nil,
            isOutdated: false
        )
        let formulaProvenance = PackageProvenance(
            identifier: "managed-cli",
            manager: .homebrewFormula,
            managerExecutablePath: "/opt/homebrew/bin/brew",
            installLocation: "/opt/homebrew/Cellar/managed-cli/1.0",
            explicitlyInstalled: true,
            homepage: nil,
            summary: nil,
            isOutdated: false
        )
        let managedApplication = installedItem(
            id: "cask",
            kind: .application,
            provenance: caskProvenance
        )
        let managedTool = installedItem(
            id: "formula",
            kind: .commandLineTool,
            provenance: formulaProvenance
        )

        XCTAssertTrue(InventoryScope.allInOne.includes(normalApplication))
        XCTAssertTrue(InventoryScope.allInOne.includes(managedApplication))
        XCTAssertTrue(InventoryScope.allInOne.includes(managedTool))
        XCTAssertTrue(InventoryScope.allInOne.includes(steamGame))
        XCTAssertTrue(InventoryScope.games.includes(gogLauncher))
        XCTAssertFalse(InventoryScope.applications.includes(gogLauncher))
        XCTAssertFalse(gogLauncher.participatesInPrimaryApplicationViews)

        XCTAssertTrue(InventoryScope.applications.includes(normalApplication))
        XCTAssertFalse(InventoryScope.applications.includes(steamGame))
        XCTAssertFalse(InventoryScope.applications.includes(managedApplication))
        XCTAssertFalse(InventoryScope.applications.includes(managedTool))

        XCTAssertFalse(InventoryScope.packageManagers.includes(normalApplication))
        XCTAssertFalse(InventoryScope.packageManagers.includes(steamGame))
        XCTAssertTrue(InventoryScope.packageManagers.includes(managedApplication))
        XCTAssertTrue(InventoryScope.packageManagers.includes(managedTool))

        XCTAssertFalse(normalApplication.isPackageManagerItem)
        XCTAssertTrue(managedApplication.isPackageManagerItem)
        XCTAssertTrue(managedTool.isPackageManagerItem)

        XCTAssertTrue(PackageManagerKind.homebrewCask.includes(managedApplication))
        XCTAssertFalse(PackageManagerKind.homebrewCask.includes(managedTool))
        XCTAssertTrue(PackageManagerKind.homebrewFormula.includes(managedTool))

        XCTAssertTrue(InventoryScope.games.includes(steamGame))
        XCTAssertFalse(InventoryScope.games.includes(normalApplication))
        XCTAssertTrue(GamePlatformKind.steam.includes(steamGame))
        XCTAssertFalse(steamGame.participatesInPrimaryApplicationViews)
        XCTAssertTrue(normalApplication.participatesInPrimaryApplicationViews)
    }

    func testSteamLibraryParserFindsConfiguredLibraryPaths() {
        let vdf = ##"""
        "libraryfolders"
        {
            "0" { "path" "/Users/example/Library/Application Support/Steam" }
            "1" { "path" "/Volumes/Games/SteamLibrary" }
        }
        """##

        XCTAssertEqual(
            SteamLibraryParser.libraryPaths(in: vdf),
            [
                "/Users/example/Library/Application Support/Steam",
                "/Volumes/Games/SteamLibrary"
            ]
        )
        XCTAssertTrue(SteamLibraryParser.libraryPaths(in: #"\"path\" \"relative/SteamLibrary\""#).isEmpty)
    }

    func testSteamManifestParserUsesManagerRegistryAsInstallationTruth() throws {
        let manifest = ##"""
        "AppState"
        {
            "appid" "1332010"
            "name" "Stray"
            "StateFlags" "4"
            "installdir" "Stray"
            "buildid" "12863654"
            "TargetBuildID" "12863655"
        }
        """##

        let parsed = try XCTUnwrap(SteamLibraryParser.manifest(in: manifest))
        XCTAssertEqual(parsed.appID, "1332010")
        XCTAssertEqual(parsed.name, "Stray")
        XCTAssertEqual(parsed.installDirectory, "Stray")
        XCTAssertEqual(parsed.buildID, "12863654")
        XCTAssertEqual(parsed.targetBuildID, "12863655")
        XCTAssertEqual(parsed.stateFlags, "4")
    }

    func testSteamManifestRejectsInvalidInstallIdentityAndDirectory() throws {
        let template = ##"""
        "AppState"
        {
            "appid" "1332010"
            "name" "Stray"
            "StateFlags" "4"
            "installdir" "Stray"
            "buildid" "12863654"
        }
        """##
        let valid = try XCTUnwrap(SteamLibraryParser.manifest(in: template))
        let library = URL(fileURLWithPath: "/Volumes/Games/steamapps", isDirectory: true)
        XCTAssertEqual(
            SteamLibraryParser.installRoot(
                for: valid,
                manifestURL: library.appendingPathComponent("appmanifest_1332010.acf"),
                steamAppsRoot: library
            )?.path,
            "/Volumes/Games/steamapps/common/Stray"
        )
        XCTAssertNil(SteamLibraryParser.installRoot(
            for: valid,
            manifestURL: library.appendingPathComponent("appmanifest_268910.acf"),
            steamAppsRoot: library
        ))
        XCTAssertNil(SteamLibraryParser.manifest(in: template.replacingOccurrences(
            of: "\"installdir\" \"Stray\"", with: "\"installdir\" \"../Other\""
        )))
        XCTAssertNil(SteamLibraryParser.manifest(in: template.replacingOccurrences(of: "\"4\"", with: "\"0\"")))
        XCTAssertNil(SteamLibraryParser.manifest(in: template.replacingOccurrences(of: "\"1332010\"", with: "\"not-an-id\"")))
    }

    func testSteamScannerCountsOnlyLiveManifestWithGameFiles() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureRoot = projectRoot.appendingPathComponent(".temporary_files/SteamScannerTests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let steamApps = fixtureRoot.appendingPathComponent("steamapps")
        let gameRoot = steamApps.appendingPathComponent("common/Stray")
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        let manifest = steamApps.appendingPathComponent("appmanifest_1332010.acf")
        let document = ##"""
        "AppState"
        {
            "appid" "1332010"
            "name" "Stray"
            "StateFlags" "4"
            "installdir" "Stray"
            "buildid" "12863654"
            "TargetBuildID" "12863655"
        }
        """##
        try Data(document.utf8).write(to: manifest)
        let scanner = ApplicationScanner()
        XCTAssertTrue(scanner.discoverSteamGames(
            steamAppsRoot: steamApps, parentInventoryID: "steam-client", caskApplicationsByPath: [:]
        ).isEmpty)

        try Data("installed".utf8).write(to: gameRoot.appendingPathComponent("game.dat"))
        let games = scanner.discoverSteamGames(
            steamAppsRoot: steamApps, parentInventoryID: "steam-client", caskApplicationsByPath: [:]
        )
        XCTAssertEqual(games.map(\.inventoryID), ["game:steam:1332010"])
        XCTAssertEqual(games.first?.parentInventoryID, "steam-client")
        XCTAssertEqual(games.first?.info["SteamBuildID"], "12863654")
        XCTAssertEqual(games.first?.info["SteamManifestPath"], manifest.path)

        try FileManager.default.moveItem(at: manifest, to: steamApps.appendingPathComponent("appmanifest_268910.acf"))
        XCTAssertTrue(scanner.discoverSteamGames(
            steamAppsRoot: steamApps, parentInventoryID: "steam-client", caskApplicationsByPath: [:]
        ).isEmpty)
    }

    func testGenericGamesFolderIsNotAttributedToGOGGalaxy() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let gog = ApplicationScanner.gameLibraryRoots(home: home, platform: .gog).map(\.path)
        let standalone = ApplicationScanner.gameLibraryRoots(home: home, platform: .standalone).map(\.path)
        XCTAssertTrue(gog.contains("/Users/example/GOG Games"))
        XCTAssertFalse(gog.contains("/Applications/Games"))
        XCTAssertTrue(standalone.contains("/Applications/Games"))
        XCTAssertTrue(standalone.contains("/Users/example/Applications/Games"))
    }

    func testSteamTargetBuildRequiresStrictlyNewerNumericBuild() {
        XCTAssertEqual(SteamLocalUpdateEvidence.newerTarget(installed: "12863654", target: "12863655"), "12863655")
        XCTAssertNil(SteamLocalUpdateEvidence.newerTarget(installed: "12863654", target: "12863654"))
        XCTAssertNil(SteamLocalUpdateEvidence.newerTarget(installed: "12863654", target: "0"))
        XCTAssertNil(SteamLocalUpdateEvidence.newerTarget(installed: "12863654", target: "unknown"))
    }

    func testSteamShortcutParserUsesStableAppIDInsteadOfLocalizedName() {
        XCTAssertEqual(
            SteamShortcutParser.appID(in: "open steam://run/268910"),
            "268910"
        )
        XCTAssertEqual(
            SteamShortcutParser.appID(in: "open STEAM://RUNGAMEID/1332010"),
            "1332010"
        )
    }

    func testSteamShortcutDoesNotCountAsAnInstalledGameWithoutManifest() {
        let installedManifestAppIDs: Set<String> = ["1332010"]

        XCTAssertFalse(
            SteamInventoryReconciler.isInstalled(
                shortcutAppID: "268910",
                manifestAppIDs: installedManifestAppIDs
            )
        )
        XCTAssertTrue(
            SteamInventoryReconciler.isInstalled(
                shortcutAppID: "1332010",
                manifestAppIDs: installedManifestAppIDs
            )
        )
    }

    private func installedItem(
        id: String,
        kind: InventoryItemKind,
        provenance: PackageProvenance?,
        gamePlatform: GamePlatformKind? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: id,
            path: "/tmp/\(id)",
            name: id,
            bundleIdentifier: id,
            displayVersion: "1.0",
            buildVersion: "1.0",
            teamIdentifier: nil,
            status: .supported,
            mechanism: provenance?.manager.mechanism ?? .sparkle,
            mechanismName: provenance?.manager.title ?? "Sparkle",
            confidence: .verified,
            evidence: [],
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            catalogEntryID: nil,
            notes: "",
            kind: kind,
            gamePlatform: gamePlatform,
            packageProvenance: provenance
        )
    }
}
