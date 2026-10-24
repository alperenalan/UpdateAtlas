import Foundation

struct DiscoveredBundle: Sendable {
    let url: URL
    let manager: String?
    let source: String
}

struct LocalDiscoveryResult: Sendable {
    var bundles: [DiscoveredBundle] = []
    var candidates: [ApplicationCandidate] = []
    var diagnostics: [ScanDiagnostic] = []
}

/// Reviewed local registries and bounded folder traversal. No manager is launched;
/// library/owned-game caches are intentionally excluded from installed inventory.
struct LocalDiscoveryProvider: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var shared = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
    var applicationRoots = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
    var run: @Sendable (String, [String], ScanControl) throws -> PackageCommandResult = {
        try PackageCommandRunner.run(executable: $0, arguments: $1, timeout: 8, control: $2)
    }

    func scan(configuration: DiscoveryConfiguration, control: ScanControl) -> LocalDiscoveryResult {
        var result = LocalDiscoveryResult()
        let support = home.appendingPathComponent("Library/Application Support")
        let managers: [(String, String, [URL])] = [
            ("Setapp", "com.setapp.DesktopClient", applicationRoots.map { $0.appendingPathComponent("Setapp") }
                + [home.appendingPathComponent("Applications/Setapp")]),
            ("JetBrains Toolbox", "com.jetbrains.toolbox", [
                support.appendingPathComponent("JetBrains/Toolbox/apps"),
                home.appendingPathComponent("Applications/JetBrains Toolbox")
            ])
        ]
        for (source, manager, roots) in managers {
            for root in roots where FileManager.default.fileExists(atPath: root.path) {
                let files = Self.walk(root: root, control: control, source: source, diagnostics: &result.diagnostics)
                result.bundles += files.filter { $0.pathExtension.lowercased() == "app" }.compactMap { url in
                    if manager == "com.jetbrains.toolbox",
                       !(ApplicationBundleMetadataReader.infoDictionary(at: url)?["CFBundleIdentifier"] as? String ?? "").hasPrefix("com.jetbrains.") { return nil }
                    return DiscoveredBundle(url: url, manager: manager, source: source)
                }
            }
        }
        // Current Toolbox installations in ~/Applications are already covered by
        // standard discovery. Do not infer ownership merely from an IDE bundle ID.
        for root in applicationRoots + [home.appendingPathComponent("Applications")] {
            for url in Self.children(root, source: "Application managers", diagnostics: &result.diagnostics) {
                guard url.lastPathComponent.hasPrefix("Adobe "), Self.isDirectory(url) else { continue }
                let files = Self.walk(root: url, maximumDepth: 3, control: control, source: "Adobe", diagnostics: &result.diagnostics)
                for app in files where app.pathExtension.lowercased() == "app" {
                    guard (ApplicationBundleMetadataReader.infoDictionary(at: app)?["CFBundleIdentifier"] as? String ?? "").hasPrefix("com.adobe.") else { continue }
                    // Bundle discovery is certain; Creative Cloud ownership is
                    // classified from its catalog instead of guessed for legacy CS.
                    result.bundles.append(.init(url: app, manager: nil, source: "Adobe"))
                }
            }
        }
        for (index, root) in configuration.folders.enumerated() {
            let source = "Custom folder #\(index + 1)"
            guard Self.isDirectory(root) else {
                result.diagnostics.append(.init(source: source, reason: .unavailable)); continue
            }
            let files = Self.walk(root: root, control: control, source: source, diagnostics: &result.diagnostics)
            result.bundles += files.filter { $0.pathExtension.lowercased() == "app" }.map {
                DiscoveredBundle(url: $0, manager: nil, source: "Custom folder")
            }
            result.candidates += gogManifests(files: files, control: control, diagnostics: &result.diagnostics)
            result.candidates += bottles(files: files, control: control, diagnostics: &result.diagnostics)
        }
        // Epic .item records hold the actual library path, including external disks.
        for root in [support.appendingPathComponent("Epic/EpicGamesLauncher/Data/Manifests"),
                     shared.appendingPathComponent("Epic Games/EpicGamesLauncher/Data/Manifests")] {
            for url in Self.children(root, source: "Epic Games", diagnostics: &result.diagnostics)
                where url.pathExtension == "item" {
                if control.shouldStop { break }
                if let data = Self.read(url, source: "Epic Games", diagnostics: &result.diagnostics) {
                    do { result.candidates += try Self.epicGames(data: data) }
                    catch { result.diagnostics.append(.init(source: "Epic Games", reason: .invalidOutput)) }
                }
            }
        }
        for root in [support.appendingPathComponent("heroic"), home.appendingPathComponent(".config/heroic")] {
            for (relative, platform) in [("legendaryConfig/legendary/installed.json", GamePlatformKind.epic),
                                          ("gog_store/installed.json", .gog)] {
                let url = root.appendingPathComponent(relative)
                if let data = Self.read(url, source: "Heroic", diagnostics: &result.diagnostics) {
                    do { result.candidates += try Self.heroicGames(data: data, platform: platform) }
                    catch { result.diagnostics.append(.init(source: "Heroic", reason: .invalidOutput)) }
                }
            }
        }
        // Galaxy's installed table is separate from its owned/downloadable library.
        for url in [shared.appendingPathComponent("GOG.com/Galaxy/Storage/galaxy-2.0.db"),
                    support.appendingPathComponent("GOG.com/Galaxy/Storage/galaxy-2.0.db")] {
            guard FileManager.default.fileExists(atPath: url.path), !control.shouldStop else { continue }
            do {
                let response = try run("/usr/bin/sqlite3", ["-readonly", "-json", url.path,
                    "SELECT productId, installationPath FROM InstalledBaseProducts LIMIT 2001;"], control)
                guard response.terminationStatus == 0 else { throw PackageCommandError.failed(.commandFailed) }
                result.candidates += try Self.galaxyGames(data: response.output.isEmpty ? Data("[]".utf8) : response.output)
            } catch {
                let failure = Self.diagnostic(error, source: "GOG Galaxy")
                result.diagnostics.append(.init(source: failure.source, reason: failure.reason, operation: .gogInstalledTable))
            }
        }
        for root in [home.appendingPathComponent("GOG Games"), URL(fileURLWithPath: "/Applications/GOG Games")] {
            let files = Self.walk(root: root, control: control, source: "GOG", diagnostics: &result.diagnostics)
            result.candidates += gogManifests(files: files, control: control, diagnostics: &result.diagnostics)
        }
        let crossoverRoot = support.appendingPathComponent("CrossOver/Bottles")
        result.candidates += bottles(files: Self.children(crossoverRoot, source: "CrossOver", diagnostics: &result.diagnostics)
            .map { $0.appendingPathComponent("cxbottle.conf") }, control: control, diagnostics: &result.diagnostics)
        let whiskyRoot = home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky")
        var whiskyFolders = Self.children(whiskyRoot.appendingPathComponent("Bottles"), source: "Whisky", diagnostics: &result.diagnostics)
        if let data = Self.read(whiskyRoot.appendingPathComponent("BottleVM.plist"), source: "Whisky", diagnostics: &result.diagnostics) {
            struct Registry: Decodable { let paths: [URL] }
            if let registry = try? PropertyListDecoder().decode(Registry.self, from: data) {
                whiskyFolders += registry.paths.filter(\.isFileURL)
            } else { result.diagnostics.append(.init(source: "Whisky", reason: .invalidOutput)) }
        }
        result.candidates += bottles(files: whiskyFolders.map { $0.appendingPathComponent("Metadata.plist") },
            control: control, diagnostics: &result.diagnostics)
        result.candidates += additionalWineBottles(support: support, control: control, diagnostics: &result.diagnostics)
        result.candidates += virtualMachines(control: control, diagnostics: &result.diagnostics)
        result.candidates += additionalGameLibraries(support: support, control: control, diagnostics: &result.diagnostics)
        var seenBundles = Set<String>()
        result.bundles = result.bundles.filter {
            Self.installedBundle($0.url) && seenBundles.insert($0.url.resolvingSymlinksInPath().path).inserted
        }
        var seenCandidates = Set<String>()
        result.candidates = result.candidates.filter { seenCandidates.insert($0.inventoryID).inserted }
        var seenDiagnostics = Set<String>()
        result.diagnostics = result.diagnostics.filter { seenDiagnostics.insert($0.source + ":" + $0.reason.rawValue).inserted }
        return result
    }

    static func epicGames(data: Data) throws -> [ApplicationCandidate] {
        let object = try object(data)
        guard object["bIsIncompleteInstall"] as? Bool != true,
              let id = text(object, "AppName"), let path = text(object, "InstallLocation"),
              let executable = text(object, "LaunchExecutable") else { return [] }
        guard let root = absoluteDirectory(path), safePayload(executable, in: root) != nil else { return [] }
        return [game(id: id, root: root, name: text(object, "DisplayName") ?? id,
            version: text(object, "AppVersionString") ?? "Unknown", platform: .epic,
            manager: "com.epicgames.EpicGamesLauncher", source: "Epic Games")]
    }

    static func heroicGames(data: Data, platform: GamePlatformKind) throws -> [ApplicationCandidate] {
        let object = try object(data)
        let rows: [[String: Any]]
        if platform == .gog {
            guard let installed = object["installed"] as? [[String: Any]] else { throw PackageCommandError.failed(.invalidOutput) }
            rows = installed
        } else {
            guard object.values.allSatisfy({ $0 is [String: Any] }) else { throw PackageCommandError.failed(.invalidOutput) }
            rows = object.keys.sorted().compactMap { object[$0] as? [String: Any] }
        }
        guard rows.count <= 2000 else { throw PackageCommandError.failed(.outputTooLarge) }
        return rows.compactMap { row in
            guard row["is_dlc"] as? Bool != true, row["is_preloaded"] as? Bool != true,
                  row["needs_verification"] as? Bool != true,
                  let id = text(row, platform == .gog ? "appName" : "app_name"),
                  let path = text(row, "install_path"), let root = absoluteDirectory(path) else { return nil }
            // GOG's installed record can leave executable empty. Require nonempty
            // local payload rather than treating an orphaned empty directory as installed.
            if let executable = text(row, "executable") {
                guard safePayload(executable, in: root) != nil else { return nil }
            } else { guard hasPayload(root) else { return nil } }
            return game(id: id, root: root, name: text(row, "title") ?? root.lastPathComponent,
                version: text(row, "version") ?? "Unknown", platform: platform,
                manager: "com.heroicgameslauncher.hgl", source: "Heroic")
        }
    }

    static func galaxyGames(data: Data) throws -> [ApplicationCandidate] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count <= 2000 else {
            throw PackageCommandError.failed(.invalidOutput)
        }
        return rows.compactMap { row in
            let id = (row["productId"] as? NSNumber)?.stringValue ?? text(row, "productId")
            guard let id, let path = text(row, "installationPath"), let root = absoluteDirectory(path), hasPayload(root) else { return nil }
            return game(id: id, root: root, name: root.deletingPathExtension().lastPathComponent,
                version: "Unknown", platform: .gog, manager: "com.gog.galaxy", source: "GOG Galaxy")
        }
    }

    private func gogManifests(files: [URL], control: ScanControl, diagnostics: inout [ScanDiagnostic]) -> [ApplicationCandidate] {
        files.filter { $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info" }.compactMap { file in
            guard !control.shouldStop, let data = Self.read(file, source: "GOG", diagnostics: &diagnostics) else { return nil }
            do { return try Self.gogGame(data: data, root: file.deletingLastPathComponent()) }
            catch { diagnostics.append(.init(source: "GOG", reason: .invalidOutput)); return nil }
        }
    }

    static func gogGame(data: Data, root: URL) throws -> ApplicationCandidate? {
        let row = try object(data)
        guard let id = text(row, "gameId"), let tasks = row["playTasks"] as? [[String: Any]],
              tasks.contains(where: { $0["type"] as? String == "FileTask"
                  && text($0, "path").flatMap { safePayload($0, in: root) } != nil }) else { return nil }
        return game(id: id, root: root, name: text(row, "name") ?? root.lastPathComponent,
            version: text(row, "buildId").map { "Build " + $0 } ?? "Unknown", platform: .gog,
            manager: "com.gog.galaxy", source: "GOG manifest")
    }

    private func bottles(files: [URL], control: ScanControl, diagnostics: inout [ScanDiagnostic]) -> [ApplicationCandidate] {
        var output: [ApplicationCandidate] = []
        for file in files where ["cxbottle.conf", "Metadata.plist"].contains(file.lastPathComponent) {
            let root = file.deletingLastPathComponent().resolvingSymlinksInPath()
            guard !control.shouldStop, Self.isDirectory(root.appendingPathComponent("drive_c")),
                  let data = Self.read(file, source: "Wine bottles", diagnostics: &diagnostics) else { continue }
            var name = root.lastPathComponent
            let whisky = file.lastPathComponent == "Metadata.plist"
            if whisky {
                guard let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let bottle = info["info"] as? [String: Any], let title = Self.text(bottle, "name") else {
                    diagnostics.append(.init(source: "Whisky", reason: .invalidOutput)); continue
                }
                name = title
            } else {
                guard let text = String(data: data, encoding: .utf8), text.contains("[Bottle]") else {
                    diagnostics.append(.init(source: "CrossOver", reason: .invalidOutput)); continue
                }
            }
            let managerBundleID = whisky ? "com.isaacmarovitz.Whisky" : "com.codeweavers.CrossOver"
            let sourceName = whisky ? "Whisky" : "CrossOver"
            let bottleID = "wine-bottle:\(root.path)"
            output.append(ApplicationCandidate(inventoryID: bottleID, path: root.path,
                name: name, bundleIdentifier: "wine-bottle", displayVersion: "Unknown", buildVersion: "",
                teamIdentifier: nil, parentManagerBundleIdentifier: managerBundleID,
                isSystemApplication: false, info: ["DiscoverySource": sourceName,
                    "DiscoveryRole": "bottle", "DiscoveryPlatform": "Windows"], kind: .wineBottle))
            output += Self.bottleInstalledApps(
                bottleRoot: root,
                bottleInventoryID: bottleID,
                bottleName: name,
                managerBundleID: managerBundleID,
                sourceName: sourceName
            )
        }
        return output
    }

    private func additionalWineBottles(
        support: URL,
        control: ScanControl,
        diagnostics: inout [ScanDiagnostic]
    ) -> [ApplicationCandidate] {
        var output: [ApplicationCandidate] = []
        // Mythic bottles
        let mythicBottles = support.appendingPathComponent("Mythic/Bottles")
        for folder in Self.children(mythicBottles, source: "Mythic", diagnostics: &diagnostics) {
            if control.shouldStop { break }
            let root = folder.resolvingSymlinksInPath()
            guard Self.isDirectory(root.appendingPathComponent("drive_c")) else { continue }
            let bottleID = "wine-bottle:\(root.path)"
            let name = root.lastPathComponent
            output.append(ApplicationCandidate(
                inventoryID: bottleID,
                path: root.path,
                name: name,
                bundleIdentifier: "wine-bottle",
                displayVersion: "Unknown",
                buildVersion: "",
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "app.getmythic.Mythic",
                isSystemApplication: false,
                info: ["DiscoverySource": "Mythic", "DiscoveryRole": "bottle", "DiscoveryPlatform": "Windows"],
                kind: .wineBottle
            ))
            output += Self.bottleInstalledApps(
                bottleRoot: root,
                bottleInventoryID: bottleID,
                bottleName: name,
                managerBundleID: "app.getmythic.Mythic",
                sourceName: "Mythic"
            )
        }

        // Standard ~/.wine prefix when initialized with system.reg
        let defaultWine = home.appendingPathComponent(".wine").resolvingSymlinksInPath()
        if Self.isDirectory(defaultWine.appendingPathComponent("drive_c")),
           FileManager.default.fileExists(atPath: defaultWine.appendingPathComponent("system.reg").path) {
            let bottleID = "wine-bottle:\(defaultWine.path)"
            output.append(ApplicationCandidate(
                inventoryID: bottleID,
                path: defaultWine.path,
                name: String(localized: "Wine Prefix (.wine)", bundle: AppL10n.bundle, locale: AppL10n.locale),
                bundleIdentifier: "wine-bottle",
                displayVersion: "Unknown",
                buildVersion: "",
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "org.winehq.wine-stable",
                isSystemApplication: false,
                info: ["DiscoverySource": "Wine", "DiscoveryRole": "bottle", "DiscoveryPlatform": "Windows"],
                kind: .wineBottle
            ))
            output += Self.bottleInstalledApps(
                bottleRoot: defaultWine,
                bottleInventoryID: bottleID,
                bottleName: String(localized: "Wine Prefix (.wine)", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerBundleID: "org.winehq.wine-stable",
                sourceName: "Wine"
            )
        }

        // Kegworks / Wineskin / Porting Kit wrapper bundles in ~/Applications
        let wrapperFolders = [
            home.appendingPathComponent("Applications/Kegworks"),
            home.appendingPathComponent("Applications/Wineskin"),
            home.appendingPathComponent("Applications/Porting Kit")
        ]
        for folder in wrapperFolders {
            for wrapper in Self.children(folder, source: "Wine Wrappers", diagnostics: &diagnostics)
                where wrapper.pathExtension.lowercased() == "app" {
                if control.shouldStop { break }
                let root = wrapper.resolvingSymlinksInPath()
                let prefixCandidates = [
                    root.appendingPathComponent("Contents/SharedSupport/prefix"),
                    root.appendingPathComponent("Contents/Resources")
                ]
                guard let prefix = prefixCandidates.first(where: { Self.isDirectory($0.appendingPathComponent("drive_c")) }) else { continue }
                let isPortingKit = folder.lastPathComponent == "Porting Kit"
                let managerBundleID = isPortingKit ? "com.paulthetall.portingkit" : "io.github.kegworks-app.kegworks"
                let sourceName = isPortingKit ? "Porting Kit" : "Kegworks"
                let bottleID = "wine-bottle:\(root.path)"
                let name = root.deletingPathExtension().lastPathComponent
                output.append(ApplicationCandidate(
                    inventoryID: bottleID,
                    path: root.path,
                    name: name,
                    bundleIdentifier: "wine-bottle",
                    displayVersion: "Unknown",
                    buildVersion: "",
                    teamIdentifier: nil,
                    parentManagerBundleIdentifier: managerBundleID,
                    isSystemApplication: false,
                    info: ["DiscoverySource": sourceName, "DiscoveryRole": "bottle", "DiscoveryPlatform": "Windows"],
                    kind: .wineBottle
                ))
                output += Self.bottleInstalledApps(
                    bottleRoot: prefix,
                    bottleInventoryID: bottleID,
                    bottleName: name,
                    managerBundleID: managerBundleID,
                    sourceName: sourceName
                )
            }
        }
        return output
    }

    static func bottleInstalledApps(
        bottleRoot: URL,
        bottleInventoryID: String,
        bottleName: String,
        managerBundleID: String,
        sourceName: String
    ) -> [ApplicationCandidate] {
        let driveC = bottleRoot.appendingPathComponent("drive_c")
        guard isDirectory(driveC) else { return [] }
        let systemReg = bottleRoot.appendingPathComponent("system.reg")
        guard let regData = try? Data(contentsOf: systemReg),
              regData.count <= 8 * 1024 * 1024,
              let content = String(data: regData, encoding: .utf8) ?? String(data: regData, encoding: .isoLatin1) else {
            return []
        }

        var apps: [ApplicationCandidate] = []
        var seenNames = Set<String>()
        let lines = content.components(separatedBy: .newlines)
        var inUninstallKey = false
        var currentName: String?
        var currentVersion: String?
        var currentInstallLocation: String?

        func flushEntry() {
            defer {
                currentName = nil
                currentVersion = nil
                currentInstallLocation = nil
            }
            guard inUninstallKey,
                  let rawName = currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { return }
            let lowered = rawName.lowercased()
            if lowered.hasPrefix("wine ") || lowered.contains("wine mono") || lowered.contains("wine gecko")
                || lowered.contains("microsoft visual c++") || lowered.contains("redistributable")
                || lowered.contains(".net framework") || lowered.contains("steamworks common") {
                return
            }
            guard seenNames.insert(lowered).inserted else { return }
            var resolvedPath = driveC.path
            if let loc = currentInstallLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty {
                let relative = loc
                    .replacingOccurrences(of: "C:\\\\", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "C:\\", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "\\\\", with: "/")
                    .replacingOccurrences(of: "\\", with: "/")
                if let safeDir = safePayload(relative, in: driveC), isDirectory(safeDir), hasPayload(safeDir) {
                    resolvedPath = safeDir.path
                } else {
                    return
                }
            } else {
                return
            }
            let slug = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            let version = (currentVersion?.isEmpty == false) ? currentVersion! : "Unknown"
            apps.append(ApplicationCandidate(
                inventoryID: "wine-app:\(bottleRoot.path):\(slug)",
                path: resolvedPath,
                name: rawName,
                bundleIdentifier: "wine-app:\(slug)",
                displayVersion: version,
                buildVersion: version,
                teamIdentifier: nil,
                parentInventoryID: bottleInventoryID,
                parentManagerBundleIdentifier: managerBundleID,
                isSystemApplication: false,
                info: [
                    "DiscoverySource": sourceName,
                    "DiscoveryRole": "bottle-app",
                    "DiscoveryPlatform": "Windows",
                    "ParentDisplayName": bottleName
                ],
                kind: .application
            ))
        }

        for line in lines {
            if line.hasPrefix("[") {
                flushEntry()
                let lowerHeader = line.lowercased()
                inUninstallKey = lowerHeader.contains("currentversion\\\\uninstall\\\\")
                    || lowerHeader.contains("currentversion\\uninstall\\")
                continue
            }
            guard inUninstallKey else { continue }
            if let value = parseRegistryString(line: line, key: "DisplayName") {
                currentName = value
            } else if let value = parseRegistryString(line: line, key: "DisplayVersion") {
                currentVersion = value
            } else if let value = parseRegistryString(line: line, key: "InstallLocation") {
                currentInstallLocation = value
            }
        }
        flushEntry()
        return Array(apps.prefix(100))
    }

    private static func parseRegistryString(line: String, key: String) -> String? {
        let prefix = "\"\(key)\"=\""
        guard line.hasPrefix(prefix), line.hasSuffix("\"") else { return nil }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(before: line.endIndex)
        guard start < end else { return nil }
        return String(line[start..<end]).replacingOccurrences(of: "\\\"", with: "\"")
    }

    func virtualMachines(control: ScanControl, diagnostics: inout [ScanDiagnostic]) -> [ApplicationCandidate] {
        var vms: [ApplicationCandidate] = []
        // 1. UTM (*.utm bundles in ~/Library/Containers/com.utmapp.UTM/Data/Documents)
        let utmRoot = home.appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents")
        for bundle in Self.children(utmRoot, source: "UTM", diagnostics: &diagnostics, operation: .utmBundleListing)
            where bundle.pathExtension.lowercased() == "utm" {
            if control.shouldStop { break }
            let configURL = bundle.appendingPathComponent("config.plist")
            guard let data = Self.read(configURL, source: "UTM", diagnostics: &diagnostics, operation: .utmConfiguration),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let info = plist["Information"] as? [String: Any]
            let system = plist["System"] as? [String: Any]
            let name = Self.text(info ?? [:], "Name") ?? bundle.deletingPathExtension().lastPathComponent
            let arch = Self.text(system ?? [:], "Architecture") ?? "VM"
            let canonical = bundle.resolvingSymlinksInPath()
            vms.append(ApplicationCandidate(
                inventoryID: "vm:utm:\(canonical.path)",
                path: canonical.path,
                name: name,
                bundleIdentifier: "utm-vm:\(name.lowercased())",
                displayVersion: arch,
                buildVersion: arch,
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "com.utmapp.UTM",
                isSystemApplication: false,
                info: [
                    "DiscoverySource": "UTM",
                    "DiscoveryRole": "vm",
                    "VMArchitecture": arch
                ],
                kind: .virtualMachine
            ))
        }

        // 2. VMware Fusion (*.vmwarevm bundles in ~/Virtual Machines.localized and ~/Virtual Machines)
        for vmwareRoot in [home.appendingPathComponent("Virtual Machines.localized"),
                           home.appendingPathComponent("Virtual Machines")] {
            for bundle in Self.children(vmwareRoot, source: "VMware Fusion", diagnostics: &diagnostics)
                where bundle.pathExtension.lowercased() == "vmwarevm" {
                if control.shouldStop { break }
                let children = Self.children(bundle, source: "VMware Fusion", diagnostics: &diagnostics)
                guard let vmxURL = children.first(where: { $0.pathExtension.lowercased() == "vmx" }),
                      let data = Self.read(vmxURL, source: "VMware Fusion", diagnostics: &diagnostics),
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
                let name = Self.parseKeyValue(in: text, key: "displayName") ?? bundle.deletingPathExtension().lastPathComponent
                let guestOS = Self.parseKeyValue(in: text, key: "guestOS") ?? "Guest OS"
                let canonical = bundle.resolvingSymlinksInPath()
                vms.append(ApplicationCandidate(
                    inventoryID: "vm:vmware:\(canonical.path)",
                    path: canonical.path,
                    name: name,
                    bundleIdentifier: "vmware-vm:\(name.lowercased())",
                    displayVersion: guestOS == "Guest OS" ? String(localized: "Guest OS", bundle: AppL10n.bundle, locale: AppL10n.locale) : guestOS,
                    buildVersion: guestOS,
                    teamIdentifier: nil,
                    parentManagerBundleIdentifier: "com.vmware.fusion",
                    isSystemApplication: false,
                    info: [
                        "DiscoverySource": "VMware Fusion",
                        "DiscoveryRole": "vm",
                        "VMGuestOS": guestOS
                    ],
                    kind: .virtualMachine
                ))
            }
        }

        // 3. Parallels Desktop (*.pvm bundles in ~/Parallels)
        let parallelsRoot = home.appendingPathComponent("Parallels")
        for bundle in Self.children(parallelsRoot, source: "Parallels Desktop", diagnostics: &diagnostics)
            where bundle.pathExtension.lowercased() == "pvm" {
            if control.shouldStop { break }
            let configURL = bundle.appendingPathComponent("config.pvs")
            guard FileManager.default.fileExists(atPath: configURL.path),
                  let data = Self.read(configURL, source: "Parallels Desktop", diagnostics: &diagnostics),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let name = Self.extractXMLTag("VmName", from: xml) ?? bundle.deletingPathExtension().lastPathComponent
            let guestOS = Self.extractXMLTag("GuestOsVersion", from: xml) ?? "Guest OS"
            let canonical = bundle.resolvingSymlinksInPath()
            vms.append(ApplicationCandidate(
                inventoryID: "vm:parallels:\(canonical.path)",
                path: canonical.path,
                name: name,
                bundleIdentifier: "parallels-vm:\(name.lowercased())",
                displayVersion: guestOS == "Guest OS" ? String(localized: "Guest OS", bundle: AppL10n.bundle, locale: AppL10n.locale) : guestOS,
                buildVersion: guestOS,
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "com.parallels.desktop.console",
                isSystemApplication: false,
                info: [
                    "DiscoverySource": "Parallels Desktop",
                    "DiscoveryRole": "vm",
                    "VMGuestOS": guestOS
                ],
                kind: .virtualMachine
            ))
        }

        // 4. VirtualBox (~/VirtualBox VMs/*/*.vbox)
        let vboxRoot = home.appendingPathComponent("VirtualBox VMs")
        for folder in Self.children(vboxRoot, source: "VirtualBox", diagnostics: &diagnostics) where Self.isDirectory(folder) {
            if control.shouldStop { break }
            let children = Self.children(folder, source: "VirtualBox", diagnostics: &diagnostics)
            guard let vboxFile = children.first(where: { $0.pathExtension.lowercased() == "vbox" }),
                  let data = Self.read(vboxFile, source: "VirtualBox", diagnostics: &diagnostics),
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let name = Self.extractXMLAttribute("name", inTag: "Machine", from: xml) ?? folder.lastPathComponent
            let osType = Self.extractXMLAttribute("OSType", inTag: "Machine", from: xml) ?? "Guest OS"
            let canonical = folder.resolvingSymlinksInPath()
            vms.append(ApplicationCandidate(
                inventoryID: "vm:virtualbox:\(canonical.path)",
                path: canonical.path,
                name: name,
                bundleIdentifier: "virtualbox-vm:\(name.lowercased())",
                displayVersion: osType == "Guest OS" ? String(localized: "Guest OS", bundle: AppL10n.bundle, locale: AppL10n.locale) : osType,
                buildVersion: osType,
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "org.virtualbox.app.VirtualBox",
                isSystemApplication: false,
                info: [
                    "DiscoverySource": "VirtualBox",
                    "DiscoveryRole": "vm",
                    "VMGuestOS": osType
                ],
                kind: .virtualMachine
            ))
        }

        // 5. Lima (~/.lima/*/lima.yaml)
        let limaRoot = home.appendingPathComponent(".lima")
        for folder in Self.children(limaRoot, source: "Lima", diagnostics: &diagnostics)
            where Self.isDirectory(folder) && !folder.lastPathComponent.hasPrefix("_") {
            if control.shouldStop { break }
            let yamlURL = folder.appendingPathComponent("lima.yaml")
            guard FileManager.default.fileExists(atPath: yamlURL.path) else { continue }
            let canonical = folder.resolvingSymlinksInPath()
            let name = folder.lastPathComponent
            vms.append(ApplicationCandidate(
                inventoryID: "vm:lima:\(canonical.path)",
                path: canonical.path,
                name: "Lima · \(name)",
                bundleIdentifier: "lima-vm:\(name.lowercased())",
                displayVersion: String(localized: "Linux VM", bundle: AppL10n.bundle, locale: AppL10n.locale),
                buildVersion: "",
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "io.lima-vm.lima",
                isSystemApplication: false,
                info: [
                    "DiscoverySource": "Lima",
                    "DiscoveryRole": "vm"
                ],
                kind: .virtualMachine
            ))
        }

        // 6. Colima (~/.colima/*/colima.yaml)
        let colimaRoot = home.appendingPathComponent(".colima")
        for folder in Self.children(colimaRoot, source: "Colima", diagnostics: &diagnostics)
            where Self.isDirectory(folder) && !folder.lastPathComponent.hasPrefix("_") {
            if control.shouldStop { break }
            let yamlURL = folder.appendingPathComponent("colima.yaml")
            guard FileManager.default.fileExists(atPath: yamlURL.path) else { continue }
            let canonical = folder.resolvingSymlinksInPath()
            let name = folder.lastPathComponent
            vms.append(ApplicationCandidate(
                inventoryID: "vm:colima:\(canonical.path)",
                path: canonical.path,
                name: "Colima · \(name)",
                bundleIdentifier: "colima-vm:\(name.lowercased())",
                displayVersion: String(localized: "Container VM", bundle: AppL10n.bundle, locale: AppL10n.locale),
                buildVersion: "",
                teamIdentifier: nil,
                parentManagerBundleIdentifier: "io.colima.colima",
                isSystemApplication: false,
                info: [
                    "DiscoverySource": "Colima",
                    "DiscoveryRole": "vm"
                ],
                kind: .virtualMachine
            ))
        }

        return vms
    }

    private func additionalGameLibraries(
        support: URL,
        control: ScanControl,
        diagnostics: inout [ScanDiagnostic]
    ) -> [ApplicationCandidate] {
        var games: [ApplicationCandidate] = []

        // 1. Modrinth App profiles
        for modrinthRoot in [
            support.appendingPathComponent("ModrinthApp/profiles"),
            support.appendingPathComponent("com.modrinth.theseus/profiles")
        ] {
            for profileDir in Self.children(modrinthRoot, source: "Modrinth", diagnostics: &diagnostics)
                where Self.isDirectory(profileDir) {
                if control.shouldStop { break }
                let profileJSON = profileDir.appendingPathComponent("profile.json")
                guard let data = Self.read(profileJSON, source: "Modrinth", diagnostics: &diagnostics),
                      let obj = try? Self.object(data) else { continue }
                let name = Self.text(obj, "name") ?? profileDir.lastPathComponent
                let gameVersion = Self.text(obj, "game_version")
                    ?? (obj["metadata"] as? [String: Any]).flatMap { Self.text($0, "game_version") }
                    ?? "Unknown"
                games.append(Self.game(
                    id: profileDir.lastPathComponent,
                    root: profileDir,
                    name: name,
                    version: gameVersion,
                    platform: .modrinth,
                    manager: "com.modrinth.theseus",
                    source: "Modrinth"
                ))
            }
        }

        // 2. CurseForge Minecraft instances
        let curseRoot = home.appendingPathComponent("Documents/Curse/Minecraft/Instances")
        for instanceDir in Self.children(curseRoot, source: "CurseForge", diagnostics: &diagnostics)
            where Self.isDirectory(instanceDir) {
            if control.shouldStop { break }
            let instanceJSON = instanceDir.appendingPathComponent("minecraftinstance.json")
            guard let data = Self.read(instanceJSON, source: "CurseForge", diagnostics: &diagnostics),
                  let obj = try? Self.object(data) else { continue }
            let name = Self.text(obj, "name") ?? instanceDir.lastPathComponent
            let gameVersion = Self.text(obj, "gameVersion") ?? "Unknown"
            games.append(Self.game(
                id: instanceDir.lastPathComponent,
                root: instanceDir,
                name: name,
                version: gameVersion,
                platform: .curseForge,
                manager: "com.overwolf.curseforge",
                source: "CurseForge"
            ))
        }

        // 3. itch.io installed apps
        let itchRoot = support.appendingPathComponent("itch/apps")
        for appDir in Self.children(itchRoot, source: "itch.io", diagnostics: &diagnostics)
            where Self.isDirectory(appDir) {
            if control.shouldStop { break }
            guard Self.hasPayload(appDir) else { continue }
            let name = appDir.lastPathComponent
            games.append(Self.game(
                id: name.lowercased(),
                root: appDir,
                name: name,
                version: "Unknown",
                platform: .itch,
                manager: "io.itch.mac",
                source: "itch.io"
            ))
        }

        // 4. Battle.net games with .build.info in applicationRoots
        for appRoot in applicationRoots {
            for folder in Self.children(appRoot, source: "Battle.net", diagnostics: &diagnostics)
                where Self.isDirectory(folder) && folder.pathExtension.isEmpty {
                if control.shouldStop { break }
                let buildInfo = folder.appendingPathComponent(".build.info")
                guard FileManager.default.fileExists(atPath: buildInfo.path),
                      let data = Self.read(buildInfo, source: "Battle.net", diagnostics: &diagnostics),
                      let text = String(data: data, encoding: .utf8),
                      Self.hasPayload(folder) else { continue }
                let version = Self.parseBattleNetBuildInfoVersion(text) ?? "Unknown"
                let name = folder.lastPathComponent
                games.append(Self.game(
                    id: name.lowercased().replacingOccurrences(of: " ", with: "-"),
                    root: folder,
                    name: name,
                    version: version,
                    platform: .battleNet,
                    manager: "net.battle.app",
                    source: "Battle.net"
                ))
            }
        }

        // 5. Riot Client Metadata
        let riotMetadata = shared.appendingPathComponent("Riot Games/Metadata")
        for productDir in Self.children(riotMetadata, source: "Riot Client", diagnostics: &diagnostics)
            where Self.isDirectory(productDir) {
            if control.shouldStop { break }
            let settingsFiles = Self.children(productDir, source: "Riot Client", diagnostics: &diagnostics)
                .filter { $0.lastPathComponent.hasSuffix(".product_settings.yaml") }
            guard let settingsFile = settingsFiles.first,
                  let data = Self.read(settingsFile, source: "Riot Client", diagnostics: &diagnostics),
                  let yaml = String(data: data, encoding: .utf8),
                  let installPath = Self.parseYAMLString(in: yaml, key: "product_install_full_path"),
                  let root = Self.absoluteDirectory(installPath),
                  Self.hasPayload(root) else { continue }
            let name = root.deletingPathExtension().lastPathComponent
            games.append(Self.game(
                id: productDir.lastPathComponent,
                root: root,
                name: name,
                version: "Unknown",
                platform: .riot,
                manager: "com.riotgames.RiotGames.RiotClient",
                source: "Riot Client"
            ))
        }

        return games
    }

    private static func parseKeyValue(in text: String, key: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func parseYAMLString(in text: String, key: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key + ":") else { continue }
            let raw = trimmed.dropFirst((key + ":").count).trimmingCharacters(in: .whitespaces)
            let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !clean.isEmpty { return clean }
        }
        return nil
    }

    private static func extractXMLTag(_ tag: String, from xml: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let startRange = xml.range(of: open),
              let endRange = xml.range(of: close, range: startRange.upperBound..<xml.endIndex) else { return nil }
        let value = String(xml[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func extractXMLAttribute(_ attribute: String, inTag tag: String, from xml: String) -> String? {
        guard let tagStart = xml.range(of: "<\(tag) "),
              let tagEnd = xml.range(of: ">", range: tagStart.upperBound..<xml.endIndex) else { return nil }
        let header = String(xml[tagStart.upperBound..<tagEnd.lowerBound])
        let needle = "\(attribute)=\""
        guard let attrStart = header.range(of: needle),
              let attrEnd = header.range(of: "\"", range: attrStart.upperBound..<header.endIndex) else { return nil }
        let value = String(header[attrStart.upperBound..<attrEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseBattleNetBuildInfoVersion(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return nil }
        let headers = lines[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let versionIndex = headers.firstIndex(where: { $0.lowercased().hasPrefix("version!") }) else { return nil }
        let values = lines[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard versionIndex < values.count else { return nil }
        let version = values[versionIndex].trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    private static func game(id: String, root: URL, name: String, version: String,
                             platform: GamePlatformKind, manager: String, source: String) -> ApplicationCandidate {
        let canonical = root.resolvingSymlinksInPath()
        return ApplicationCandidate(inventoryID: "game:\(platform.rawValue):\(id):\(canonical.path)",
            path: canonical.path, name: name, bundleIdentifier: "\(platform.rawValue)-game:\(id)",
            displayVersion: version, buildVersion: version, teamIdentifier: nil,
            parentManagerBundleIdentifier: manager, isSystemApplication: false,
            info: ["DiscoverySource": source, "DiscoveryRole": "game", "StoreGameID": id, "ManifestVersion": version],
            kind: .game, gamePlatform: platform)
    }

    static func safePayload(_ relative: String, in root: URL) -> URL? {
        let path = relative.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
              !path.split(separator: "/").contains("..") else { return nil }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(canonicalRoot + "/"), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func absoluteDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return isDirectory(root) ? root : nil
    }

    static func walk(root: URL, maximumDepth: Int = 6, maximumEntries: Int = 10000, control: ScanControl,
                     source: String, diagnostics: inout [ScanDiagnostic]) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        if root.pathExtension.lowercased() == "app" { return [root] }
        var pending: [(URL, Int)] = [(root.resolvingSymlinksInPath(), 0)]
        var visited = Set<String>()
        var files: [URL] = []
        var entries = 0
        while let (directory, depth) = pending.popLast(), !control.shouldStop {
            guard visited.insert(directory.path).inserted else { continue }
            for url in children(directory, source: source, diagnostics: &diagnostics) {
                if control.shouldStop { break }
                entries += 1
                guard entries <= maximumEntries else {
                    diagnostics.append(.init(source: source, reason: .outputTooLarge)); return files
                }
                // Nested symlinks can escape a selected folder or cycle; roots may
                // themselves be aliases, but traversal never follows child links.
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
                if url.pathExtension.lowercased() == "app" { files.append(url); continue }
                if isDirectory(url) {
                    if depth < maximumDepth { pending.append((url, depth + 1)) }
                    else { diagnostics.append(.init(source: source, reason: .outputTooLarge)) }
                } else { files.append(url) }
            }
        }
        return files
    }

    static func children(_ root: URL, source: String, diagnostics: inout [ScanDiagnostic],
                         operation: ScanDiagnostic.Operation? = nil) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
        } catch { diagnostics.append(.init(source: source, reason: .unreadable, operation: operation)); return [] }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func read(_ url: URL, source: String, diagnostics: inout [ScanDiagnostic],
                     operation: ScanDiagnostic.Operation? = nil) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue <= 4 * 1024 * 1024 else {
            diagnostics.append(.init(source: source, reason: .outputTooLarge, operation: operation)); return nil
        }
        do { return try Data(contentsOf: url) }
        catch { diagnostics.append(.init(source: source, reason: .unreadable, operation: operation)); return nil }
    }

    static func diagnostic(_ error: Error, source: String) -> ScanDiagnostic {
        if case PackageCommandError.failed(let reason) = error { return .init(source: source, reason: reason) }
        return .init(source: source, reason: .invalidOutput)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PackageCommandError.failed(.invalidOutput)
        }
        return object
    }

    private static func text(_ row: [String: Any], _ key: String) -> String? {
        guard let value = row[key] as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func installedBundle(_ url: URL) -> Bool {
        guard let info = ApplicationBundleMetadataReader.infoDictionary(at: url),
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), !executable.contains("\\"), executable != ".", executable != ".." else { return false }
        return safePayload("Contents/MacOS/" + executable, in: url) != nil
            || safePayload("WrappedBundle/" + executable, in: url) != nil
    }

    private static func hasPayload(_ root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for (index, value) in enumerator.enumerated() {
            if index >= 500 { return false }
            guard let url = value as? URL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "app", installedBundle(url) { return true }
            if values.isRegularFile == true, !url.lastPathComponent.lowercased().hasPrefix("unins"),
               ["exe", "dylib", "dll", "pak"].contains(url.pathExtension.lowercased()) { return true }
        }
        return false
    }
}
