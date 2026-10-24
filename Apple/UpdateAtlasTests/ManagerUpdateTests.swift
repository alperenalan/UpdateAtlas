import XCTest
@testable import UpdateAtlas

final class ManagerUpdateTests: XCTestCase {
    private func item(manager: PackageManagerKind = .homebrewFormula, token: String = "fixture",
                      executable: String = "/opt/homebrew/bin/brew", availability: UpdateAvailability = .updateAvailable,
                      channel: ReleaseChannel = .init(kind: .stable), bundleID: String = "fixture",
                      path: String = "/opt/homebrew/Cellar/fixture/1.0", microsoft: Bool = false,
                      kind: InventoryItemKind = .commandLineTool, displayVersion: String = "1.0") -> InstalledApplication {
        InstalledApplication(inventoryID: "fixture", path: path, name: "Fixture", bundleIdentifier: bundleID,
            displayVersion: displayVersion, buildVersion: "1", teamIdentifier: microsoft ? "UBF8T346G9" : nil,
            status: microsoft ? .managedExternally : .supported,
            mechanism: microsoft ? .externalManager : manager.mechanism, mechanismName: "Manager", confidence: .verified,
            evidence: [], parentManagerBundleIdentifier: microsoft ? "com.microsoft.autoupdate2" : nil,
            parentManagerName: nil, vendorURL: nil, catalogEntryID: nil, notes: "",
            kind: microsoft ? .application : kind,
            packageProvenance: microsoft ? nil : PackageProvenance(identifier: token, manager: manager,
                managerExecutablePath: executable, installLocation: path, explicitlyInstalled: true,
                homepage: nil, summary: nil, isOutdated: true, installedVersion: "1.0"), releaseChannel: channel,
            updateCheck: UpdateCheckResult(availability: availability, installedVersion: "1.0", latestVersion: "2.0",
                                          checkedAt: nil, source: nil, detail: ""))
    }
    private func formula(version: String = "1.0", outdated: Bool = true, pinned: Bool = false, latest: String = "2.0") -> Data {
        Data("""
        {"formulae":[{"name":"fixture","installed":[{"version":"\(version)","installed_on_request":true}],
        "versions":{"stable":"\(latest)"},"outdated":\(outdated),"pinned":\(pinned)}],"casks":[]}
        """.utf8)
    }
    func testOnlyVerifiedBrewOwnerAndSupportedMicrosoftItemsOfferActions() {
        XCTAssertEqual(ManagerUpdatePolicy.action(for: item(), executableExists: { _ in true }), .homebrewConfirmation)
        XCTAssertNil(ManagerUpdatePolicy.action(for: item(executable: "/some/other/brew"), executableExists: { _ in true }))
        XCTAssertNil(ManagerUpdatePolicy.action(for: item(), executableExists: { _ in false }))
        XCTAssertNil(ManagerUpdatePolicy.action(for: item(availability: .upToDate), executableExists: { _ in true }))
        XCTAssertNil(ManagerUpdatePolicy.action(for: item(channel: .init(kind: .beta)), executableExists: { _ in true }))
        for manager in [PackageManagerKind.pythonPip, .pipx, .uvTool, .npm, .cargo] {
            XCTAssertNil(ManagerUpdatePolicy.action(for: item(manager: manager), executableExists: { _ in true }))
        }
        let word = item(bundleID: "com.microsoft.Word", path: "/Applications/Microsoft Word.app", microsoft: true)
        XCTAssertEqual(ManagerUpdatePolicy.action(for: word, executableExists: { _ in true }), .microsoftAutoUpdateConfirmation)
        XCTAssertNil(ManagerUpdatePolicy.action(for: word, executableExists: { _ in false }))
        for id in ["com.microsoft.teams2", "com.microsoft.edgemac", "com.microsoft.VSCode"] {
            XCTAssertNil(ManagerUpdatePolicy.action(for: item(bundleID: id, microsoft: true), executableExists: { _ in true }))
        }
        XCTAssertNil(ManagerUpdatePolicy.action(for: item(bundleID: "com.microsoft.Word", path: "/Other/Word.app", microsoft: true), executableExists: { _ in true }))
    }
    func testNewStoreReceiptPreventsManagerTakeover() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".temporary_files/manager-receipt-tests/" + UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        defer { try? FileManager.default.removeItem(at: root) }
        let brewItem = item(manager: .homebrewCask, path: app.path, kind: .application)
        XCTAssertEqual(ManagerUpdatePolicy.action(for: brewItem, executableExists: { _ in true }), .homebrewConfirmation)
        let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: receipt)
        XCTAssertTrue(ManagerUpdatePolicy.hasStoreReceipt(at: app.path))
        XCTAssertNil(ManagerUpdatePolicy.action(for: brewItem, executableExists: { _ in true }))
    }

    func testUnsafeOperandsCannotBecomeCommands() {
        for token in ["", "--all", "../fixture", "/tmp/install.rb", "https://example.com/foo", "a;echo", "a b", "a\nb", "a/../b"] {
            XCTAssertFalse(ManagerUpdatePolicy.validToken(token), token)
            XCTAssertNil(ManagerUpdatePolicy.installCommand(for: item(token: token), action: .homebrewConfirmation))
        }
        XCTAssertTrue(ManagerUpdatePolicy.validToken("owner/tap/fixture"))
    }
    func testCommandsTargetOneItemWithoutForcedQuitOrGlobalUpgrade() throws {
        let brew = try XCTUnwrap(ManagerUpdatePolicy.installCommand(for: item(), action: .homebrewConfirmation))
        XCTAssertEqual(brew.arguments, ["upgrade", "--formula", "fixture"])
        XCTAssertEqual(brew.environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"], "1")
        let cask = try XCTUnwrap(ManagerUpdatePolicy.installCommand(for: item(manager: .homebrewCask), action: .homebrewConfirmation))
        XCTAssertEqual(cask.arguments, ["upgrade", "--cask", "--no-quit", "--require-sha", "--greedy-auto-updates", "fixture"])
        let word = try XCTUnwrap(ManagerUpdatePolicy.installCommand(for: item(bundleID: "com.microsoft.Word", microsoft: true), action: .microsoftAutoUpdateConfirmation))
        XCTAssertEqual(word.arguments, ["--install", "--apps", "MSWD2019", "--wait", "600"])
    }
    func testPinnedMalformedAndChangedOwnershipNeverReachInstall() throws {
        for data in [formula(pinned: true), formula(latest: "2.0-beta.1"), formula(version: "0.9"), Data("{}".utf8)] {
            var commands: [ManagerUpdatePolicy.Command] = []
            XCTAssertThrowsError(try ManagerUpdateExecutor.execute(item(), action: .homebrewConfirmation, run: { command, _ in
                commands.append(command); return PackageCommandResult(output: data, terminationStatus: 0)
            }, validate: { true }, installedVersion: { nil }))
            XCTAssertEqual(commands.count, 1)
            XCTAssertEqual(commands.first?.arguments.first, "info")
        }
    }
    func testFreshNoUpdateDoesNotInstall() throws {
        var count = 0
        let outcome = try ManagerUpdateExecutor.execute(item(), action: .homebrewConfirmation, run: { _, _ in
            count += 1; return PackageCommandResult(output: formula(outdated: false), terminationStatus: 0)
        }, validate: { true }, installedVersion: { nil })
        XCTAssertEqual(outcome, .unchanged); XCTAssertEqual(count, 1)
    }
    func testBrewSuccessRequiresNewInstalledVersionAndNoRemainingUpdate() throws {
        for updated in [true, false] {
            var commands: [[String]] = []
            let outcome = try ManagerUpdateExecutor.execute(item(), action: .homebrewConfirmation, run: { command, _ in
                commands.append(command.arguments)
                let data = commands.count == 3 && updated ? formula(version: "2.0", outdated: false) : formula()
                return PackageCommandResult(output: data, terminationStatus: 0)
            }, validate: { true }, installedVersion: { nil })
            XCTAssertEqual(outcome, updated ? .verified : .submitted)
            XCTAssertEqual(commands.map { $0.first! }, ["info", "upgrade", "info"])
        }
    }
    func testReplacedTargetOrFailedCommandDoesNotClaimSuccess() throws {
        var checks = 0; var commands = 0
        XCTAssertThrowsError(try ManagerUpdateExecutor.execute(item(), action: .homebrewConfirmation, run: { _, _ in
            commands += 1; return PackageCommandResult(output: formula(), terminationStatus: 0)
        }, validate: { checks += 1; return checks == 1 }, installedVersion: { nil }))
        XCTAssertEqual(commands, 1)
        XCTAssertThrowsError(try ManagerUpdateExecutor.execute(item(), action: .homebrewConfirmation, run: { command, _ in
            PackageCommandResult(output: formula(), terminationStatus: command.arguments.first == "upgrade" ? 1 : 0)
        }, validate: { true }, installedVersion: { nil }))
    }
    func testCaskChecksumAndVersionBuildPairs() throws {
        let data = Data("""
        {"casks":[{"token":"fixture","installed":"1.0,10","version":"2.0,20","outdated":true,"sha256":"no_check"}]}
        """.utf8)
        let p = try XCTUnwrap(item(manager: .homebrewCask).packageProvenance)
        let record = try ManagerUpdateExecutor.brewRecord(data, provenance: p)
        XCTAssertEqual(record.installedVersion, "1.0,10"); XCTAssertFalse(record.hasChecksum)
        let snapshot = PackageInventoryScanner.parseHomebrew(data: data, executablePath: "/opt/homebrew/bin/brew")
        XCTAssertEqual(snapshot.candidates.first?.packageProvenance?.installedVersion, "1.0,10")
    }
    func testCaskInstallGuardsAndVerifiedResultThroughFakeManager() throws {
        let cask = item(manager: .homebrewCask, path: "/opt/homebrew/Caskroom/fixture/1.0")
        for checksum in ["no_check", String(repeating: "a", count: 64)] {
            var commands: [String] = []
            func run(_ command: ManagerUpdatePolicy.Command, _: TimeInterval) -> PackageCommandResult {
                commands.append(command.arguments.first!)
                let post = commands.count == 3
                let data = Data("""
                {"casks":[{"token":"fixture","installed":"\(post ? "2.0" : "1.0")","version":"2.0", "outdated":\(!post),"sha256":"\(checksum)"}]}
                """.utf8)
                return PackageCommandResult(output: data, terminationStatus: 0)
            }
            if checksum == "no_check" {
                XCTAssertThrowsError(try ManagerUpdateExecutor.execute(cask, action: .homebrewConfirmation,
                    run: run, validate: { true }, installedVersion: { nil }))
                XCTAssertEqual(commands, ["info"])
            } else {
                let outcome = try ManagerUpdateExecutor.execute(cask, action: .homebrewConfirmation,
                    run: run, validate: { true }, installedVersion: { nil })
                XCTAssertEqual(outcome, .verified)
                XCTAssertEqual(commands, ["info", "upgrade", "info"])
            }
        }
    }

    func testCaskReceiptAloneCannotProveGUIAppWasReplaced() throws {
        let app = item(manager: .homebrewCask, path: "/Applications/Fixture.app", kind: .application)
        for replaced in [true, false] {
            var count = 0
            let outcome = try ManagerUpdateExecutor.execute(app, action: .homebrewConfirmation, run: { _, _ in
                count += 1
                let post = count == 3
                let data = Data("""
                {"casks":[{"token":"fixture","installed":"\(post ? "2.0" : "1.0")","version":"2.0", "outdated":\(!post),
                  "sha256":"\(String(repeating: "a", count: 64))","artifacts":[{"app":["Fixture.app"]}]}]}
                """.utf8)
                return PackageCommandResult(output: data, terminationStatus: 0)
            }, validate: { true }, installedVersion: { count == 3 && replaced ? "2.0" : "1.0" }, installedBuild: { "1" })
            XCTAssertEqual(outcome, replaced ? .verified : .submitted)
        }
    }

    func testNormalizedDisplayVersionCannotProveCaskBundleChanged() throws {
        let app = item(manager: .homebrewCask, path: "/Applications/Fixture.app", kind: .application, displayVersion: "1.0.1")
        var count = 0
        let outcome = try ManagerUpdateExecutor.execute(app, action: .homebrewConfirmation, run: { _, _ in
            count += 1
            let post = count == 3
            let data = Data("""
            {"casks":[{"token":"fixture","installed":"\(post ? "2.0" : "1.0")","version":"2.0", "outdated":\(!post),
              "sha256":"\(String(repeating: "a", count: 64))","artifacts":[{"app":["Fixture.app"]}]}]}
            """.utf8)
            return PackageCommandResult(output: data, terminationStatus: 0)
        }, validate: { true }, installedVersion: { "1.0" }, installedBuild: { "1" })
        XCTAssertEqual(outcome, .submitted)
    }

    func testMicrosoftDaemonReturnIsPendingUntilActualVersionChanges() throws {
        let word = item(bundleID: "com.microsoft.Word", microsoft: true)
        for changed in [true, false] {
            var reads = 0
            let outcome = try ManagerUpdateExecutor.execute(word, action: .microsoftAutoUpdateConfirmation, run: { command, _ in
                XCTAssertEqual(command.arguments[2], "MSWD2019")
                return PackageCommandResult(output: Data(), terminationStatus: 0)
            }, validate: { true }, installedVersion: { reads += 1; return reads == 2 && changed ? "2.0" : "1.0" })
            XCTAssertEqual(outcome, changed ? .verified : .submitted)
        }
    }
    func testStoreDestinationRejectsNonProductAndUntrustedURLs() {
        XCTAssertNotNil(AppStoreDestination.validatedPage(URL(string: "https://apps.apple.com/tr/app/fixture/id1234?mt=12")))
        for value in ["https://apps.apple.com/tr/search", "http://apps.apple.com/app/id123", "https://apps.apple.com.evil/app/id123", "https://user:pass@apps.apple.com/app/id123", "file:///app/id123"] {
            XCTAssertNil(AppStoreDestination.validatedPage(URL(string: value)))
        }
    }
}
