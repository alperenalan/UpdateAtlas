import Foundation
import Testing
@testable import UpdateAtlas

struct DockerDiscoveryTests {
    private let imageID = "sha256:" + String(repeating: "a", count: 64)
    private let containerID = String(repeating: "b", count: 64)

    @Test func optOutNeverLaunchesTheDockerCLI() {
        let provider = DockerDiscoveryProvider(executable: "/fixture/docker", environment: [:], run: { _, _, _ in
            Issue.record("Docker CLI must not run when discovery is disabled")
            return .init(output: Data(), terminationStatus: 1)
        })
        #expect(provider.scan(enabled: false, parent: nil, control: ScanControl()).candidates.isEmpty)
    }

    @Test func missingDaemonAndPermissionFailureAreExplicitDiagnostics() {
        let provider = DockerDiscoveryProvider(executable: "/fixture/docker", environment: [:], run: { _, args, _ in
            if args == ["context", "show"] { return .init(output: Data("desktop-linux\n".utf8), terminationStatus: 0) }
            return .init(output: Data(), terminationStatus: 1)
        })
        let result = provider.scan(enabled: true, parent: nil, control: ScanControl())
        #expect(result.candidates.isEmpty)
        #expect(result.diagnostics == [.init(source: "Docker", reason: .commandFailed)])
        let missing = DockerDiscoveryProvider(executable: nil)
        #expect(missing.scan(enabled: true, parent: nil, control: ScanControl()).diagnostics.first?.reason == .unavailable)
    }

    @Test func runningAndStoppedContainersShareOneImmutableImageAndComposeOwner() throws {
        let images = try jsonLines([["id": imageID, "os": "linux", "architecture": "arm64", "digests": ["private.example/team/app@" + imageID]]])
        let containers = try jsonLines([
            ["id": containerID, "image": imageID, "name": "/web-1", "state": "running", "project": "demo", "service": "web"],
            ["id": String(repeating: "c", count: 64), "image": imageID, "name": "/worker-1", "state": "exited", "project": "demo", "service": "worker"]
        ])
        let items = try DockerDiscoveryProvider.parse(images: images, containers: containers, volumes: Data("\"demo-data\"\n".utf8), contextID: "context")
        #expect(items.count == 5)
        #expect(items.filter { $0.kind == .containerImage }.count == 1)
        #expect(items.filter { $0.kind == .composeProject }.count == 1)
        #expect(items.filter { $0.kind == .container }.allSatisfy { $0.parentInventoryID == "context:compose:demo" })
        #expect(items.first { $0.name == "worker-1" }?.info["DiscoveryState"] == "exited")
        #expect(items.first { $0.kind == .containerImage }?.info["DiscoveryPlatform"] == "linux/arm64")
        #expect(items.first { $0.kind == .containerImage }?.displayVersion != "latest")
        let classified = UpdateDetectionEngine().classify(items, catalog: emptyCatalog())
        #expect(classified.allSatisfy { $0.updateCheck.availability == .managedExternally && !$0.participatesInPrimaryApplicationViews })
        #expect(classified.allSatisfy(InventoryScope.containers.includes))
        #expect(classified.allSatisfy { $0.inventoryReleaseChannel == "notApplicable" })
        #expect(classified.allSatisfy { $0.discovery?.source == "Docker" })
        #expect(classified.allSatisfy { ManagerUpdatePolicy.action(for: $0) == nil })
    }

    @Test func removedImageRemainsAReferenceWithoutInventingAnInstalledImage() throws {
        let containers = try jsonLines([["id": containerID, "image": imageID, "name": "/old", "state": "exited"]])
        let items = try DockerDiscoveryProvider.parse(images: Data(), containers: containers, volumes: Data(), contextID: "context")
        #expect(items.count == 1)
        #expect(items.first?.kind == .container)
        #expect(items.first?.info["DockerImageID"] == imageID)
    }

    @Test func contextIdentityAndExplicitBindingPreventCrossContextDuplicates() {
        let run: @Sendable (String, [String], ScanControl) throws -> PackageCommandResult = { _, args, _ in
            if args == ["context", "show"] { return .init(output: Data("alternate\n".utf8), terminationStatus: 0) }
            #expect(args.prefix(2) == ["--context", "alternate"])
            #expect(!args.contains("pull") && !args.contains("start") && !args.contains("exec"))
            return .init(output: Data(), terminationStatus: 0)
        }
        let provider = DockerDiscoveryProvider(executable: "/fixture/docker", environment: [:], run: run)
        let plain = provider.scan(enabled: true, parent: nil, control: ScanControl())
        #expect(plain.candidates.count == 1)
        #expect(plain.candidates.first?.name == "Docker · alternate")
        let custom = DockerDiscoveryProvider(executable: "/fixture/docker", environment: ["DOCKER_HOST": "unix:///private/fixture.sock"],
            run: { _, args, _ in .init(output: args == ["context", "show"] ? Data("alternate\n".utf8) : Data(), terminationStatus: 0) })
        let host = custom.scan(enabled: true, parent: nil, control: ScanControl())
        #expect(host.candidates.first?.inventoryID != plain.candidates.first?.inventoryID)
        #expect(host.candidates.first?.name == String(localized: "Docker · Custom connection"))
        #expect(!host.candidates.first!.inventoryID.contains("private"))
    }

    @Test func multiArchitectureImagesHaveDistinctPlatformIdentities() throws {
        let images = try jsonLines([
            ["id": imageID, "os": "linux", "architecture": "arm64"],
            ["id": "sha256:" + String(repeating: "d", count: 64), "os": "linux", "architecture": "amd64"]
        ])
        let items = try DockerDiscoveryProvider.parse(images: images, containers: Data(), volumes: Data(), contextID: "context")
        #expect(items.count == 2)
        #expect(Set(items.map(\.inventoryID)).count == 2)
        #expect(Set(items.compactMap { $0.info["DiscoveryPlatform"] }) == ["linux/arm64", "linux/amd64"])
    }

    @Test func malformedAndDuplicateObjectsFailInsteadOfProducingEmptySuccess() throws {
        #expect(throws: (any Error).self) {
            try DockerDiscoveryProvider.parse(images: Data("not-json".utf8), containers: Data(), volumes: Data(), contextID: "context")
        }
        let images = try jsonLines([["id": imageID, "os": "linux", "architecture": "arm64"], ["id": imageID, "os": "linux", "architecture": "arm64"]])
        #expect(throws: (any Error).self) {
            try DockerDiscoveryProvider.parse(images: images, containers: Data(), volumes: Data(), contextID: "context")
        }
    }

    @Test @MainActor func expandingDockerTreeNeverInflatesApplicationCounts() throws {
        let owner = ApplicationCandidate(inventoryID: "docker-app", path: "/Applications/Docker.app", name: "Docker",
            bundleIdentifier: "com.docker.docker", displayVersion: "1", buildVersion: "1", teamIdentifier: nil,
            parentManagerBundleIdentifier: nil, isSystemApplication: false, info: [:])
        let context = ApplicationCandidate(inventoryID: "context", path: "", name: "Docker context",
            bundleIdentifier: "docker-context", displayVersion: "Unknown", buildVersion: "", teamIdentifier: nil,
            parentInventoryID: owner.inventoryID, parentManagerBundleIdentifier: owner.bundleIdentifier,
            isSystemApplication: false, info: ["DiscoverySource": "Docker"], kind: .containerContext)
        let image = try DockerDiscoveryProvider.parse(images: jsonLines([["id": imageID, "os": "linux", "architecture": "arm64"]]),
            containers: Data(), volumes: Data(), contextID: context.inventoryID)
        let inventory = UpdateDetectionEngine().classify([owner, context] + image, catalog: emptyCatalog())
        let model = AppInventoryViewModel(initialApplications: inventory)
        model.selectedFilterID = InventoryScope.allInOne.id
        #expect(model.scopeFilters.first { $0.id == InventoryScope.applications.id }?.count == 1)
        #expect(model.scopeFilters.first { $0.id == InventoryScope.containers.id }?.count == 2)
        #expect(model.scopeFilters.first { $0.id == InventoryScope.applications.id }?.count == 1)
        model.toggleExpanded(inventory[0])
        model.toggleExpanded(inventory[1])
        #expect(model.scopeFilters.first { $0.id == InventoryScope.applications.id }?.count == 1)
        model.selectedFilterID = InventoryScope.containers.id
        #expect(model.visibleApplications.map(\.id).contains(owner.inventoryID))
        #expect(model.scopeFilters.first { $0.id == InventoryScope.containers.id }?.count == 2)
    }

    @Test func projectionNeverRequestsSensitiveFieldsAndFactsStayPathFree() throws {
        #expect(!DockerDiscoveryProvider.imageFormat.contains("History"))
        #expect(!DockerDiscoveryProvider.containerFormat.contains("Env"))
        #expect(!DockerDiscoveryProvider.containerFormat.contains("Mounts"))
        #expect(!DockerDiscoveryProvider.containerFormat.contains("{{json .Config.Labels}}"))
        let facts = try #require(DiscoveryFacts(["DiscoverySource": "Docker", "DiscoveryState": "running", "DockerImageID": imageID,
            "Mounts": "/Users/private", "Env": "SECRET=value", "LaunchArguments": "--password test"]))
        let encoded = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        #expect(!encoded.contains("Users") && !encoded.contains("SECRET") && !encoded.contains("password"))
    }

    private func jsonLines(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { output, row in
            output.append(try JSONSerialization.data(withJSONObject: row)); output.append(10)
        }
    }
    private func emptyCatalog() -> RemoteCatalog {
        RemoteCatalog(schemaVersion: 1, catalogID: "test", revision: 0, generatedAt: Date(), expiresAt: nil, entries: [])
    }
}
