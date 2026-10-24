import Foundation

/// Offline discovery never launches configurable package-manager executables.
/// Installation receipts prove installed versions; they are not latest-release evidence.
enum OfflinePackageInventory {
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     prefixes: [URL] = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")],
                     control: ScanControl = ScanControl()) -> PackageInventorySnapshot {
        var candidates: [ApplicationCandidate] = []
        var casksByPath: [String: PackageProvenance] = [:]
        for prefix in prefixes {
            if control.shouldStop { break }
            let brew = prefix.appendingPathComponent("bin/brew").path
            var formulae: [[String: Any]] = []
            var casks: [[String: Any]] = []
            for formula in children(prefix.appendingPathComponent("Cellar")) {
                if control.shouldStop { break }
                for version in children(formula) {
                    if control.shouldStop { break }
                    guard let receipt = json(version.appendingPathComponent("INSTALL_RECEIPT.json")),
                          receipt["installed_on_request"] as? Bool == true else { continue }
                    formulae.append(["name": formula.lastPathComponent,
                        "installed": [["version": version.lastPathComponent, "installed_on_request": true]]])
                }
            }
            for cask in children(prefix.appendingPathComponent("Caskroom")) {
                if control.shouldStop { break }
                let metadata = cask.appendingPathComponent(".metadata")
                for version in children(metadata) {
                    if control.shouldStop { break }
                    for timestamp in children(version) {
                        if control.shouldStop { break }
                        for file in children(timestamp.appendingPathComponent("Casks")) where file.pathExtension == "json" {
                            if control.shouldStop { break }
                            guard var record = json(file), record["token"] as? String == cask.lastPathComponent else { continue }
                            record["installed"] = version.lastPathComponent
                            // The installed recipe's version is not a check of the current release.
                            record.removeValue(forKey: "version")
                            record.removeValue(forKey: "outdated")
                            casks.append(record)
                        }
                    }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["formulae": formulae, "casks": casks]) {
                let parsed = PackageInventoryScanner.parseHomebrew(data: data, executablePath: brew)
                candidates += parsed.candidates
                casksByPath.merge(parsed.caskApplicationsByPath) { first, _ in first }
            }
        }
        let npmRoots = prefixes.map { $0.appendingPathComponent("lib/node_modules") }
            + [home.appendingPathComponent(".local/lib/node_modules")]
            + children(home.appendingPathComponent(".nvm/versions/node")).map { $0.appendingPathComponent("lib/node_modules") }
            + children(home.appendingPathComponent(".local/share/mise/installs/node")).map { $0.appendingPathComponent("lib/node_modules") }
            + children(home.appendingPathComponent(".asdf/installs/nodejs")).map { $0.appendingPathComponent("lib/node_modules") }
        var seen = Set<String>()
        for root in npmRoots where seen.insert(root.resolvingSymlinksInPath().path).inserted {
            if control.shouldStop { break }
            var dependencies: [String: Any] = [:]
            let packages = children(root).flatMap { $0.lastPathComponent.hasPrefix("@") ? children($0) : [$0] }
            for package in packages {
                if control.shouldStop { break }
                guard let metadata = json(package.appendingPathComponent("package.json")),
                      let name = metadata["name"] as? String, let version = metadata["version"] as? String,
                      name == package.lastPathComponent || name == package.deletingLastPathComponent().lastPathComponent + "/" + package.lastPathComponent else { continue }
                dependencies[name] = ["version": version]
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["dependencies": dependencies]) {
                let executable = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/npm").path
                candidates += PackageInventoryScanner.parseNPM(data: data, executablePath: executable, globalRoot: root.path)
            }
        }
        return PackageInventorySnapshot(candidates: candidates, caskApplicationsByPath: casksByPath,
            diagnostics: [.init(source: String(localized: "Other package environments", bundle: AppL10n.bundle, locale: AppL10n.locale), reason: .offlineSkipped)])
    }

    private static func children(_ url: URL) -> [URL] {
        Array(((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []).sorted { $0.path < $1.path }.prefix(2_000))
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue <= 2 * 1_024 * 1_024, let data = try? Data(contentsOf: url), data.count <= 2 * 1_024 * 1_024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
