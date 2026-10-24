import Foundation
import Testing
@testable import UpdateAtlas

struct PrismInventoryTests {
    @Test func readsPrismVersionsAndManagedContentWithoutGuessingFromFilenames() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = root.appendingPathComponent("instances/Example", isDirectory: true)
        try write("name=My World\niconKey=creeper\n", to: instance.appendingPathComponent("instance.cfg"))
        try write(#"{"components":[{"uid":"net.minecraft","version":"26.3"},{"uid":"net.fabricmc.fabric-loader","version":"0.19.5","cachedName":"Fabric Loader"}]}"#,
                  to: instance.appendingPathComponent("mmc-pack.json"))
        let game = instance.appendingPathComponent("minecraft", isDirectory: true)
        try write("icon", to: game.appendingPathComponent("icon.png"))
        try write("jar", to: game.appendingPathComponent("mods/iris-fabric-1.11.7+mc26.3.jar"))
        try write("filename = 'iris-fabric-1.11.7+mc26.3.jar'\nname = 'Iris'\nx-prismlauncher-version-number = '1.11.7+26.3-fabric'\n[update.modrinth]\nmod-id = 'YL57xq9U'\n",
                  to: game.appendingPathComponent("mods/.index/iris.pw.toml"))
        try write("zip", to: game.appendingPathComponent("shaderpacks/Complementary_r5.9.3.zip"))
        try write("filename = 'Complementary_r5.9.3.zip'\nname = 'Complementary Shaders'\nx-prismlauncher-version-number = 'r5.9.3'\n",
                  to: game.appendingPathComponent("shaderpacks/complementary.pw.toml"))
        try write("zip", to: game.appendingPathComponent("resourcepacks/Custom_1.20.zip"))

        let items = ApplicationScanner.prismLauncherInstances(
            at: root.appendingPathComponent("instances"), parentInventoryID: "prism-app"
        )
        #expect(items.count == 5)
        let minecraft = try #require(items.first { $0.kind == .game })
        #expect(minecraft.displayVersion == "26.3")
        #expect(minecraft.info["IconPath"] == game.appendingPathComponent("icon.png").path)
        let loader = try #require(items.first { $0.kind == .modLoader })
        #expect(loader.name == "Fabric Loader")
        let mod = try #require(items.first { $0.kind == .mod })
        #expect(mod.name == "Iris")
        #expect(mod.displayVersion == "1.11.7+26.3-fabric")
        #expect(mod.info["ModrinthProjectID"] == "YL57xq9U")
        #expect(mod.parentInventoryID == minecraft.inventoryID)
        let shader = try #require(items.first { $0.kind == .shaderPack })
        #expect(shader.name == "Complementary Shaders")
        #expect(shader.displayVersion == "r5.9.3")
        let resource = try #require(items.first { $0.kind == .resourcePack })
        #expect(resource.displayVersion == "Unknown")
        #expect(resource.parentInventoryID == minecraft.inventoryID)
    }

    @Test func missingMinecraftVersionNeverGetsAFalseUpdateComparison() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = root.appendingPathComponent("instances/Incomplete", isDirectory: true)
        try write("name=Incomplete\n", to: instance.appendingPathComponent("instance.cfg"))
        try write(#"{"components":[{"uid":"net.fabricmc.fabric-loader","version":"0.19.5"}]}"#,
                  to: instance.appendingPathComponent("mmc-pack.json"))
        let candidates = ApplicationScanner.prismLauncherInstances(
            at: root.appendingPathComponent("instances"), parentInventoryID: "prism-app"
        )
        let game = try #require(candidates.first { $0.kind == .game })
        let catalog = RemoteCatalog(
            schemaVersion: 1, catalogID: "test", revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil, entries: []
        )
        let classified = try #require(UpdateDetectionEngine().classify([game], catalog: catalog).first)
        #expect(game.displayVersion == "Unknown")
        #expect(classified.status == .managedExternally)
        #expect(classified.versionProvider == nil)
    }

    @Test func respectsPrismConfiguredInstanceAndIconFolders() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("InstanceDir=custom/instances\nIconsDir=custom/icons\n",
                  to: root.appendingPathComponent("prismlauncher.cfg"))
        let instance = root.appendingPathComponent("custom/instances/Custom", isDirectory: true)
        try write("name=Custom\niconKey=custom\n", to: instance.appendingPathComponent("instance.cfg"))
        try write(#"{"components":[{"uid":"net.minecraft","version":"1.21.11"}]}"#,
                  to: instance.appendingPathComponent("mmc-pack.json"))
        let icon = root.appendingPathComponent("custom/icons/custom.png")
        try write("icon", to: icon)

        let items = ApplicationScanner.prismLauncherInstances(launcherRoot: root, parentInventoryID: "prism-app")
        #expect(items.count == 1)
        #expect(items.first?.displayVersion == "1.21.11")
        #expect(items.first?.info["IconPath"] == icon.path)
    }

    @Test func snapshotInstanceChecksSnapshotChannelNotStableRelease() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = root.appendingPathComponent("instances/Snapshot", isDirectory: true)
        try write(#"{"components":[{"uid":"net.minecraft","version":"26w40a"}]}"#,
                  to: instance.appendingPathComponent("mmc-pack.json"))
        let game = try #require(ApplicationScanner.prismLauncherInstances(
            at: root.appendingPathComponent("instances"), parentInventoryID: "prism-app"
        ).first)
        let catalog = RemoteCatalog(
            schemaVersion: 1, catalogID: "test", revision: 0,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil, entries: []
        )
        let classified = try #require(UpdateDetectionEngine().classify([game], catalog: catalog).first)
        #expect(game.info["UpdateChannel"] == "nightly")
        #expect(classified.releaseChannel == .nightly)
        #expect(classified.versionProvider?.channel == "snapshot")
    }

    private func fixtureRoot() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".temporary_files/prism-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
