import Foundation

struct PackageInventorySnapshot: Sendable {
    let candidates: [ApplicationCandidate]
    let caskApplicationsByPath: [String: PackageProvenance]

    var diagnostics: [ScanDiagnostic] = []

    static let empty = PackageInventorySnapshot(candidates: [], caskApplicationsByPath: [:])
}

struct PackageInventoryScanner: Sendable {
    func scan(control: ScanControl = ScanControl(), offline: Bool = false,
              progress: @Sendable (String) -> Void = { _ in }) -> PackageInventorySnapshot {
        if offline { return OfflinePackageInventory.scan(control: control) }
        var diagnostics: [ScanDiagnostic] = []
        var commandIndex: [String: Int] = [:]
        func run(executable: String, arguments: [String], timeout: TimeInterval = 20) -> PackageCommandResult? {
            let manager = URL(fileURLWithPath: executable).lastPathComponent
            let operation: ScanDiagnostic.Operation? = manager == "npm" ? {
                switch arguments.first {
                case "root": .npmGlobalRoot
                case "ls": .npmGlobalList
                case "outdated": .npmGlobalOutdated
                default: nil
                }
            }() : nil
            commandIndex[manager, default: 0] += 1
            let source = manager + " #" + String(commandIndex[manager]!)
            progress(String(format: String(localized: "Inspecting package environments · %@", bundle: AppL10n.bundle, locale: AppL10n.locale), source))
            do {
                let result = try PackageCommandRunner.run(executable: executable, arguments: arguments,
                                                          timeout: timeout, control: control)
                // npm reports outdated/partially invalid installs with exit code 1.
                let acceptsOne = manager == "npm" && ["outdated", "ls"].contains(arguments.first ?? "")
                guard result.terminationStatus == 0 || (acceptsOne && result.terminationStatus == 1) else {
                    diagnostics.append(.init(source: source, reason: .commandFailed, operation: operation)); return nil
                }
                if arguments.contains("--json") || arguments.contains("--json=v2") || arguments.contains("--format=json") {
                    guard Self.validJSON(result.output, arguments: arguments) else {
                        diagnostics.append(.init(source: source, reason: .invalidOutput, operation: operation)); return nil
                    }
                } else if let text = String(data: result.output, encoding: .utf8) {
                    if arguments == ["install", "--list"] || arguments == ["tool", "list", "--offline", "--color", "never"] {
                        guard Self.validToolListing(text, cargo: arguments.first == "install") else {
                            diagnostics.append(.init(source: source, reason: .invalidOutput, operation: operation)); return nil
                        }
                    }
                    if ["root", "dir", "environment", "-c"].contains(arguments.first ?? ""),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                        diagnostics.append(.init(source: source, reason: .invalidOutput, operation: operation)); return nil
                    }
                } else { diagnostics.append(.init(source: source, reason: .invalidOutput, operation: operation)); return nil }
                return result
            } catch let PackageCommandError.failed(reason) {
                diagnostics.append(.init(source: source, reason: reason, operation: operation)); return nil
            } catch { diagnostics.append(.init(source: source, reason: .unavailable, operation: operation)); return nil }
        }
        var candidates: [ApplicationCandidate] = []
        var caskApplicationsByPath: [String: PackageProvenance] = [:]

        if let brew = ExecutableLocator.first(named: "brew", additionalPaths: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew"
        ]), let result = run(
            executable: brew,
            arguments: ["info", "--json=v2", "--installed"]
        ) {
            let snapshot = Self.parseHomebrew(data: result.output, executablePath: brew)
            candidates.append(contentsOf: snapshot.candidates)
            caskApplicationsByPath.merge(snapshot.caskApplicationsByPath) { current, _ in current }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let npmPaths = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            home.appendingPathComponent(".local/bin/npm").path,
            home.appendingPathComponent(".volta/bin/npm").path
        ] + ExecutableLocator.versioned(named: "npm", roots: [
            home.appendingPathComponent(".nvm/versions/node").path,
            home.appendingPathComponent(".local/share/mise/installs/node").path,
            home.appendingPathComponent(".asdf/installs/nodejs").path
        ])
        var scannedNPMRoots = Set<String>()
        for npm in ExecutableLocator.all(named: "npm", additionalPaths: npmPaths).prefix(12) {
            if control.shouldStop { break }
            guard let root = run(executable: npm, arguments: ["root", "-g"], timeout: 3)
                .flatMap({ String(data: $0.output, encoding: .utf8) })?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                root.hasPrefix("/"),
                scannedNPMRoots.insert(URL(fileURLWithPath: root).resolvingSymlinksInPath().path).inserted,
                let result = run(
                    executable: npm, arguments: ["ls", "-g", "--depth=0", "--json"], timeout: 5
                ) else { continue }
            let outdated = run(
                executable: npm,
                arguments: ["outdated", "-g", "--depth=0", "--json"], timeout: 8
            )
            candidates.append(contentsOf: Self.parseNPM(
                data: result.output,
                executablePath: npm,
                globalRoot: root,
                outdatedData: outdated?.output
            ))
        }

        let pythonPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            home.appendingPathComponent(".pyenv/shims/python3").path
        ] + ["VIRTUAL_ENV", "CONDA_PREFIX"].compactMap {
            ProcessInfo.processInfo.environment[$0].map { URL(fileURLWithPath: $0).appendingPathComponent("bin/python3").path }
        } + ExecutableLocator.versioned(named: "python3", roots: [
            home.appendingPathComponent(".pyenv/versions").path,
            home.appendingPathComponent(".local/share/mise/installs/python").path,
            home.appendingPathComponent(".asdf/installs/python").path,
            home.appendingPathComponent("miniconda3/envs").path,
            home.appendingPathComponent("anaconda3/envs").path
        ])
        var scannedPythonEnvironments = Set<String>()
        for python in ExecutableLocator.all(named: "python3", additionalPaths: pythonPaths).prefix(20) {
            if control.shouldStop { break }
            guard let environment = run(
                executable: python,
                arguments: ["-c", "import sys; print(sys.prefix)"],
                timeout: 5
            ).flatMap({ String(data: $0.output, encoding: .utf8) })?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                environment.hasPrefix("/"),
                scannedPythonEnvironments.insert(URL(fileURLWithPath: environment).resolvingSymlinksInPath().path).inserted
            else { continue }
            guard let result = run(
                executable: python,
                arguments: ["-m", "pip", "list", "--not-required", "--format=json"], timeout: 5
            ) else { continue }
            let outdated = run(
                executable: python,
                arguments: ["-m", "pip", "list", "--outdated", "--format=json"], timeout: 8
            )
            candidates.append(contentsOf: Self.parsePythonPip(
                data: result.output,
                executablePath: python,
                outdatedData: outdated?.output
            ))
        }

        if !control.shouldStop, let pipx = ExecutableLocator.first(named: "pipx", additionalPaths: [
            "/opt/homebrew/bin/pipx", home.appendingPathComponent(".local/bin/pipx").path
        ]), let pipxHome = run(
            executable: pipx, arguments: ["environment", "--skip-maintenance", "--value", "PIPX_HOME"], timeout: 5
        ).flatMap({ String(data: $0.output, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let listed = run(
                executable: pipx, arguments: ["list", "--skip-maintenance", "--json"], timeout: 8
           ) {
            candidates.append(contentsOf: Self.parsePipx(
                data: listed.output, executablePath: pipx, homePath: pipxHome
            ))
        }

        if !control.shouldStop, let uv = ExecutableLocator.first(named: "uv", additionalPaths: [
            "/opt/homebrew/bin/uv", home.appendingPathComponent(".local/bin/uv").path
        ]), let toolDirectory = run(executable: uv, arguments: ["tool", "dir"], timeout: 5)
            .flatMap({ String(data: $0.output, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let listed = run(
                executable: uv, arguments: ["tool", "list", "--offline", "--color", "never"], timeout: 8
           ) {
            candidates.append(contentsOf: Self.parseUVTools(
                data: listed.output, executablePath: uv, toolDirectory: toolDirectory
            ))
        }

        if !control.shouldStop, let cargo = ExecutableLocator.first(named: "cargo", additionalPaths: [
            home.appendingPathComponent(".cargo/bin/cargo").path,
            "/opt/homebrew/bin/cargo"
        ]), let listed = run(executable: cargo, arguments: ["install", "--list"], timeout: 8) {
            let installRoot = ProcessInfo.processInfo.environment["CARGO_INSTALL_ROOT"]
                ?? ProcessInfo.processInfo.environment["CARGO_HOME"]
                ?? home.appendingPathComponent(".cargo").path
            candidates.append(contentsOf: Self.parseCargo(
                data: listed.output, executablePath: cargo, installRoot: installRoot
            ))
        }

        let unique = Dictionary(candidates.map { ($0.inventoryID, $0) }, uniquingKeysWith: { first, _ in first })
        return PackageInventorySnapshot(
            candidates: unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            caskApplicationsByPath: caskApplicationsByPath,
            diagnostics: diagnostics
        )
    }

    static func validToolListing(_ text: String, cargo: Bool) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        if lines.isEmpty { return true }
        let headings = lines.filter { !$0.first!.isWhitespace }
        guard !headings.isEmpty else { return false }
        return headings.allSatisfy { line in
            let parts = line.split(separator: " ")
            return parts.count >= 2 && safePackageName(String(parts[0]))
                && parts[1].first == "v" && parts[1].dropFirst().first?.isNumber == true
                && (!cargo || line.last == ":")
        }
    }

    static func validJSON(_ data: Data, arguments: [String]) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        if arguments.contains("--json=v2") {
            guard let root = value as? [String: Any] else { return false }
            return root["formulae"] is [[String: Any]] && root["casks"] is [[String: Any]]
        }
        if arguments.contains("--format=json") {
            guard let rows = value as? [[String: Any]] else { return false }
            return rows.allSatisfy { $0["name"] is String && $0["version"] is String }
        }
        guard let root = value as? [String: Any] else { return false }
        if arguments.first == "ls" {
            return root["dependencies"] == nil || root["dependencies"] is [String: [String: Any]]
        }
        if arguments.first == "outdated" { return value is [String: [String: Any]] }
        if arguments.contains("--skip-maintenance") { return root["venvs"] is [String: Any] }
        return true
    }

    static func parseHomebrew(data: Data, executablePath: String) -> PackageInventorySnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }

        let prefix = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        var candidates: [ApplicationCandidate] = []
        var caskApplicationsByPath: [String: PackageProvenance] = [:]

        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String,
                  let installed = formula["installed"] as? [[String: Any]],
                  let current = installed.last,
                  current["installed_on_request"] as? Bool == true else { continue }

            let version = current["version"] as? String ?? "Unknown"
            let installLocation = URL(fileURLWithPath: prefix)
                .appendingPathComponent("Cellar", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .path
            let provenance = PackageProvenance(
                identifier: name,
                manager: .homebrewFormula,
                managerExecutablePath: executablePath,
                installLocation: installLocation,
                explicitlyInstalled: true,
                homepage: (formula["homepage"] as? String).flatMap(URL.init(string:)),
                summary: formula["desc"] as? String,
                isOutdated: formula["outdated"] as? Bool,
                latestVersion: (formula["versions"] as? [String: Any])?["stable"] as? String,
                installedVersion: version
            )
            candidates.append(packageCandidate(
                provenance: provenance,
                name: name,
                version: version,
                path: installLocation,
                kind: .commandLineTool
            ))
        }

        for cask in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = cask["token"] as? String else { continue }
            let installedValue = cask["installed"]
            let version = (installedValue as? String)
                ?? (installedValue as? [String])?.last
                ?? "Unknown"
            let provenance = PackageProvenance(
                identifier: token,
                manager: .homebrewCask,
                managerExecutablePath: executablePath,
                installLocation: nil,
                explicitlyInstalled: true,
                homepage: (cask["homepage"] as? String).flatMap(URL.init(string:)),
                summary: cask["desc"] as? String,
                isOutdated: cask["outdated"] as? Bool,
                latestVersion: cask["version"] as? String,
                installedVersion: version
            )
            let appTargets = homebrewAppTargets(from: cask)
            for target in appTargets {
                let normalizedPath = URL(fileURLWithPath: target).standardizedFileURL.path
                caskApplicationsByPath[normalizedPath] = PackageProvenance(
                    identifier: provenance.identifier,
                    manager: provenance.manager,
                    managerExecutablePath: provenance.managerExecutablePath,
                    installLocation: normalizedPath,
                    explicitlyInstalled: provenance.explicitlyInstalled,
                    homepage: provenance.homepage,
                    summary: provenance.summary,
                    isOutdated: provenance.isOutdated,
                    latestVersion: provenance.latestVersion,
                    installedVersion: provenance.installedVersion
                )
            }

            if appTargets.isEmpty {
                let caskroomPath = URL(fileURLWithPath: prefix)
                    .appendingPathComponent("Caskroom", isDirectory: true)
                    .appendingPathComponent(token, isDirectory: true)
                    .appendingPathComponent(version, isDirectory: true)
                    .path
                let packageProvenance = PackageProvenance(
                    identifier: provenance.identifier,
                    manager: provenance.manager,
                    managerExecutablePath: provenance.managerExecutablePath,
                    installLocation: caskroomPath,
                    explicitlyInstalled: provenance.explicitlyInstalled,
                    homepage: provenance.homepage,
                    summary: provenance.summary,
                    isOutdated: provenance.isOutdated,
                    latestVersion: provenance.latestVersion,
                    installedVersion: provenance.installedVersion
                )
                candidates.append(packageCandidate(
                    provenance: packageProvenance,
                    name: (cask["name"] as? [String])?.first ?? token,
                    version: version,
                    path: caskroomPath,
                    kind: .package
                ))
            }
        }

        return PackageInventorySnapshot(
            candidates: candidates,
            caskApplicationsByPath: caskApplicationsByPath
        )
    }

    static func parseNPM(
        data: Data,
        executablePath: String,
        globalRoot: String?,
        outdatedData: Data? = nil
    ) -> [ApplicationCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any] else { return [] }

        let outdated = outdatedData.flatMap(parseNPMOutdated)

        return dependencies.compactMap { name, rawValue in
            guard name != "npm", let details = rawValue as? [String: Any] else { return nil }
            let version = details["version"] as? String ?? "Unknown"
            let latestVersion = (outdated?[name]?["latest"] as? String)
                ?? (outdated?[name]?["wanted"] as? String)
            let installLocation = globalRoot.map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name, isDirectory: true).path
            }
            let provenance = PackageProvenance(
                identifier: name,
                manager: .npm,
                managerExecutablePath: executablePath,
                installLocation: installLocation,
                explicitlyInstalled: true,
                homepage: nil,
                summary: nil,
                isOutdated: outdated.map { $0[name] != nil },
                latestVersion: latestVersion
            )
            return packageCandidate(
                provenance: provenance,
                name: name,
                version: version,
                path: installLocation ?? executablePath,
                kind: .commandLineTool
            )
        }
    }

    static func parsePythonPip(
        data: Data,
        executablePath: String,
        outdatedData: Data? = nil
    ) -> [ApplicationCandidate] {
        guard let packages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let ignored = Set(["pip", "setuptools", "wheel"])
        let outdated = outdatedData.flatMap(parsePipOutdated)

        return packages.compactMap { package in
            guard let name = package["name"] as? String,
                  !ignored.contains(name.lowercased()) else { return nil }
            let version = package["version"] as? String ?? "Unknown"
            let latestVersion = outdated?[name.lowercased()]
            let provenance = PackageProvenance(
                identifier: name,
                manager: .pythonPip,
                managerExecutablePath: executablePath,
                installLocation: nil,
                explicitlyInstalled: false,
                homepage: nil,
                summary: String(localized: "Top-level package in this Python environment", bundle: AppL10n.bundle, locale: AppL10n.locale),
                isOutdated: outdated.map { $0[name.lowercased()] != nil },
                latestVersion: latestVersion
            )
            return packageCandidate(
                provenance: provenance,
                name: name,
                version: version,
                path: executablePath,
                kind: .package
            )
        }
    }

    static func parsePipx(data: Data, executablePath: String, homePath: String) -> [ApplicationCandidate] {
        guard homePath.hasPrefix("/"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let venvs = root["venvs"] as? [String: [String: Any]] else { return [] }

        return venvs.compactMap { environmentName, details in
            guard safePackageName(environmentName),
                  let metadata = details["metadata"] as? [String: Any],
                  let package = metadata["main_package"] as? [String: Any],
                  let version = package["package_version"] as? String,
                  !version.isEmpty else { return nil }
            let name = (package["package"] as? String) ?? environmentName
            let environment = URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent("venvs", isDirectory: true)
                .appendingPathComponent(environmentName, isDirectory: true)
            guard FileManager.default.isExecutableFile(
                atPath: environment.appendingPathComponent("bin/python").path
            ) else { return nil }
            let provenance = PackageProvenance(
                identifier: environmentName,
                manager: .pipx,
                managerExecutablePath: executablePath,
                installLocation: environment.path,
                explicitlyInstalled: true,
                homepage: nil,
                summary: String(localized: "Isolated pipx tool; latest-version verification is pending.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                isOutdated: nil
            )
            return packageCandidate(
                provenance: provenance, name: name, version: version,
                path: environment.path, kind: .commandLineTool
            )
        }
    }

    static func parseUVTools(data: Data, executablePath: String, toolDirectory: String) -> [ApplicationCandidate] {
        guard toolDirectory.hasPrefix("/"), let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.first!.isWhitespace else { return nil }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2,
                  safePackageName(String(parts[0])),
                  parts[1].first == "v",
                  parts[1].dropFirst().first?.isNumber == true else { return nil }
            let name = String(parts[0])
            let version = String(parts[1].dropFirst())
            let environment = URL(fileURLWithPath: toolDirectory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.isExecutableFile(
                atPath: environment.appendingPathComponent("bin/python").path
            ) else { return nil }
            let provenance = PackageProvenance(
                identifier: name,
                manager: .uvTool,
                managerExecutablePath: executablePath,
                installLocation: environment.path,
                explicitlyInstalled: true,
                homepage: nil,
                summary: String(localized: "Persistent uv tool; latest-version verification is pending.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                isOutdated: nil
            )
            return packageCandidate(
                provenance: provenance, name: name, version: version,
                path: environment.path, kind: .commandLineTool
            )
        }
    }

    static func parseCargo(data: Data, executablePath: String, installRoot: String) -> [ApplicationCandidate] {
        guard installRoot.hasPrefix("/"), let output = String(data: data, encoding: .utf8) else { return [] }
        var entries: [(name: String, version: String, binaries: [String])] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if !line.first!.isWhitespace {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts[1].first == "v", line.last == ":",
                      safePackageName(String(parts[0])),
                      parts[1].dropFirst().first?.isNumber == true else { continue }
                entries.append((String(parts[0]), String(parts[1].dropFirst()), []))
            } else if let index = entries.indices.last {
                let binary = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if safePackageName(binary) { entries[index].binaries.append(binary) }
            }
        }
        let binDirectory = URL(fileURLWithPath: installRoot, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        return entries.compactMap { entry in
            guard let binary = entry.binaries.first(where: {
                FileManager.default.isExecutableFile(atPath: binDirectory.appendingPathComponent($0).path)
            }) else { return nil }
            let location = binDirectory.appendingPathComponent(binary).path
            let provenance = PackageProvenance(
                identifier: entry.name,
                manager: .cargo,
                managerExecutablePath: executablePath,
                installLocation: location,
                explicitlyInstalled: true,
                homepage: nil,
                summary: String(localized: "Cargo-installed binary crate; latest-version verification is pending.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                isOutdated: nil
            )
            return packageCandidate(
                provenance: provenance, name: entry.name, version: entry.version,
                path: location, kind: .commandLineTool
            )
        }
    }

    private static func safePackageName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func parseNPMOutdated(_ data: Data) -> [String: [String: Any]]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    }

    static func parsePipOutdated(_ data: Data) -> [String: String]? {
        guard let packages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        // pip can list one name twice (case variants, duplicate dist-info); keep the first.
        return Dictionary(packages.compactMap { package in
            guard let name = package["name"] as? String,
                  let latest = package["latest_version"] as? String else { return nil }
            return (name.lowercased(), latest)
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func homebrewAppTargets(from cask: [String: Any]) -> [String] {
        guard let artifacts = cask["artifacts"] as? [Any] else { return [] }
        return artifacts.compactMap { artifact in
            guard let dictionary = artifact as? [String: Any], dictionary["app"] != nil else { return nil }
            if let target = dictionary["target"] as? String { return target }
            if let apps = dictionary["app"] as? [String], let app = apps.first {
                return URL(fileURLWithPath: "/Applications", isDirectory: true)
                    .appendingPathComponent(app)
                    .path
            }
            return nil
        }
    }

    private static func packageCandidate(
        provenance: PackageProvenance,
        name: String,
        version: String,
        path: String,
        kind: InventoryItemKind
    ) -> ApplicationCandidate {
        ApplicationCandidate(
            inventoryID: "package:\(provenance.manager.rawValue):\(provenance.managerExecutablePath):\(provenance.identifier)",
            path: path,
            name: name,
            bundleIdentifier: provenance.identifier,
            displayVersion: version,
            buildVersion: version,
            teamIdentifier: nil,
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [:],
            kind: kind,
            packageProvenance: provenance
        )
    }
}

enum ExecutableLocator {
    static func versioned(named name: String, roots: [String]) -> [String] {
        roots.flatMap { root in
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [String]() }
            return entries.sorted().prefix(12).map {
                URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent($0, isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(name).path
            }
        }
    }
    static func first(named name: String, additionalPaths: [String]) -> String? {
        all(named: name, additionalPaths: additionalPaths).first
    }

    static func all(
        named name: String,
        additionalPaths: [String],
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String] {
        // A relative PATH entry (".", "bin", or an empty one) resolves against the current
        // directory, so a command run there could pick up a planted binary; skip them.
        let pathCandidates = (searchPath ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name).path }
        var seen = Set<String>()
        return (additionalPaths + pathCandidates).compactMap { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardized).inserted,
                  FileManager.default.isExecutableFile(atPath: standardized) else { return nil }
            return standardized
        }
    }
}
