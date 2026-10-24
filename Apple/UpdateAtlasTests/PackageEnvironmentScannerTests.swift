import Foundation
import Testing
@testable import UpdateAtlas

@Suite("Manager-owned tool inventories")
struct PackageEnvironmentScannerTests {
    @Test("pipx requires a live environment, not only a saved record")
    func pipxRequiresLiveEnvironment() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = root.appendingPathComponent("venvs/ruff", isDirectory: true)
        let json = #"{"pipx_spec_version":"0.1","venvs":{"ruff":{"metadata":{"main_package":{"package":"ruff","package_version":"0.13.0"}}}}}"#

        #expect(PackageInventoryScanner.parsePipx(
            data: Data(json.utf8), executablePath: "/opt/homebrew/bin/pipx", homePath: root.path
        ).isEmpty)

        try makeExecutable(environment.appendingPathComponent("bin/python"))
        let item = try #require(PackageInventoryScanner.parsePipx(
            data: Data(json.utf8), executablePath: "/opt/homebrew/bin/pipx", homePath: root.path
        ).first)
        #expect(item.displayVersion == "0.13.0")
        #expect(item.packageProvenance?.manager == .pipx)
        #expect(item.packageProvenance?.isOutdated == nil)
    }

    @Test("uv lists only persistent tools with live environments")
    func uvRequiresLiveTool() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root.appendingPathComponent("ruff/bin/python"))
        let listing = "ruff v0.13.0\n- ruff\nstale v1.0.0\n- stale\n"

        let items = PackageInventoryScanner.parseUVTools(
            data: Data(listing.utf8), executablePath: "/opt/homebrew/bin/uv", toolDirectory: root.path
        )
        #expect(items.map(\.name) == ["ruff"])
        #expect(items.first?.packageProvenance?.manager == .uvTool)
        #expect(items.first?.packageProvenance?.isOutdated == nil)
    }

    @Test("Cargo requires a live binary from an installed crate")
    func cargoRequiresBinary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(root.appendingPathComponent("bin/starship"))
        let listing = "starship v1.26.0:\n    starship\nstale v2.0.0:\n    stale\n"

        let items = PackageInventoryScanner.parseCargo(
            data: Data(listing.utf8), executablePath: "/Users/test/.cargo/bin/cargo", installRoot: root.path
        )
        #expect(items.map(\.name) == ["starship"])
        #expect(items.first?.packageProvenance?.isOutdated == nil)
    }

    @Test("Same package in two npm or Python environments retains two identities")
    func environmentsRemainDistinct() {
        let npm = Data(#"{"dependencies":{"tool":{"version":"1.0.0"}}}"#.utf8)
        let firstNPM = PackageInventoryScanner.parseNPM(
            data: npm, executablePath: "/a/bin/npm", globalRoot: "/a/lib/node_modules"
        )
        let secondNPM = PackageInventoryScanner.parseNPM(
            data: npm, executablePath: "/b/bin/npm", globalRoot: "/b/lib/node_modules"
        )
        #expect(firstNPM.first?.inventoryID != secondNPM.first?.inventoryID)

        let pip = Data(#"[{"name":"tool","version":"1.0.0"}]"#.utf8)
        let firstPython = PackageInventoryScanner.parsePythonPip(data: pip, executablePath: "/a/bin/python3")
        let secondPython = PackageInventoryScanner.parsePythonPip(data: pip, executablePath: "/b/bin/python3")
        #expect(firstPython.first?.inventoryID != secondPython.first?.inventoryID)
    }

    @Test("An installed manager-owned tool without latest-version evidence is not current")
    func unknownLatestIsSourcePending() async throws {
        let provenance = PackageProvenance(
            identifier: "example", manager: .cargo,
            managerExecutablePath: "/Users/test/.cargo/bin/cargo",
            installLocation: "/Users/test/.cargo/bin/example",
            explicitlyInstalled: true, homepage: nil, summary: nil, isOutdated: nil
        )
        let candidate = ApplicationCandidate(
            path: "/Users/test/.cargo/bin/example", name: "example",
            bundleIdentifier: "example", displayVersion: "1.0.0", buildVersion: "1.0.0",
            teamIdentifier: nil, parentManagerBundleIdentifier: nil, isSystemApplication: false,
            info: [:], kind: .commandLineTool, packageProvenance: provenance
        )
        let catalog = RemoteCatalog(
            schemaVersion: 1, catalogID: "test", revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil, entries: []
        )
        let detected = try #require(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        let checked = try #require(await UpdateCheckService().check([detected]).first)
        #expect(checked.updateCheck.availability == .sourcePending)
        #expect(checked.updateCheck.latestVersion == nil)
    }

    private func temporaryRoot() throws -> URL {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = projectRoot.appendingPathComponent(".temporary_files/package-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
