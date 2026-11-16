import Foundation
import Testing
@testable import UpdateAtlas

struct DirectInstallScannerTests {
    @Test func findsReviewedBinaryWithoutRunningIt() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".local/bin/agy")

        let snapshot = fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        )

        let candidate = try #require(snapshot.candidates.first)
        #expect(snapshot.candidates.count == 1)
        #expect(candidate.name == "Antigravity CLI")
        #expect(candidate.bundleIdentifier == "direct-cli:antigravity-cli")
        #expect(candidate.displayVersion == String(localized: "Unknown"))
        #expect(candidate.kind == .commandLineTool)
    }

    @Test func brokenLauncherIsNotInstalled() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeLink(".local/bin/cua-driver", to: "missing-driver")

        let snapshot = fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        )

        #expect(snapshot.candidates.isEmpty)
        #expect(snapshot.remnants.map(\.name) == ["Cua Driver"])
    }

    @Test func claudeNativeLauncherReadsVersionFromTargetPath() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".local/share/claude/versions/2.1.211")
        try fixture.makeLink(".local/bin/claude", to: "../share/claude/versions/2.1.211")

        let snapshot = fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        )

        #expect(snapshot.candidates.first?.displayVersion == "2.1.211")
    }

    @Test func ollamaAppLinkIsDiscoveredAsItsCLIChild() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        let app = fixture.home.appendingPathComponent("Applications/Ollama.app")
        try fixture.makeExecutable("Applications/Ollama.app/Contents/Resources/ollama")
        let plist: [String: String] = [
            "CFBundleIdentifier": "com.electron.ollama",
            "CFBundleShortVersionString": "0.40.11"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try fixture.makeLink("fake-system-bin/ollama", to: "../Applications/Ollama.app/Contents/Resources/ollama")
        let parent = ApplicationCandidate(path: app.path, name: "Ollama",
            bundleIdentifier: "com.electron.ollama", displayVersion: "0.40.11", buildVersion: "",
            teamIdentifier: nil, parentManagerBundleIdentifier: nil, isSystemApplication: false, info: [:])

        let candidate = try #require(fixture.scanner.scan(packageCandidates: [],
            applicationCandidates: [parent]).candidates.first)
        #expect(candidate.bundleIdentifier == "direct-cli:ollama-cli")
        #expect(candidate.displayVersion == "0.40.11")
        #expect(candidate.parentInventoryID == parent.inventoryID)
        #expect(candidate.parentManagerBundleIdentifier == "com.electron.ollama")
        #expect(candidate.info["DirectInstallVersionProven"] == "true")
        let catalog = RemoteCatalog(schemaVersion: 1, catalogID: "test", revision: 1,
            generatedAt: Date(), expiresAt: nil, entries: [])
        let classified = try #require(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        #expect(classified.mechanism == .externalManager)
        #expect(classified.parentManagerName == "Ollama")
    }

    @Test func exactOllamaAppLinkRetainsItsChildThroughCaskroom() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        let realApp = fixture.home.appendingPathComponent("Caskroom/ollama/0.40.11/Ollama.app")
        try fixture.makeExecutable("Caskroom/ollama/0.40.11/Ollama.app/Contents/Resources/ollama")
        let plist = ["CFBundleIdentifier": "com.electron.ollama", "CFBundleShortVersionString": "0.40.11"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: realApp.appendingPathComponent("Contents/Info.plist"))
        try fixture.makeLink("Applications/Ollama.app", to: "../Caskroom/ollama/0.40.11/Ollama.app")
        try fixture.makeLink("fake-system-bin/ollama", to: "../Applications/Ollama.app/Contents/Resources/ollama")
        let parent = ApplicationCandidate(
            path: fixture.home.appendingPathComponent("Applications/Ollama.app").path, name: "Ollama",
            bundleIdentifier: "com.electron.ollama", displayVersion: "0.40.11", buildVersion: "",
            teamIdentifier: nil, parentManagerBundleIdentifier: nil, isSystemApplication: false, info: [:])
        let candidate = try #require(fixture.scanner.scan(packageCandidates: [],
            applicationCandidates: [parent]).candidates.first)
        #expect(candidate.parentInventoryID == parent.inventoryID)
        #expect(candidate.displayVersion == "0.40.11")
        #expect(candidate.info["DirectInstallVersionProven"] == "true")
        let catalog = RemoteCatalog(schemaVersion: 1, catalogID: "fixture", revision: 1,
            generatedAt: Date(), expiresAt: nil, entries: [])
        let classified = try #require(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        #expect(classified.mechanism == .externalManager)
        #expect(classified.parentManagerName == "Ollama")
    }

    @Test func standaloneOllamaDoesNotBorrowAnUnrelatedAppVersionOrParent() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".local/bin/ollama")
        let app = fixture.home.appendingPathComponent("Applications/Ollama.app")
        let parent = ApplicationCandidate(path: app.path, name: "Ollama",
            bundleIdentifier: "com.electron.ollama", displayVersion: "0.40.11", buildVersion: "",
            teamIdentifier: nil, parentManagerBundleIdentifier: nil, isSystemApplication: false, info: [:])
        let candidate = try #require(fixture.scanner.scan(packageCandidates: [],
            applicationCandidates: [parent]).candidates.first)
        #expect(candidate.parentInventoryID == nil)
        #expect(candidate.parentManagerBundleIdentifier == nil)
        #expect(candidate.displayVersion == String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale))
        #expect(candidate.info["DirectInstallVersionProven"] == nil)
    }

    @Test func packagedOllamaAliasIsNotClaimedAsDirect() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable("Cellar/ollama/0.40.11/bin/ollama")
        try fixture.makeLink("fake-system-bin/ollama", to: "../Cellar/ollama/0.40.11/bin/ollama")
        #expect(fixture.scanner.scan(packageCandidates: [], applicationCandidates: []).candidates.isEmpty)
    }

    @Test func packageManagedLinkIsNotMislabelledAsDirect() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable("manager/node_modules/claude/bin/claude")
        try fixture.makeLink(".local/bin/claude", to: "../../manager/node_modules/claude/bin/claude")

        let snapshot = fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        )

        #expect(snapshot.candidates.isEmpty)
        #expect(snapshot.remnants.isEmpty)
    }

    @Test func appAndCLIAliasDoNotCreateTwoCuaProducts() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".local/bin/cua-driver")
        let app = ApplicationCandidate(
            path: "/Applications/CuaDriver.app",
            name: "CuaDriver",
            bundleIdentifier: "com.trycua.driver",
            displayVersion: "0.30.0",
            buildVersion: "0.30.0",
            teamIdentifier: nil,
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [:]
        )

        let snapshot = fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: [app]
        )

        #expect(snapshot.candidates.isEmpty)
    }

    @Test func nonExecutableFileIsNotAnInstallation() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeFile(".local/bin/mise")

        let snapshot = fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        )

        #expect(snapshot.candidates.isEmpty)
    }

    @Test func directCLIToolHasKnownOwnerButNoInventedUpdateVersion() async throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".local/bin/agy")
        let candidate = try #require(fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        ).candidates.first)
        let catalog = RemoteCatalog(
            schemaVersion: 1,
            catalogID: "test",
            revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            entries: []
        )

        let classified = try #require(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        let checked = try #require(await UpdateCheckService().check([classified]).first)

        #expect(classified.mechanism == .publisherCLIInstaller)
        #expect(classified.status == .needsCatalog)
        #expect(checked.updateCheck.availability == .sourcePending)
        #expect(checked.updateCheck.latestVersion == nil)
        #expect(InventoryScope.commandLineTools.includes(checked))
        #expect(InventoryScope.packageManagers.includes(checked) == false)
    }

    @Test func starshipCustomHomeInstallationIsSourcePending() async throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".local/bin/starship")

        let candidate = try #require(fixture.scanner.scan(
            packageCandidates: [], applicationCandidates: []
        ).candidates.first)
        let catalog = RemoteCatalog(
            schemaVersion: 1,
            catalogID: "test",
            revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            entries: []
        )
        let classified = try #require(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        let checked = try #require(await UpdateCheckService().check([classified]).first)

        #expect(candidate.name == "Starship")
        #expect(candidate.bundleIdentifier == "direct-cli:starship")
        #expect(candidate.displayVersion == String(localized: "Unknown"))
        #expect(classified.mechanism == .publisherCLIInstaller)
        #expect(checked.updateCheck.availability == .sourcePending)
        #expect(checked.updateCheck.latestVersion == nil)
    }

    @Test func starshipDefaultInstallerPathIsDiscovered() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable("fake-system-bin/starship")

        let snapshot = fixture.scanner.scan(packageCandidates: [], applicationCandidates: [])

        #expect(snapshot.candidates.map(\.name) == ["Starship"])
        #expect(snapshot.candidates.first?.path == fixture.systemBin.appendingPathComponent("starship").path)
    }

    @Test func starshipHomebrewLinkIsNotClaimedAsDirectInstallation() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable("manager/Cellar/starship/1.26.0/bin/starship")
        try fixture.makeLink("fake-system-bin/starship", to: "../manager/Cellar/starship/1.26.0/bin/starship")

        let snapshot = fixture.scanner.scan(packageCandidates: [], applicationCandidates: [])

        #expect(snapshot.candidates.isEmpty)
        #expect(snapshot.remnants.isEmpty)
    }

    @Test func starshipAliasesToSameBinaryAppearOnce() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable("fake-system-bin/starship")
        try fixture.makeLink(".local/bin/starship", to: "../../fake-system-bin/starship")

        let snapshot = fixture.scanner.scan(packageCandidates: [], applicationCandidates: [])

        #expect(snapshot.candidates.count == 1)
        #expect(snapshot.candidates.first?.name == "Starship")
    }

    @Test func starshipCargoLinkIsNotClaimedAsDirectInstallation() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".cargo/bin/starship")
        try fixture.makeLink(".local/bin/starship", to: "../../.cargo/bin/starship")

        let snapshot = fixture.scanner.scan(packageCandidates: [], applicationCandidates: [])

        #expect(snapshot.candidates.isEmpty)
    }

    @Test func rustupIsStillDiscoveredInCargoBin() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeExecutable(".cargo/bin/rustup")

        let snapshot = fixture.scanner.scan(packageCandidates: [], applicationCandidates: [])

        #expect(snapshot.candidates.map(\.name) == ["rustup"])
    }

    @Test func brokenStarshipLauncherIsOnlyARemnant() throws {
        let fixture = try DirectInstallFixture()
        defer { fixture.remove() }
        try fixture.makeLink("fake-system-bin/starship", to: "missing-starship")

        let snapshot = fixture.scanner.scan(packageCandidates: [], applicationCandidates: [])

        #expect(snapshot.candidates.isEmpty)
        #expect(snapshot.remnants.map(\.name) == ["Starship"])
    }
}

private struct DirectInstallFixture {
    let home: URL
    var systemBin: URL { home.appendingPathComponent("fake-system-bin", isDirectory: true) }
    var scanner: DirectInstallScanner {
        DirectInstallScanner(homeDirectory: home, systemBinaryDirectory: systemBin)
    }

    init() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        home = project.appendingPathComponent(".temporary_files/DirectInstallScannerTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func makeFile(_ relativePath: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
    }

    func makeExecutable(_ relativePath: String) throws {
        try makeFile(relativePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent(relativePath).path)
    }

    func makeLink(_ relativePath: String, to destination: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}
