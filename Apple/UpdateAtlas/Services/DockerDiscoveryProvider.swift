import CryptoKit
import Foundation

struct DockerDiscoveryResult: Sendable {
    var candidates: [ApplicationCandidate] = []
    var diagnostics: [ScanDiagnostic] = []
}

/// Opt-in, current connection only. Projected inspect templates avoid collecting
/// environment, mount paths, credentials, arbitrary labels or image history.
struct DockerDiscoveryProvider: Sendable {
    var executable: String? = Self.findExecutable()
    var environment = ProcessInfo.processInfo.environment
    var run: @Sendable (String, [String], ScanControl) throws -> PackageCommandResult = {
        try PackageCommandRunner.run(executable: $0, arguments: $1, timeout: 10,
                                     control: $2, maximumOutputBytes: 4 * 1024 * 1024)
    }
    static let imageFormat = #"{"id":{{json .Id}},"os":{{json .Os}},"architecture":{{json .Architecture}},"digests":{{json .RepoDigests}}}"#
    static let containerFormat = #"{"id":{{json .Id}},"image":{{json .Image}},"name":{{json .Name}},"state":{{json .State.Status}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}}}"#

    func scan(enabled: Bool, parent: ApplicationCandidate?, control: ScanControl) -> DockerDiscoveryResult {
        guard enabled else { return DockerDiscoveryResult() }
        guard let executable else { return .init(diagnostics: [.init(source: "Docker", reason: .unavailable)]) }
        do {
            let contextData = try command(executable, ["context", "show"], control)
            guard let context = String(data: contextData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !context.isEmpty, context.count < 256, !context.contains("\n") else {
                throw PackageCommandError.failed(.invalidOutput)
            }
            // The CLI's DOCKER_HOST override can point outside the named context.
            // Keep that endpoint out of display/JSON, but distinct in internal IDs.
            let hostOverride = environment["DOCKER_CONTEXT"] == nil ? environment["DOCKER_HOST"] : nil
            let connection = context + "|" + (hostOverride ?? "")
            let prefix = hostOverride == nil ? ["--context", context] : []
            let contextID = "docker-context:" + Self.hash(connection)
            let imageIDs = try Self.identifiers(try command(executable, prefix + ["image", "ls", "--no-trunc", "--quiet"], control))
            let containerIDs = try Self.identifiers(try command(executable, prefix + ["container", "ls", "--all", "--no-trunc", "--quiet"], control))
            let volumes = try command(executable, prefix + ["volume", "ls", "--format", "{{json .Name}}"], control)
            let imageData = imageIDs.isEmpty ? Data() : try command(executable,
                prefix + ["image", "inspect", "--format", Self.imageFormat] + imageIDs, control)
            let containerData = containerIDs.isEmpty ? Data() : try command(executable,
                prefix + ["container", "inspect", "--format", Self.containerFormat] + containerIDs, control)
            let contextCandidate = Self.item(id: contextID, name: hostOverride == nil ? "Docker · " + context : String(localized: "Docker · Custom connection", bundle: AppL10n.bundle, locale: AppL10n.locale),
                role: "context", version: "Unknown", parentID: parent?.inventoryID,
                manager: parent?.bundleIdentifier ?? "com.docker.docker")
            var items = [contextCandidate]
            items += try Self.parse(images: imageData, containers: containerData, volumes: volumes,
                                    contextID: contextID, manager: contextCandidate.parentManagerBundleIdentifier ?? "com.docker.docker")
            // Snapshot races (a container/image removed between ls and inspect)
            // fail explicitly rather than silently returning an empty daemon.
            return .init(candidates: items)
        } catch { return .init(diagnostics: [LocalDiscoveryProvider.diagnostic(error, source: "Docker")]) }
    }

    private func command(_ executable: String, _ arguments: [String], _ control: ScanControl) throws -> Data {
        let response = try run(executable, arguments, control)
        guard response.terminationStatus == 0 else { throw PackageCommandError.failed(.commandFailed) }
        return response.output
    }

    static func parse(images: Data, containers: Data, volumes: Data, contextID: String,
                      manager: String = "com.docker.docker") throws -> [ApplicationCandidate] {
        struct Image: Decodable { let id: String; let os: String; let architecture: String; let digests: [String]? }
        struct Container: Decodable { let id: String; let image: String; let name: String; let state: String; let project: String?; let service: String? }
        let imageRows: [Image] = try lines(images)
        let containerRows: [Container] = try lines(containers)
        let volumeNames: [String] = try lines(volumes)
        var items: [ApplicationCandidate] = []
        var knownImages = Set<String>()
        for image in imageRows {
            guard digest(image.id), token(image.os), token(image.architecture), knownImages.insert(image.id).inserted else {
                throw PackageCommandError.failed(.invalidOutput)
            }
            let platform = image.os + "/" + image.architecture
            // Config digest + platform is immutable. A tag never becomes a version.
            let reference = image.digests?.first(where: { $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil })
            var info = ["DockerImageID": image.id, "DiscoveryPlatform": platform]
            if let reference { info["DockerImageReference"] = reference }
            items.append(item(id: contextID + ":image:" + image.id + ":" + platform,
                name: reference?.components(separatedBy: "@").first ?? String(format: String(localized: "Image %@", bundle: AppL10n.bundle, locale: AppL10n.locale), String(image.id.dropFirst(7).prefix(12))),
                role: "image", version: String(image.id.prefix(19)), parentID: contextID, manager: manager, info: info))
        }
        var projects = Set<String>()
        var seenContainers = Set<String>()
        for container in containerRows {
            guard hexID(container.id), digest(container.image), token(container.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                  ["created", "running", "paused", "restarting", "removing", "exited", "dead"].contains(container.state),
                  seenContainers.insert(container.id).inserted else { throw PackageCommandError.failed(.invalidOutput) }
            var parentID = contextID
            if let project = container.project, !project.isEmpty {
                guard token(project) else { throw PackageCommandError.failed(.invalidOutput) }
                parentID = contextID + ":compose:" + project
                if projects.insert(project).inserted {
                    items.append(item(id: parentID, name: project, role: "composeProject", version: "Unknown", parentID: contextID, manager: manager))
                }
            }
            var info = ["DiscoveryState": container.state, "DockerImageID": container.image]
            if let service = container.service, !service.isEmpty {
                guard token(service) else { throw PackageCommandError.failed(.invalidOutput) }
                info["ComposeService"] = service
            }
            // Images are shared siblings under the context, referenced by digest.
            // Two containers sharing one image produce exactly one image record.
            items.append(item(id: contextID + ":container:" + container.id,
                name: container.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")), role: "container",
                version: "Unknown", parentID: parentID, manager: manager, info: info))
        }
        guard Set(volumeNames).count == volumeNames.count else { throw PackageCommandError.failed(.invalidOutput) }
        for name in volumeNames {
            guard token(name) else { throw PackageCommandError.failed(.invalidOutput) }
            items.append(item(id: contextID + ":volume:" + name, name: name, role: "volume",
                version: "Unknown", parentID: contextID, manager: manager))
        }
        return items
    }

    private static func item(id: String, name: String, role: String, version: String, parentID: String?,
                             manager: String, info: [String: String] = [:]) -> ApplicationCandidate {
        ApplicationCandidate(inventoryID: id, path: "", name: name, bundleIdentifier: "docker-" + role,
            displayVersion: version, buildVersion: "", teamIdentifier: nil, parentInventoryID: parentID,
            parentManagerBundleIdentifier: manager, isSystemApplication: false,
            info: info.merging(["DiscoverySource": "Docker", "DiscoveryRole": role]) { first, _ in first }, kind: kind(role))
    }

    private static func kind(_ role: String) -> InventoryItemKind {
        switch role {
        case "context": .containerContext
        case "composeProject": .composeProject
        case "container": .container
        case "image": .containerImage
        default: .containerVolume
        }
    }

    private static func identifiers(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { throw PackageCommandError.failed(.invalidOutput) }
        let values = text.split(whereSeparator: \.isNewline).map(String.init)
        guard values.count <= 2000, values.allSatisfy({ hexID($0) || digest($0) }) else {
            throw PackageCommandError.failed(.invalidOutput)
        }
        return Array(Set(values)).sorted()
    }

    private static func lines<T: Decodable>(_ data: Data) throws -> [T] {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw PackageCommandError.failed(.outputTooLarge)
        }
        let rows = text.split(whereSeparator: \.isNewline)
        guard rows.count <= 2000 else { throw PackageCommandError.failed(.outputTooLarge) }
        return try rows.map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
    private static func hexID(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ value: String) -> Bool { value.hasPrefix("sha256:") && hexID(String(value.dropFirst(7))) }
    private static func printable(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 1024 && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    private static func token(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func findExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.docker/bin/docker", home + "/.orbstack/bin/docker", "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
