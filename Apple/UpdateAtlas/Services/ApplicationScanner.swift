import Foundation
import Security

struct ApplicationScanner: Sendable {
    private var activeControl: ScanControl?
    private let packageScanner = PackageInventoryScanner()
    private let directInstallScanner = DirectInstallScanner()

    func scan(includeSystemApplications: Bool = InventorySettings.defaultIncludeSystemApplications) async -> [ApplicationCandidate] {
        await scanWithFindings(includeSystemApplications: includeSystemApplications).candidates
    }

    func scanWithFindings(
        includeSystemApplications: Bool = InventorySettings.defaultIncludeSystemApplications,
        control: ScanControl = ScanControl(),
        discovery: DiscoveryConfiguration = .current(),
        offline: Bool = false,
        progress: @escaping @Sendable (ScanPhase) -> Void = { _ in },
        activity: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> ApplicationScanResult {
        let task = Task.detached(priority: .userInitiated) {
            var scoped = self
            scoped.activeControl = control
            return scoped.scanSynchronously(includeSystemApplications: includeSystemApplications, control: control, discovery: discovery, offline: offline, progress: progress, activity: activity)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { control.cancel() }
    }

    private func scanSynchronously(includeSystemApplications: Bool, control: ScanControl,
                                   discovery: DiscoveryConfiguration, offline: Bool,
                                   progress: @Sendable (ScanPhase) -> Void,
                                   activity: @Sendable (String) -> Void) -> ApplicationScanResult {
        progress(.packages)
        let packageSnapshot = packageScanner.scan(control: control, offline: offline, progress: activity)
        var diagnostics = packageSnapshot.diagnostics
        progress(.applications)
        var discovered: [String: ApplicationCandidate] = [:]

        for root in standardApplicationRoots(includeSystemApplications: includeSystemApplications) {
            if control.shouldStop { break }
            var bundles: [URL] = []
            if FileManager.default.fileExists(atPath: root.path) {
                do { bundles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "app" }
                } catch { diagnostics.append(.init(source: "Applications #" + String(diagnostics.count + 1), reason: .unreadable)) }
            }
            for appURL in bundles {
                if control.shouldStop { break }
                if let candidate = makeCandidate(
                    url: appURL,
                    parentManagerBundleIdentifier: nil,
                    caskApplicationsByPath: packageSnapshot.caskApplicationsByPath
                ) {
                    discovered[candidate.inventoryID] = candidate
                }
            }
            for appURL in Self.vendorUtilityBundles(in: root) {
                if let candidate = makeCandidate(
                    url: appURL,
                    parentManagerBundleIdentifier: nil,
                    caskApplicationsByPath: packageSnapshot.caskApplicationsByPath
                ) {
                    discovered[candidate.inventoryID] = candidate
                }
            }
        }

        var canonicalBundles = Set<String>()
        for candidate in discovered.values.sorted(by: { $0.inventoryID < $1.inventoryID }) {
            let canonical = URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath().path
            if !canonicalBundles.insert(canonical).inserted { discovered.removeValue(forKey: candidate.inventoryID) }
        }

        if control.shouldStop {
            return ApplicationScanResult(candidates: Array(discovered.values) + packageSnapshot.candidates,
                                         directInstallRemnants: [], diagnostics: diagnostics)
        }
        if let visualStudioCode = discovered.values.first(where: {
            $0.bundleIdentifier == "com.microsoft.VSCode"
        }) {
            for candidate in discoverVisualStudioCodeExtensions(
                hostVersion: visualStudioCode.displayVersion,
                parentInventoryID: visualStudioCode.inventoryID
            ) {
                discovered[candidate.inventoryID] = candidate
            }
        }

        let unityHubID = discovered.values.first { $0.bundleIdentifier == "com.unity3d.unityhub" }?.inventoryID
        for candidate in discoverUnityEditors(
            parentInventoryID: unityHubID,
            caskApplicationsByPath: packageSnapshot.caskApplicationsByPath
        ) {
            discovered[candidate.inventoryID] = candidate
        }

        activity(String(localized: "Discovering games and managed components…", bundle: AppL10n.bundle, locale: AppL10n.locale))
        let steamID = discovered.values.first { $0.bundleIdentifier == "com.valvesoftware.steam" }?.inventoryID
        let managedGames = discoverManagedGames(
            steamParentInventoryID: steamID,
            caskApplicationsByPath: packageSnapshot.caskApplicationsByPath
        )
        let installedSteamAppIDs: Set<String> = Set(managedGames.compactMap { candidate -> String? in
            guard candidate.gamePlatform == .steam else { return nil }
            return candidate.info["SteamAppID"]
        })
        let shortcuts = discovered.compactMap { key, candidate -> (String, ApplicationCandidate, String)? in
            guard let appID = steamShortcutAppID(for: candidate) else { return nil }
            return (key, candidate, appID)
        }
        for (oldKey, candidate, appID) in shortcuts {
            // Steam leaves generated launchers behind after a game is uninstalled.
            // A shortcut identifies a title, but only a live Steam manifest plus its
            // install directory proves that the game is currently installed.
            discovered.removeValue(forKey: oldKey)
            guard SteamInventoryReconciler.isInstalled(
                shortcutAppID: appID,
                manifestAppIDs: installedSteamAppIDs
            ) else { continue }
            let shortcut = ApplicationCandidate(
                inventoryID: "game:steam:\(appID)",
                path: candidate.path,
                name: candidate.name,
                bundleIdentifier: "steam-app:\(appID)",
                displayVersion: String(localized: "Steam Shortcut", bundle: AppL10n.bundle, locale: AppL10n.locale),
                buildVersion: "",
                teamIdentifier: candidate.teamIdentifier,
                parentInventoryID: steamID,
                parentManagerBundleIdentifier: "com.valvesoftware.steam",
                isSystemApplication: false,
                info: candidate.info.merging([
                    "SteamAppID": appID,
                    "SteamShortcut": "true"
                ]) { current, _ in current },
                kind: .game,
                gamePlatform: .steam
            )
            discovered[shortcut.inventoryID] = shortcut
        }
        for candidate in managedGames {
            discovered[candidate.inventoryID] = candidate
        }

        let prismID = discovered.values.first { $0.bundleIdentifier == "org.prismlauncher.PrismLauncher" }?.inventoryID
        for candidate in discoverPrismLauncherInstances(parentInventoryID: prismID) {
            discovered[candidate.inventoryID] = candidate
        }

        let comfyID = discovered.values.first { $0.bundleIdentifier == "com.todesktop.241012ess7yxs0e" }?.inventoryID
        for candidate in discoverComfyUIInstallations(parentInventoryID: comfyID) {
            discovered[candidate.inventoryID] = candidate
        }

        let hermesID = discovered.values.first {
            ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"].contains($0.bundleIdentifier)
        }?.inventoryID
        if let runtime = HermesRuntimeMetadata.sourceCandidate(parentInventoryID: hermesID) {
            discovered[runtime.inventoryID] = runtime
        }

        for candidate in packageSnapshot.candidates {
            discovered[candidate.inventoryID] = candidate
        }

        activity(String(localized: "Discovering additional libraries and application folders…", bundle: AppL10n.bundle, locale: AppL10n.locale))
        let additional = LocalDiscoveryProvider().scan(configuration: discovery, control: control)
        diagnostics += additional.diagnostics
        for bundle in additional.bundles {
            guard let candidate = makeCandidate(url: bundle.url,
                parentManagerBundleIdentifier: bundle.manager,
                caskApplicationsByPath: packageSnapshot.caskApplicationsByPath) else { continue }
            let canonical = URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath().path
            let existing = discovered.values.first {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == canonical
            }
            // Preserve existing installation identities and Homebrew ownership.
            let original = existing ?? candidate
            let manager = original.packageProvenance == nil ? (bundle.manager ?? original.parentManagerBundleIdentifier) : original.parentManagerBundleIdentifier
            let parentID = discovered.values.first { $0.bundleIdentifier == manager }?.inventoryID
            discovered[original.inventoryID] = Self.withDiscovery(original, manager: manager,
                parentID: parentID ?? original.parentInventoryID, info: ["DiscoverySource": bundle.source])
        }
        discovered = Self.reconcileAdditional(additional.candidates, with: discovered)
        if discovery.includeDocker && offline {
            diagnostics.append(.init(source: "Docker", reason: .offlineSkipped))
        }
        if discovery.includeDocker && !offline {
            activity(String(localized: "Reading the current Docker connection…", bundle: AppL10n.bundle, locale: AppL10n.locale))
            let dockerParent = discovered.values.first { $0.bundleIdentifier == "com.docker.docker" }
                ?? discovered.values.first { $0.bundleIdentifier == "dev.kdrag0n.OrbStack" }
            let docker = DockerDiscoveryProvider().scan(enabled: true, parent: dockerParent, control: control)
            diagnostics += docker.diagnostics
            for candidate in docker.candidates { discovered[candidate.inventoryID] = candidate }
        }

        activity(String(localized: "Discovering standalone command-line tools…", bundle: AppL10n.bundle, locale: AppL10n.locale))
        let directInstallSnapshot = directInstallScanner.scan(
            packageCandidates: packageSnapshot.candidates,
            applicationCandidates: Array(discovered.values)
        )
        for candidate in directInstallSnapshot.candidates {
            discovered[candidate.inventoryID] = candidate
        }

        return ApplicationScanResult(
            candidates: discovered.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            directInstallRemnants: directInstallSnapshot.remnants,
            diagnostics: diagnostics
        )
    }

    static func reconcileAdditional(_ additional: [ApplicationCandidate], with existing: [String: ApplicationCandidate]) -> [String: ApplicationCandidate] {
        var discovered = existing
        let sourcePriority = ["GOG manifest": 0, "GOG Galaxy": 1, "Epic Games": 2, "Heroic": 3]
        for candidate in additional.sorted(by: {
            let leftBottleApp = $0.info["DiscoveryRole"] == "bottle-app" ? 1 : 0
            let rightBottleApp = $1.info["DiscoveryRole"] == "bottle-app" ? 1 : 0
            if leftBottleApp != rightBottleApp { return leftBottleApp < rightBottleApp }
            let left = sourcePriority[$0.info["DiscoverySource"] ?? ""] ?? 0
            let right = sourcePriority[$1.info["DiscoverySource"] ?? ""] ?? 0
            return left == right ? $0.inventoryID < $1.inventoryID : left < right
        }) {
            let root = URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath().path
            if discovered.values.contains(where: { existing in
                guard existing.packageProvenance != nil else { return false }
                let path = URL(fileURLWithPath: existing.path).resolvingSymlinksInPath().path
                return path == root || (candidate.kind == .game && path.hasPrefix(root + "/") && path.hasSuffix(".app"))
            }) { continue }
            let duplicates = discovered.values.filter { existing in
                let path = URL(fileURLWithPath: existing.path).resolvingSymlinksInPath().path
                return path == root || (candidate.kind == .game && path.hasPrefix(root + "/")
                    && existing.path.hasSuffix(".app") && existing.packageProvenance == nil)
            }.sorted { $0.inventoryID < $1.inventoryID }
            // Existing bundle identities remain stable when a manifest enriches it.
            let identity = duplicates.first?.inventoryID ?? candidate.inventoryID
            for duplicate in duplicates { discovered.removeValue(forKey: duplicate.inventoryID) }
            let parentID = candidate.parentInventoryID.flatMap { discovered[$0] != nil ? $0 : nil }
                ?? discovered.values.first {
                    $0.bundleIdentifier == candidate.parentManagerBundleIdentifier
                        || (candidate.parentManagerBundleIdentifier == "io.lima-vm.lima" && $0.packageProvenance?.identifier == "lima")
                        || (candidate.parentManagerBundleIdentifier == "io.colima.colima" && $0.packageProvenance?.identifier == "colima")
                }?.inventoryID
            let native = duplicates.first { $0.path.hasSuffix(".app") }
            let enriched = native.map { original in
                ApplicationCandidate(inventoryID: identity, path: original.path, name: original.name,
                    bundleIdentifier: original.bundleIdentifier,
                    displayVersion: original.displayVersion == "Unknown" ? candidate.displayVersion : original.displayVersion,
                    buildVersion: original.displayVersion == "Unknown" ? candidate.buildVersion : original.buildVersion,
                    teamIdentifier: original.teamIdentifier, parentManagerBundleIdentifier: candidate.parentManagerBundleIdentifier,
                    isSystemApplication: false, info: original.info.merging(candidate.info) { _, new in new },
                    kind: candidate.kind, gamePlatform: candidate.gamePlatform)
            } ?? candidate
            discovered[identity] = Self.withDiscovery(enriched, inventoryID: identity,
                manager: candidate.parentManagerBundleIdentifier, parentID: parentID, info: [:])
        }
        return discovered
    }

    static func withDiscovery(_ candidate: ApplicationCandidate, inventoryID: String? = nil,
                              manager: String?, parentID: String?, info: [String: String]) -> ApplicationCandidate {
        ApplicationCandidate(inventoryID: inventoryID ?? candidate.inventoryID, path: candidate.path,
            name: candidate.name, bundleIdentifier: candidate.bundleIdentifier,
            displayVersion: candidate.displayVersion, buildVersion: candidate.buildVersion,
            teamIdentifier: candidate.teamIdentifier, parentInventoryID: parentID,
            parentManagerBundleIdentifier: manager, isSystemApplication: candidate.isSystemApplication,
            info: candidate.info.merging(info) { _, new in new }, kind: candidate.kind,
            gamePlatform: candidate.gamePlatform, packageProvenance: candidate.packageProvenance)
    }

    private func standardApplicationRoots(includeSystemApplications: Bool) -> [URL] {
        let fileManager = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)
        ]

        if includeSystemApplications {
            roots.append(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
            roots.append(URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true))
        }

        if let userApplications = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApplications)
        }

        return roots
    }

    private func applicationBundles(at root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.filter { $0.pathExtension.lowercased() == "app" }
    }

    /// Vendor installers commonly put their main app one or two levels under
    /// Applications. Probe reviewed paths only, so unrelated registration tools,
    /// driver helpers, and nested bundles do not become top-level applications.
    static func vendorUtilityBundles(in applicationRoot: URL) -> [URL] {
        let reviewedPaths = [
            "Canon Utilities/IJ Scan Utility/Canon IJ Scan Utility2.app",
            "DDPM/DDPM.app"
        ]
        return reviewedPaths.compactMap { relativePath in
            let url = applicationRoot.appendingPathComponent(relativePath, isDirectory: true)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return url
        }
    }

    private func discoverUnityEditors(
        parentInventoryID: String?,
        caskApplicationsByPath: [String: PackageProvenance]
    ) -> [ApplicationCandidate] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications/Unity/Hub/Editor", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Unity/Hub/Editor", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/UnityHub/Editor", isDirectory: true)
        ]

        var candidates = roots.flatMap { root -> [ApplicationCandidate] in
            guard let versions = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            return versions.flatMap { versionDirectory -> [ApplicationCandidate] in
                guard activeControl?.shouldStop != true else { return [] }
                let directApp = versionDirectory.appendingPathComponent("Unity.app", isDirectory: true)
                let editorApp = versionDirectory
                    .appendingPathComponent("Editor", isDirectory: true)
                    .appendingPathComponent("Unity.app", isDirectory: true)
                let appURL = fileManager.fileExists(atPath: directApp.path) ? directApp : editorApp
                guard let editor = makeCandidate(
                    url: appURL,
                    parentInventoryID: parentInventoryID,
                    parentManagerBundleIdentifier: "com.unity3d.unityhub",
                    caskApplicationsByPath: caskApplicationsByPath
                ) else { return [] }

                var result = [editor]
                let moduleRoots = [
                    appURL.appendingPathComponent("Contents/PlaybackEngines", isDirectory: true),
                    versionDirectory.appendingPathComponent("PlaybackEngines", isDirectory: true),
                    versionDirectory.appendingPathComponent("Editor/Data/PlaybackEngines", isDirectory: true)
                ]
                for playbackEngines in uniqueExistingDirectories(moduleRoots) {
                    if let modules = try? fileManager.contentsOfDirectory(
                        at: playbackEngines,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        result += modules.map { moduleURL in
                        let moduleName = Self.unityModuleDisplayName(moduleURL.lastPathComponent)
                        return ApplicationCandidate(
                            inventoryID: "module:unity:\(editor.inventoryID):\(moduleURL.lastPathComponent)",
                            path: moduleURL.path,
                            name: moduleName,
                            bundleIdentifier: "unity-module:\(moduleURL.lastPathComponent)",
                            displayVersion: editor.displayVersion,
                            buildVersion: editor.buildVersion,
                            teamIdentifier: editor.teamIdentifier,
                            parentInventoryID: editor.inventoryID,
                            parentManagerBundleIdentifier: "com.unity3d.unityhub",
                            isSystemApplication: false,
                            info: [
                                "ManagedComponentType": "unity-module",
                                "ParentDisplayName": editor.name
                            ],
                            kind: .module
                        )
                    }
                    }
                }
                return result
            }
        }
        let registryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UnityHub/editors-v2.json")
        if let data = try? Data(contentsOf: registryURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["data"] as? [[String: Any]] {
            let registeredPaths = rows.compactMap { row in
                (row["location"] as? String) ?? (row["path"] as? String)
            }
            for path in registeredPaths where !candidates.contains(where: { $0.path.hasPrefix(path) }) {
                let base = URL(fileURLWithPath: path, isDirectory: true)
                let appOptions = base.pathExtension == "app"
                    ? [base]
                    : [base.appendingPathComponent("Unity.app"), base.appendingPathComponent("Editor/Unity.app")]
                guard let appURL = appOptions.first(where: { fileManager.fileExists(atPath: $0.path) }) else { continue }
                if let editor = makeCandidate(
                    url: appURL,
                    parentInventoryID: parentInventoryID,
                    parentManagerBundleIdentifier: "com.unity3d.unityhub",
                    caskApplicationsByPath: caskApplicationsByPath
                ) {
                    candidates.append(editor)
                    let moduleRoots = [
                        appURL.appendingPathComponent("Contents/PlaybackEngines", isDirectory: true),
                        base.appendingPathComponent("PlaybackEngines", isDirectory: true),
                        base.appendingPathComponent("Editor/Data/PlaybackEngines", isDirectory: true)
                    ]
                    for moduleRoot in uniqueExistingDirectories(moduleRoots) {
                        guard let modules = try? fileManager.contentsOfDirectory(
                            at: moduleRoot,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        ) else { continue }
                        candidates += modules.map { moduleURL in
                            ApplicationCandidate(
                                inventoryID: "module:unity:\(editor.inventoryID):\(moduleURL.lastPathComponent)",
                                path: moduleURL.path,
                                name: Self.unityModuleDisplayName(moduleURL.lastPathComponent),
                                bundleIdentifier: "unity-module:\(moduleURL.lastPathComponent)",
                                displayVersion: editor.displayVersion,
                                buildVersion: editor.buildVersion,
                                teamIdentifier: editor.teamIdentifier,
                                parentInventoryID: editor.inventoryID,
                                parentManagerBundleIdentifier: "com.unity3d.unityhub",
                                isSystemApplication: false,
                                info: ["ManagedComponentType": "unity-module", "ParentDisplayName": editor.name],
                                kind: .module
                            )
                        }
                    }
                }
            }
        }
        return candidates
    }

    private func discoverManagedGames(
        steamParentInventoryID: String?,
        caskApplicationsByPath: [String: PackageProvenance]
    ) -> [ApplicationCandidate] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let steamRoot = home
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        var steamAppsRoots = [steamRoot.appendingPathComponent("steamapps", isDirectory: true)]
        let libraryFile = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let data = try? Data(contentsOf: libraryFile),
           let text = String(data: data, encoding: .utf8) {
            steamAppsRoots += SteamLibraryParser.libraryPaths(in: text).map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("steamapps", isDirectory: true)
            }
        }

        // GOG documents ~/GOG Games as its default Mac install root. A generic
        // /Applications/Games folder is not evidence of GOG ownership.
        // Source: https://support.gog.com/hc/en-us/articles/213039625-Where-is-my-game-installed
        let gogLibraries = Self.gameLibraryRoots(home: home, platform: .gog)

        var result = uniqueExistingDirectories(steamAppsRoots).flatMap { steamAppsRoot in
            discoverSteamGames(
                steamAppsRoot: steamAppsRoot,
                parentInventoryID: steamParentInventoryID,
                caskApplicationsByPath: caskApplicationsByPath
            )
        }
        result += uniqueExistingDirectories(gogLibraries).flatMap { root in
            nestedApplicationBundles(at: root, maximumDepth: 4).compactMap { appURL in
                makeCandidate(
                    url: appURL,
                    parentManagerBundleIdentifier: GamePlatformKind.gog.managerBundleIdentifier,
                    gamePlatform: .gog,
                    caskApplicationsByPath: caskApplicationsByPath
                )
            }
        }
        let genericGameLibraries = Self.gameLibraryRoots(home: home, platform: .standalone)
        result += uniqueExistingDirectories(genericGameLibraries).flatMap { root in
            nestedApplicationBundles(at: root, maximumDepth: 4).compactMap { appURL in
                makeCandidate(
                    url: appURL,
                    parentManagerBundleIdentifier: nil,
                    gamePlatform: .standalone,
                    caskApplicationsByPath: caskApplicationsByPath
                )
            }
        }
        return result
    }

    static func gameLibraryRoots(home: URL, platform: GamePlatformKind) -> [URL] {
        switch platform {
        case .gog:
            return [
                URL(fileURLWithPath: "/Applications/GOG Games", isDirectory: true),
                home.appendingPathComponent("GOG Games", isDirectory: true)
            ]
        case .standalone:
            return [
                URL(fileURLWithPath: "/Applications/Games", isDirectory: true),
                home.appendingPathComponent("Applications/Games", isDirectory: true)
            ]
        case .steam, .epic, .heroic, .battleNet, .eaApp, .riot, .itch, .modrinth, .curseForge, .retroArch:
            return []
        }
    }

    private func discoverComfyUIInstallations(parentInventoryID: String?) -> [ApplicationCandidate] {
        let fileManager = FileManager.default
        let stateURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Comfy Desktop/installations.json")
        guard let data = try? Data(contentsOf: stateURL),
              let installations = try? JSONDecoder().decode([ComfyDesktopInstallation].self, from: data) else {
            return []
        }

        return installations.compactMap { installation in
            guard installation.status == "installed",
                  let installPath = installation.installPath,
                  fileManager.fileExists(atPath: installPath),
                  let installedVersion = installation.resolvedInstalledVersion else {
                return nil
            }

            let channel = installation.updateChannel ?? "stable"
            return ApplicationCandidate(
                inventoryID: "managed-component:comfyui:\(installPath)",
                path: installPath,
                name: installation.name ?? "ComfyUI",
                bundleIdentifier: "org.comfy.ComfyUI",
                displayVersion: installedVersion,
                buildVersion: installedVersion,
                teamIdentifier: nil,
                parentInventoryID: parentInventoryID,
                parentManagerBundleIdentifier: "com.todesktop.241012ess7yxs0e",
                isSystemApplication: false,
                info: ["UpdateChannel": channel],
                kind: .managedComponent
            )
        }
    }

    private func discoverVisualStudioCodeExtensions(
        hostVersion: String,
        parentInventoryID: String?
    ) -> [ApplicationCandidate] {
        let extensionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions/extensions.json")
        guard let data = try? Data(contentsOf: extensionsURL, options: [.uncached]),
              let extensions = try? JSONDecoder().decode([VisualStudioCodeExtension].self, from: data) else {
            return []
        }

        return extensions.compactMap { extensionRecord in
            guard activeControl?.shouldStop != true else { return nil }
            let identifier = extensionRecord.identifier.id.lowercased()
            let location = extensionRecord.location.path
            guard !identifier.isEmpty,
                  !extensionRecord.version.isEmpty,
                  FileManager.default.fileExists(atPath: location) else {
                return nil
            }

            let packageURL = URL(fileURLWithPath: location).appendingPathComponent("package.json")
            let package = packageURL
                .flatMapData()
                .flatMap { try? JSONDecoder().decode(VisualStudioCodeExtensionPackage.self, from: $0) }
            let targetPlatform = extensionRecord.metadata?.targetPlatform
                .flatMap { $0 == "undefined" ? nil : $0 }
            let iconPath = package?.icon.map {
                URL(fileURLWithPath: location).appendingPathComponent($0).path
            }
            let sourceCodeURL = package?.repositoryURL
            let license = package?.license?.trimmingCharacters(in: .whitespacesAndNewlines)

            return ApplicationCandidate(
                inventoryID: "extension:vscode:\(identifier)",
                path: location,
                name: package?.displayName ?? package?.name ?? identifier,
                bundleIdentifier: "vscode-extension:\(identifier)",
                displayVersion: extensionRecord.version,
                buildVersion: extensionRecord.version,
                teamIdentifier: nil,
                parentInventoryID: parentInventoryID,
                parentManagerBundleIdentifier: "com.microsoft.VSCode",
                isSystemApplication: false,
                info: [
                    "ManagedComponentType": "vscode-extension",
                    "ExtensionIdentifier": identifier,
                    "TargetPlatform": targetPlatform ?? "universal",
                    "HostVersion": hostVersion,
                    "IncludePrerelease": extensionRecord.metadata?.isPreReleaseVersion == true ? "true" : "false",
                    "IconPath": iconPath ?? "",
                    "SourceCodeURL": sourceCodeURL ?? "",
                    "License": license ?? ""
                ],
                kind: .extension
            )
        }
    }

    private func steamShortcutAppID(for candidate: ApplicationCandidate) -> String? {
        guard candidate.path.hasSuffix(".app"),
              let executableName = candidate.info["CFBundleExecutable"] else { return nil }
        let executableURL = URL(fileURLWithPath: candidate.path, isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        // Steam shortcuts are small shell scripts; read only a script's head instead of
        // loading every app's whole Mach-O executable.
        guard let handle = try? FileHandle(forReadingFrom: executableURL) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096),
              head.starts(with: Data("#!".utf8)) else { return nil }
        return SteamShortcutParser.appID(in: String(decoding: head, as: UTF8.self))
    }

    func discoverSteamGames(
        steamAppsRoot: URL,
        parentInventoryID: String?,
        caskApplicationsByPath: [String: PackageProvenance]
    ) -> [ApplicationCandidate] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: steamAppsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.filter {
            $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf"
        }.compactMap { manifestURL in
            guard activeControl?.shouldStop != true else { return nil }
            guard let attributes = try? fileManager.attributesOfItem(atPath: manifestURL.path),
                  let size = attributes[.size] as? NSNumber, size.intValue < 1_048_576,
                  let text = try? String(contentsOf: manifestURL, encoding: .utf8),
                  let manifest = SteamLibraryParser.manifest(in: text),
                  let installRoot = SteamLibraryParser.installRoot(
                    for: manifest, manifestURL: manifestURL, steamAppsRoot: steamAppsRoot
                  ),
                  let contents = try? fileManager.contentsOfDirectory(atPath: installRoot.path),
                  contents.contains(where: { !$0.hasPrefix(".") }) else { return nil }
            let appURL = nestedApplicationBundles(at: installRoot, maximumDepth: 4).first
            if let appURL,
               let bundleCandidate = makeCandidate(
                    url: appURL,
                    parentInventoryID: parentInventoryID,
                    parentManagerBundleIdentifier: "com.valvesoftware.steam",
                    gamePlatform: .steam,
                    caskApplicationsByPath: caskApplicationsByPath
               ) {
                return ApplicationCandidate(
                    inventoryID: "game:steam:\(manifest.appID)",
                    path: bundleCandidate.path,
                    name: manifest.name,
                    bundleIdentifier: bundleCandidate.bundleIdentifier,
                    displayVersion: bundleCandidate.displayVersion,
                    buildVersion: manifest.buildID ?? bundleCandidate.buildVersion,
                    teamIdentifier: bundleCandidate.teamIdentifier,
                    parentInventoryID: parentInventoryID,
                    parentManagerBundleIdentifier: "com.valvesoftware.steam",
                    isSystemApplication: false,
                    info: bundleCandidate.info.merging([
                        "SteamAppID": manifest.appID,
                        "SteamManifestPath": manifestURL.path,
                        "SteamBuildID": manifest.buildID ?? "",
                        "SteamTargetBuildID": manifest.targetBuildID ?? ""
                    ]) { current, _ in current },
                    kind: .game,
                    gamePlatform: .steam
                )
            }
            return ApplicationCandidate(
                inventoryID: "game:steam:\(manifest.appID)",
                path: installRoot.path,
                name: manifest.name,
                bundleIdentifier: "steam-app:\(manifest.appID)",
                displayVersion: manifest.buildID ?? String(localized: "Managed by Steam", bundle: AppL10n.bundle, locale: AppL10n.locale),
                buildVersion: manifest.buildID ?? "",
                teamIdentifier: nil,
                parentInventoryID: parentInventoryID,
                parentManagerBundleIdentifier: "com.valvesoftware.steam",
                isSystemApplication: false,
                info: [
                    "SteamAppID": manifest.appID,
                    "SteamManifestPath": manifestURL.path,
                    "SteamBuildID": manifest.buildID ?? "",
                    "SteamTargetBuildID": manifest.targetBuildID ?? ""
                ],
                kind: .game,
                gamePlatform: .steam
            )
        }
    }

    private func discoverPrismLauncherInstances(parentInventoryID: String?) -> [ApplicationCandidate] {
        let launcherRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PrismLauncher", isDirectory: true)
        return Self.prismLauncherInstances(launcherRoot: launcherRoot, parentInventoryID: parentInventoryID, control: activeControl)
    }

    static func prismLauncherInstances(launcherRoot: URL, parentInventoryID: String?, control: ScanControl? = nil) -> [ApplicationCandidate] {
        let settings = keyValueFile(at: launcherRoot.appendingPathComponent("prismlauncher.cfg"))
        let instances = prismDirectory(settings["InstanceDir"], relativeTo: launcherRoot, defaultName: "instances")
        let icons = prismDirectory(settings["IconsDir"], relativeTo: launcherRoot, defaultName: "icons")
        return prismLauncherInstances(at: instances, iconsRoot: icons, parentInventoryID: parentInventoryID, control: control)
    }

    private static func prismDirectory(_ configured: String?, relativeTo root: URL, defaultName: String) -> URL {
        guard let configured, !configured.isEmpty else {
            return root.appendingPathComponent(defaultName, isDirectory: true)
        }
        let expanded = (configured as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            : root.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }

    static func prismLauncherInstances(
        at root: URL,
        iconsRoot: URL? = nil,
        parentInventoryID: String?,
        control: ScanControl? = nil
    ) -> [ApplicationCandidate] {
        guard let parentInventoryID else { return [] }
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return directories.flatMap { directory -> [ApplicationCandidate] in
            guard control?.shouldStop != true else { return [] }
            let config = Self.keyValueFile(at: directory.appendingPathComponent("instance.cfg"))
            let packURL = directory.appendingPathComponent("mmc-pack.json")
            guard let data = try? Data(contentsOf: packURL),
                  let pack = try? JSONDecoder().decode(PrismPack.self, from: data) else { return [] }
            let minecraft = pack.components.first { $0.uid == "net.minecraft" }
            let instanceName = config["name"] ?? directory.lastPathComponent
            let version = minecraft?.version ?? "Unknown"
            let comparableVersion = version.range(
                of: #"^(?:[0-9]+(?:\.[0-9]+)+|[0-9]{2}w[0-9]{2}[a-z])$"#,
                options: .regularExpression
            ) != nil
            let instanceID = "game:prism:\(directory.lastPathComponent)"
            let localIcon = directory.appendingPathComponent("minecraft/icon.png")
            let iconKey = config["iconKey"].flatMap { value in
                value.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) == nil
                    ? nil : value
            }
            let launcherIcon = iconKey.map {
                (iconsRoot ?? root.deletingLastPathComponent().appendingPathComponent("icons"))
                    .appendingPathComponent("\($0).png")
            }
            let iconPath = [localIcon, launcherIcon].compactMap { $0 }.first {
                fileManager.fileExists(atPath: $0.path)
            }?.path
            let instance = ApplicationCandidate(
                inventoryID: instanceID,
                path: directory.path,
                name: "Minecraft · \(instanceName)",
                bundleIdentifier: "prism-instance:\(directory.lastPathComponent)",
                displayVersion: version,
                buildVersion: version,
                teamIdentifier: nil,
                parentInventoryID: parentInventoryID,
                parentManagerBundleIdentifier: "org.prismlauncher.PrismLauncher",
                isSystemApplication: false,
                info: [
                    "ManagedComponentType": "minecraft-instance",
                    "JavaVersion": config["JavaVersion"] ?? "",
                    "MinecraftVersionVerified": comparableVersion ? "true" : "false",
                    "UpdateChannel": version.range(of: #"^[0-9]{2}w[0-9]{2}"#, options: .regularExpression) == nil
                        ? "stable" : "nightly",
                    "IconPath": iconPath ?? ""
                ],
                kind: .game,
                gamePlatform: .standalone
            )
            let modules = pack.components.filter { $0.uid != "net.minecraft" }.map { component in
                let isLoader = [
                    "net.fabricmc.fabric-loader", "net.minecraftforge", "net.neoforged",
                    "org.quiltmc.quilt-loader", "com.mumfrey.liteloader"
                ].contains(component.uid)
                return ApplicationCandidate(
                    inventoryID: "module:prism:\(directory.lastPathComponent):\(component.uid)",
                    path: packURL.path,
                    name: component.cachedName ?? Self.prismComponentName(component.uid),
                    bundleIdentifier: "prism-component:\(component.uid)",
                    displayVersion: component.version,
                    buildVersion: component.version,
                    teamIdentifier: nil,
                    parentInventoryID: instanceID,
                    parentManagerBundleIdentifier: "org.prismlauncher.PrismLauncher",
                    isSystemApplication: false,
                    info: [
                        "ManagedComponentType": isLoader ? "minecraft-loader" : "minecraft-component",
                        "ParentDisplayName": "Minecraft · \(instanceName)"
                    ],
                    kind: isLoader ? .modLoader : .runtime,
                    gamePlatform: .standalone
                )
            }
            var runtimeItems = modules
            if let javaPath = config["JavaPath"], !javaPath.isEmpty {
                runtimeItems.append(ApplicationCandidate(
                    inventoryID: "runtime:prism:\(directory.lastPathComponent):java",
                    path: javaPath,
                    name: String(localized: "Java Runtime", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    bundleIdentifier: "prism-runtime:java",
                    displayVersion: config["JavaVersion"] ?? "Unknown",
                    buildVersion: config["JavaVersion"] ?? "Unknown",
                    teamIdentifier: nil,
                    parentInventoryID: instanceID,
                    parentManagerBundleIdentifier: "org.prismlauncher.PrismLauncher",
                    isSystemApplication: false,
                    info: [
                        "ManagedComponentType": "minecraft-runtime",
                        "ParentDisplayName": "Minecraft · \(instanceName)"
                    ],
                    kind: .runtime,
                    gamePlatform: .standalone
                ))
            }

            let content = Self.prismContentItems(in: directory, instanceID: instanceID, instanceName: instanceName, control: control)
            return [instance] + runtimeItems + content
        }
    }

    private static func prismContentItems(
        in instance: URL,
        instanceID: String,
        instanceName: String,
        control: ScanControl? = nil
    ) -> [ApplicationCandidate] {
        let folders: [(String, InventoryItemKind)] = [
            ("mods", .mod), ("shaderpacks", .shaderPack), ("resourcepacks", .resourcePack)
        ]
        return folders.flatMap { folder, kind -> [ApplicationCandidate] in
            guard control?.shouldStop != true else { return [] }
            let directory = instance.appendingPathComponent("minecraft/\(folder)", isDirectory: true)
            let metadata = PrismContentMetadata.read(in: directory)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return files.filter { file in
                guard control?.shouldStop != true else { return false }
                if ["jar", "zip"].contains(file.pathExtension.lowercased()) { return true }
                guard folder != "mods",
                      (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
                let marker = folder == "resourcepacks" ? "pack.mcmeta" : "shaders"
                return FileManager.default.fileExists(atPath: file.appendingPathComponent(marker).path)
            }.map { file in
                let details = metadata[file.lastPathComponent]
                let label = file.deletingPathExtension().lastPathComponent
                let version = details?.version ?? "Unknown"
                var info = [
                    "ManagedComponentType": "minecraft-\(folder)",
                    "ParentDisplayName": "Minecraft · \(instanceName)"
                ]
                if let source = details?.source { info["PrismMetadataPath"] = source }
                if let projectID = details?.modrinthProjectID { info["ModrinthProjectID"] = projectID }
                if let channel = details?.releaseType { info["ReleaseChannel"] = channel }
                return ApplicationCandidate(
                    inventoryID: "\(folder == "mods" ? "mod" : folder):prism:\(instance.lastPathComponent):\(file.lastPathComponent)",
                    path: file.path,
                    name: details?.name ?? label,
                    bundleIdentifier: "prism-\(folder):\(file.lastPathComponent)",
                    displayVersion: version,
                    buildVersion: version == "Unknown" ? "" : version,
                    teamIdentifier: nil,
                    parentInventoryID: instanceID,
                    parentManagerBundleIdentifier: "org.prismlauncher.PrismLauncher",
                    isSystemApplication: false,
                    info: info,
                    kind: kind,
                    gamePlatform: .standalone
                )
            }
        }
    }

    private func uniqueExistingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private func nestedApplicationBundles(at root: URL, maximumDepth: Int) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootDepth = root.standardizedFileURL.pathComponents.count
        var applications: [URL] = []
        for case let url as URL in enumerator {
            if activeControl?.shouldStop == true { break }
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "app" {
                applications.append(url)
                enumerator.skipDescendants()
            }
        }
        return applications
    }

    /// Read one known bundle without enumerating folders, children or other managers.
    static func refreshedBundle(_ item: InstalledApplication,
                                provenance: PackageProvenance? = nil) throws -> ApplicationCandidate {
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        let ownership = provenance.map { [path: $0] } ?? [:]
        guard let fresh = ApplicationScanner().makeCandidate(url: URL(fileURLWithPath: path),
            parentInventoryID: item.parentInventoryID,
            parentManagerBundleIdentifier: item.parentManagerBundleIdentifier,
            caskApplicationsByPath: ownership),
              fresh.bundleIdentifier == item.bundleIdentifier,
              item.teamIdentifier == nil || fresh.teamIdentifier == item.teamIdentifier else {
            throw NSError(domain: "UpdateAtlas.Refresh", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The installation changed or could not be read. Scan again before updating.", bundle: AppL10n.bundle, locale: AppL10n.locale)])
        }
        // Keep inventory ownership/identity stable across bundle replacement. Update
        // configuration and versions always come from the new on-disk metadata.
        var info = fresh.info
        if let discovery = item.discovery {
            info["DiscoverySource"] = discovery.source
            info["DiscoveryRole"] = discovery.role
            info["DiscoveryPlatform"] = discovery.platform
        }
        return ApplicationCandidate(inventoryID: item.id, path: fresh.path, name: fresh.name,
            bundleIdentifier: fresh.bundleIdentifier, displayVersion: fresh.displayVersion,
            buildVersion: fresh.buildVersion, teamIdentifier: fresh.teamIdentifier,
            parentInventoryID: item.parentInventoryID,
            parentManagerBundleIdentifier: item.parentManagerBundleIdentifier,
            isSystemApplication: fresh.isSystemApplication, info: info,
            kind: item.kind, gamePlatform: item.gamePlatform, packageProvenance: provenance)
    }

    private func makeCandidate(
        url: URL,
        parentInventoryID: String? = nil,
        parentManagerBundleIdentifier: String?,
        gamePlatform: GamePlatformKind? = nil,
        caskApplicationsByPath: [String: PackageProvenance]
    ) -> ApplicationCandidate? {
        let fileManager = FileManager.default
        guard activeControl?.shouldStop != true, fileManager.fileExists(atPath: url.path),
              let rawInfo = ApplicationBundleMetadataReader.infoDictionary(at: url) else { return nil }

        var name = (rawInfo["CFBundleDisplayName"] as? String)
            ?? (rawInfo["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = (rawInfo["CFBundleIdentifier"] as? String) ?? "path:\(url.path)"
        if bundleIdentifier == "com.kaspersky.ksec" { name = "Kaspersky VPN" }
        var displayVersion = (rawInfo["CFBundleShortVersionString"] as? String)
            ?? (rawInfo["CFBundleVersion"] as? String)
            ?? "Unknown"
        var buildVersion = (rawInfo["CFBundleVersion"] as? String) ?? displayVersion
        var stringInfo = rawInfo.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String { result[pair.key] = value }
        }
        if bundleIdentifier == "com.google.android.studio",
           let release = AndroidStudioMetadata.release(at: url, bundleVersion: displayVersion) {
            stringInfo["BundleShortVersion"] = displayVersion
            stringInfo["AndroidStudioFullVersion"] = release.version
            if let suffix = release.versionSuffix, !suffix.isEmpty {
                stringInfo["AndroidStudioPreviewChannel"] = suffix
            }
            displayVersion = release.version
        }
        if bundleIdentifier == "com.nousresearch.hermes.setup",
           let runtimeVersion = HermesRuntimeMetadata.installedVersion() {
            stringInfo["BundleShellVersion"] = displayVersion
            stringInfo["ManagedRuntimeVersion"] = runtimeVersion
            stringInfo["ManagedRuntimePath"] = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes/hermes-agent").path
            displayVersion = runtimeVersion
            buildVersion = runtimeVersion
        }
        if let storeMetadata = ApplicationBundleMetadataReader.appStoreMetadata(at: url) {
            if let itemID = storeMetadata["itemId"] as? NSNumber {
                stringInfo["AppStoreItemID"] = itemID.stringValue
            }
            if let country = storeMetadata["storefrontCountryCode"] as? String {
                stringInfo["AppStoreCountry"] = country.lowercased()
            }
        }

        let standardizedPath = url.standardizedFileURL.path
        let packageProvenance = caskApplicationsByPath[standardizedPath]
        let declaredAsGame = stringInfo["LSApplicationCategoryType"] == "public.app-category.games"
            && bundleIdentifier != "org.prismlauncher.PrismLauncher"
        let managerPlatform = Self.gameManagerPlatform(bundleIdentifier: bundleIdentifier)
        let resolvedGamePlatform = packageProvenance == nil
            ? (gamePlatform ?? (declaredAsGame ? .standalone : managerPlatform))
            : nil
        return ApplicationCandidate(
            path: standardizedPath,
            name: name,
            bundleIdentifier: bundleIdentifier,
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            teamIdentifier: SigningIdentityReader.teamIdentifier(at: url),
            parentInventoryID: parentInventoryID
                ?? (bundleIdentifier == "com.anthropic.claude-code-url-handler"
                    ? "application:/Applications/Claude.app" : nil),
            parentManagerBundleIdentifier: parentManagerBundleIdentifier,
            isSystemApplication: url.path.hasPrefix("/System/Applications/")
                || bundleIdentifier == "com.apple.appleseed.FeedbackAssistant",
            info: stringInfo,
            kind: bundleIdentifier == "com.anthropic.claude-code-url-handler"
                ? .helper
                : ((declaredAsGame || gamePlatform != nil) ? .game : .application),
            gamePlatform: resolvedGamePlatform,
            packageProvenance: packageProvenance
        )
    }
}

enum AndroidStudioMetadata {
    static func release(at bundle: URL, bundleVersion: String) -> (version: String, versionSuffix: String?)? {
        let url = bundle.appendingPathComponent("Contents/Resources/product-info.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue < 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return release(from: data, bundleVersion: bundleVersion)
    }

    static func release(from data: Data, bundleVersion: String) -> (version: String, versionSuffix: String?)? {
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let directoryName = document["dataDirectoryName"] as? String,
              directoryName.hasPrefix("AndroidStudio") else { return nil }
        let version = String(directoryName.dropFirst("AndroidStudio".count))
        let components = version.split(separator: ".")
        let shortComponents = bundleVersion.split(separator: ".")
        guard components.count == 3,
              !shortComponents.isEmpty,
              shortComponents.count <= components.count,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.prefix(shortComponents.count).elementsEqual(shortComponents) else { return nil }
        return (version, document["versionSuffix"] as? String)
    }
}

struct ApplicationScanResult: Sendable {
    let candidates: [ApplicationCandidate]
    let directInstallRemnants: [DirectInstallRemnant]
    var diagnostics: [ScanDiagnostic] = []
}

enum HermesRuntimeMetadata {
    static func sourceCandidate(
        parentInventoryID: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ApplicationCandidate? {
        let root = homeDirectory.appendingPathComponent(".hermes/hermes-agent", isDirectory: true)
        let launcher = homeDirectory.appendingPathComponent(".local/bin/hermes")
        let executable = root.appendingPathComponent(".hermes/bin/hermes")
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: launcher.path),
              fileManager.isExecutableFile(atPath: executable.path),
              launcherReferencesExecutable(launcher, executable: executable),
              let revision = sourceRevision(at: root) else { return nil }

        let version = String(revision.prefix(10))
        return ApplicationCandidate(
            inventoryID: "runtime:hermes-agent:\(root.standardizedFileURL.path)",
            path: root.path,
            name: "Hermes Agent",
            bundleIdentifier: "managed-component:hermes-agent",
            displayVersion: version,
            buildVersion: revision,
            teamIdentifier: nil,
            parentInventoryID: parentInventoryID,
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [
                "ManagedComponentType": "hermes-agent-source",
                "SourceRevision": revision,
                "SourceBranch": sourceBranch(at: root) ?? "unknown"
            ],
            kind: .runtime
        )
    }

    private static func launcherReferencesExecutable(_ launcher: URL, executable: URL) -> Bool {
        if launcher.resolvingSymlinksInPath().path == executable.path { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: launcher.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue < 16_384,
              let text = try? String(contentsOf: launcher, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains {
            $0.contains("exec ") && $0.contains(executable.path)
        }
    }

    static func sourceRevision(at root: URL) -> String? {
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCommitID(trimmed) { return trimmed.lowercased() }
        guard trimmed.hasPrefix("ref: refs/heads/"),
              !trimmed.contains(".."),
              !trimmed.contains("\\"),
              trimmed.range(of: #"^ref: refs/heads/[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let reference = String(trimmed.dropFirst("ref: ".count))

        let looseURL = gitDirectory.appendingPathComponent(reference)
        if let loose = try? String(contentsOf: looseURL, encoding: .utf8) {
            let revision = loose.trimmingCharacters(in: .whitespacesAndNewlines)
            if isCommitID(revision) { return revision.lowercased() }
        }
        guard let packed = try? String(
            contentsOf: gitDirectory.appendingPathComponent("packed-refs"), encoding: .utf8
        ) else { return nil }
        for line in packed.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[1] == reference, isCommitID(String(fields[0])) {
                return String(fields[0]).lowercased()
            }
        }
        return nil
    }

    private static func sourceBranch(at root: URL) -> String? {
        let headURL = root.appendingPathComponent(".git/HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }
        return String(trimmed.dropFirst("ref: refs/heads/".count))
    }

    private static func isCommitID(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    static func installedVersion(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let runtimeRoot = homeDirectory.appendingPathComponent(".hermes/hermes-agent", isDirectory: true)
        let pyprojectURL = runtimeRoot.appendingPathComponent("pyproject.toml")
        if let data = try? Data(contentsOf: pyprojectURL),
           let version = version(fromPyprojectData: data), version != "0.0.0" {
            return version
        }

        let updateCheckURL = homeDirectory.appendingPathComponent(".hermes/.update_check")
        if let data = try? Data(contentsOf: updateCheckURL),
           let version = version(fromUpdateCheckData: data), version != "0.0.0" {
            return version
        }
        return nil
    }

    static func version(fromUpdateCheckData data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["ver"] as? String else { return nil }
        return normalized(value)
    }

    static func version(fromPyprojectData data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"(?m)^version\s*=\s*[\"']([^\"']+)[\"']\s*$"#
              ),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return normalized(String(text[range]))
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[0-9]+(?:\.[0-9A-Za-z-]+)+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }
}

private extension ApplicationScanner {
    static func unityModuleDisplayName(_ identifier: String) -> String {
        let known = [
            "iOSSupport": String(localized: "iOS Build Support", bundle: AppL10n.bundle, locale: AppL10n.locale),
            "AndroidPlayer": String(localized: "Android Build Support", bundle: AppL10n.bundle, locale: AppL10n.locale),
            "MacStandaloneSupport": String(localized: "macOS Build Support", bundle: AppL10n.bundle, locale: AppL10n.locale),
            "WebGLSupport": String(localized: "WebGL Build Support", bundle: AppL10n.bundle, locale: AppL10n.locale),
            "LinuxStandaloneSupport": String(localized: "Linux Build Support", bundle: AppL10n.bundle, locale: AppL10n.locale),
            "WindowsStandaloneSupport": String(localized: "Windows Build Support", bundle: AppL10n.bundle, locale: AppL10n.locale)
        ]
        return known[identifier] ?? identifier
    }

    static func prismComponentName(_ uid: String) -> String {
        let known = [
            "org.lwjgl3": "LWJGL",
            "net.fabricmc.intermediary": "Fabric Intermediary",
            "net.fabricmc.fabric-loader": "Fabric Loader",
            "net.minecraftforge": "Minecraft Forge",
            "org.quiltmc.quilt-loader": "Quilt Loader"
        ]
        return known[uid] ?? uid
    }

    static func gameManagerPlatform(bundleIdentifier: String) -> GamePlatformKind? {
        switch bundleIdentifier {
        case "com.valvesoftware.steam": .steam
        case "com.gog.galaxy": .gog
        case "com.epicgames.EpicGamesLauncher": .epic
        case "com.heroicgameslauncher.hgl": .heroic
        case "org.prismlauncher.PrismLauncher": .standalone
        default: nil
        }
    }

    static func minecraftModDisplayName(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "[-_]?v?[0-9]+(?:\\.[0-9A-Za-z]+)+.*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func minecraftModVersion(_ filename: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"(?:^|[-_])v?([0-9]+(?:\.[0-9A-Za-z]+)+)"#),
              let match = expression.firstMatch(
                in: filename,
                range: NSRange(filename.startIndex..<filename.endIndex, in: filename)
              ),
              let range = Range(match.range(at: 1), in: filename) else { return nil }
        return String(filename[range])
    }

    static func keyValueFile(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
    }
}

enum ApplicationBundleMetadataReader {
    static func infoDictionary(at applicationURL: URL) -> [String: Any]? {
        let candidates = [
            applicationURL.appendingPathComponent("Contents/Info.plist"),
            applicationURL.appendingPathComponent("WrappedBundle/Info.plist")
        ]
        for infoURL in candidates {
            if let dictionary = propertyList(at: infoURL) {
                return dictionary
            }
        }
        return nil
    }

    static func appStoreMetadata(at applicationURL: URL) -> [String: Any]? {
        propertyList(at: applicationURL.appendingPathComponent("Wrapper/iTunesMetadata.plist"))
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return value as? [String: Any]
    }
}

private struct VisualStudioCodeExtension: Decodable {
    struct Identifier: Decodable { let id: String }
    struct Location: Decodable { let path: String }
    struct Metadata: Decodable {
        let targetPlatform: String?
        let isPreReleaseVersion: Bool?
    }

    let identifier: Identifier
    let version: String
    let location: Location
    let metadata: Metadata?
}

private struct VisualStudioCodeExtensionPackage: Decodable {
    let name: String?
    let displayName: String?
    let icon: String?
    let license: String?
    let repository: Repository?

    struct Repository: Decodable { let url: String? }

    var repositoryURL: String? {
        repository?.url?
            .replacingOccurrences(of: "git+", with: "")
            .replacingOccurrences(of: ".git", with: "")
    }
}

private struct PrismPack: Decodable {
    struct Component: Decodable {
        let uid: String
        let version: String
        let cachedName: String?
    }
    let components: [Component]
}

private struct PrismContentMetadata {
    let name: String?
    let version: String?
    let releaseType: String?
    let modrinthProjectID: String?
    let source: String

    static func read(in directory: URL) -> [String: Self] {
        // Prism stores downloaded content metadata in packwiz-style .pw.toml files.
        // Read only local identity/version fields; do not infer updates from file names.
        // Source: https://packwiz.infra.link/reference/pack-format/mod-toml/
        let roots = [directory, directory.appendingPathComponent(".index", isDirectory: true)]
        return roots.reduce(into: [:]) { results, root in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: []
            )) ?? []
            for file in files where file.lastPathComponent.hasSuffix(".pw.toml") {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size < 256_000,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                var fields: [String: String] = [:]
                var section = ""
                for line in text.split(whereSeparator: \.isNewline) {
                    let value = line.trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("[") { section = value; continue }
                    guard section.isEmpty || section == "[update.modrinth]",
                          let separator = value.firstIndex(of: "=") else { continue }
                    let key = value[..<separator].trimmingCharacters(in: .whitespaces)
                    let quoted = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                    guard quoted.count >= 2, let quote = quoted.first,
                          (quote == "'" || quote == "\""), quoted.last == quote else { continue }
                    fields[(section.isEmpty ? "" : "modrinth.") + key] = String(quoted.dropFirst().dropLast())
                }
                guard let filename = fields["filename"],
                      filename == URL(fileURLWithPath: filename).lastPathComponent else { continue }
                results[filename] = Self(
                    name: fields["name"], version: fields["x-prismlauncher-version-number"],
                    releaseType: fields["x-prismlauncher-release-type"],
                    modrinthProjectID: fields["modrinth.mod-id"], source: file.path
                )
            }
        }
    }
}

private extension URL {
    func flatMapData() -> Data? {
        try? Data(contentsOf: self, options: [.uncached])
    }
}

private struct ComfyDesktopInstallation: Decodable {
    struct GitVersion: Decodable {
        let baseTag: String?
    }

    struct ChannelState: Decodable {
        let installedTag: String?
    }

    let name: String?
    let installPath: String?
    let status: String?
    let version: String?
    let updateChannel: String?
    let comfyVersion: GitVersion?
    let updateInfoByChannel: [String: ChannelState]?

    var resolvedInstalledVersion: String? {
        let channel = updateChannel ?? "stable"
        return updateInfoByChannel?[channel]?.installedTag
            ?? comfyVersion?.baseTag
            ?? version
    }
}

enum SteamLibraryParser {
    struct Manifest: Equatable {
        let appID: String
        let name: String
        let installDirectory: String
        let buildID: String?
        let targetBuildID: String?
        let stateFlags: String
    }

    static func libraryPaths(in contents: String) -> [String] {
        let pattern = #"\"path\"\s+\"([^\"]+)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return expression.matches(in: contents, range: fullRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: contents) else { return nil }
            let path = String(contents[range]).replacingOccurrences(of: #"\\"#, with: #"\"#)
            return path.hasPrefix("/") && !path.contains("\0") ? path : nil
        }
    }

    static func manifest(in contents: String) -> Manifest? {
        // Steam documents appmanifest_[appid].acf as the client's KeyValues install state:
        // https://partner.steamgames.com/doc/sdk/uploading#Debugging_Build_Issues
        guard contents.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\"AppState\"") else {
            return nil
        }
        func value(_ key: String) -> String? {
            let pattern = #"\""# + NSRegularExpression.escapedPattern(for: key)
                + #"\"\s+\"([^\"]*)\""#
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(
                    in: contents,
                    range: NSRange(contents.startIndex..<contents.endIndex, in: contents)
                  ),
                  let range = Range(match.range(at: 1), in: contents) else { return nil }
            return String(contents[range])
        }
        guard let appID = value("appid"), !appID.isEmpty,
              appID.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let name = value("name"), !name.isEmpty,
              let installDirectory = value("installdir"),
              isSafeInstallDirectory(installDirectory),
              let stateFlags = value("StateFlags"),
              let state = UInt64(stateFlags), state != 0 else { return nil }
        return Manifest(
            appID: appID,
            name: name,
            installDirectory: installDirectory,
            buildID: value("buildid"),
            targetBuildID: value("TargetBuildID"),
            stateFlags: stateFlags
        )
    }

    static func installRoot(for manifest: Manifest, manifestURL: URL, steamAppsRoot: URL) -> URL? {
        guard manifestURL.lastPathComponent == "appmanifest_\(manifest.appID).acf",
              isSafeInstallDirectory(manifest.installDirectory) else { return nil }
        let common = steamAppsRoot.appendingPathComponent("common", isDirectory: true).standardizedFileURL
        let root = common.appendingPathComponent(manifest.installDirectory, isDirectory: true).standardizedFileURL
        return root.deletingLastPathComponent() == common ? root : nil
    }

    private static func isSafeInstallDirectory(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0")
    }
}

enum SteamLocalUpdateEvidence {
    static func newerTarget(installed: String?, target: String?) -> String? {
        guard let installed, let target,
              let installedNumber = UInt64(installed), let targetNumber = UInt64(target),
              targetNumber > installedNumber else { return nil }
        return target
    }
}

enum SteamShortcutParser {
    static func appID(in contents: String) -> String? {
        let pattern = #"steam://(?:run|rungameid)/(\d+)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: contents,
            range: NSRange(contents.startIndex..<contents.endIndex, in: contents)
        ),
        let range = Range(match.range(at: 1), in: contents) else { return nil }
        return String(contents[range])
    }
}

enum SteamInventoryReconciler {
    static func isInstalled(shortcutAppID: String, manifestAppIDs: Set<String>) -> Bool {
        manifestAppIDs.contains(shortcutAppID)
    }
}

enum InventorySettings {
    static let includeSystemApplicationsKey = "inventory.include-system-applications"
    static let defaultIncludeSystemApplications = false
    static let defaultViewKey = "inventory.default-view"
    static let defaultView = DefaultInventoryView.updateAvailable
    static let hideSystemPythonUpdatesKey = "inventory.hide-system-python-updates"
    static let hideSystemPythonPackagesKey = hideSystemPythonUpdatesKey
    static let defaultHideSystemPythonUpdates = true
    static let defaultHideSystemPythonPackages = defaultHideSystemPythonUpdates

    static func hideSystemPythonUpdates(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hideSystemPythonUpdatesKey) as? Bool ?? defaultHideSystemPythonUpdates
    }
}

private enum SigningIdentityReader {
    static func teamIdentifier(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else { return nil }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard copyStatus == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
