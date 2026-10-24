import Foundation

struct UpdateDetectionEngine: Sendable {
    func classify(
        _ candidates: [ApplicationCandidate],
        catalog: RemoteCatalog
    ) -> [InstalledApplication] {
        candidates.map { classify($0, catalog: catalog) }
    }

    private func classify(
        _ candidate: ApplicationCandidate,
        catalog: RemoteCatalog
    ) -> InstalledApplication {
        if candidate.info["DiscoverySource"] == "Docker" {
            let manager = candidate.parentManagerBundleIdentifier ?? "com.docker.docker"
            return record(candidate, status: .managedExternally, mechanism: .externalManager,
                mechanismName: "Docker", confidence: .verified,
                evidence: [.init(title: String(localized: "Local Docker inventory", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: candidate.info["DockerImageID"] ?? candidate.kind.title, level: .confirmed)],
                parentManagerBundleIdentifier: manager, parentManagerName: managerDescriptor(for: manager).name,
                notes: String(localized: "This is a local Docker object. Image identity and container state do not establish whether an update exists; Docker owns changes to these objects.", bundle: AppL10n.bundle, locale: AppL10n.locale))
        }

        if candidate.info["ManagedComponentType"] == "hermes-agent-source",
           let revision = candidate.info["SourceRevision"],
           candidate.info["SourceBranch"] != "main" {
            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .githubReleases,
                mechanismName: String(localized: "Hermes Agent · Git checkout", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [.init(title: String(localized: "Installed Git revision", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: revision, level: .confirmed)],
                vendorURL: URL(string: "https://hermes-agent.nousresearch.com/"),
                isOpenSource: true,
                sourceCodeURL: URL(string: "https://github.com/NousResearch/hermes-agent"),
                notes: String(localized: "This Hermes Agent checkout is not on the official main branch. Update Atlas will not compare it with main or recommend replacing it.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if candidate.info["ManagedComponentType"] == "hermes-agent-source",
           let revision = candidate.info["SourceRevision"],
           let url = URL(string: "https://api.github.com/repos/NousResearch/hermes-agent/compare/\(revision)...main?per_page=1") {
            return record(
                candidate,
                status: .supported,
                mechanism: .githubReleases,
                mechanismName: String(localized: "Hermes Agent · GitHub main", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [
                    .init(title: String(localized: "Source checkout", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.path, level: .confirmed),
                    .init(title: String(localized: "Installed Git revision", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: revision, level: .confirmed)
                ],
                parentManagerBundleIdentifier: candidate.parentInventoryID == nil ? nil : "com.nousresearch.hermes",
                parentManagerName: candidate.parentInventoryID == nil ? nil : "Hermes",
                vendorURL: URL(string: "https://hermes-agent.nousresearch.com/"),
                isOpenSource: true,
                sourceCodeURL: URL(string: "https://github.com/NousResearch/hermes-agent"),
                releaseNotesURL: URL(string: "https://github.com/NousResearch/hermes-agent/commits/main/"),
                updateFeedURL: url,
                versionProvider: CatalogVersionProvider(type: .githubCommitCompare, url: url, channel: "main"),
                notes: String(localized: "This installed Hermes Agent source checkout is checked separately from Hermes Desktop. Update Atlas compares its Git revision with the official main branch; Hermes remains responsible for applying updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if ["com.nousresearch.hermes", "com.nousresearch.hermes.setup"].contains(candidate.bundleIdentifier),
           candidate.displayVersion == "0.0.0" || candidate.displayVersion == "0.0.1" {
            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .externalManager,
                mechanismName: String(localized: "Hermes Desktop · Source Build", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [.init(title: String(localized: "Bundle identity", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.bundleIdentifier, level: .confirmed)],
                vendorURL: URL(string: "https://hermes-agent.nousresearch.com/"),
                isOpenSource: true,
                sourceCodeURL: URL(string: "https://github.com/NousResearch/hermes-agent"),
                notes: String(localized: "This Hermes Desktop build has a placeholder version. It cannot be compared with Hermes Agent releases; check its separately installed Agent runtime instead.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if candidate.bundleIdentifier == "com.anthropic.claude-code-url-handler" {
            return record(
                candidate,
                status: .managedExternally,
                mechanism: .externalManager,
                mechanismName: String(localized: "Part of Claude", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [
                    .init(title: String(localized: "Bundle identity", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "Anthropic Claude URL-scheme helper", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed),
                    .init(title: String(localized: "Signing identity", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.teamIdentifier ?? String(localized: "Anthropic helper", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed)
                ],
                parentManagerBundleIdentifier: "com.anthropic.claudefordesktop",
                parentManagerName: "Claude",
                notes: String(localized: "This background URL handler belongs to Claude and is not an independently updatable application.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if candidate.info["ManagedComponentType"] == "vscode-extension",
           let identifier = candidate.info["ExtensionIdentifier"],
           let providerURL = visualStudioMarketplaceURL(identifier: identifier) {
            return record(
                candidate,
                status: .supported,
                mechanism: .ideExtension,
                mechanismName: String(localized: "VS Code Marketplace", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [
                    .init(title: String(localized: "VS Code extension registry", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: identifier, level: .confirmed),
                    .init(title: String(localized: "Parent IDE", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: "Visual Studio Code \(candidate.info["HostVersion"] ?? "")", level: .confirmed)
                ],
                parentManagerBundleIdentifier: "com.microsoft.VSCode",
                parentManagerName: "Visual Studio Code",
                vendorURL: URL(string: "https://marketplace.visualstudio.com/items?itemName=\(identifier)"),
                isOpenSource: Self.openSourceStatus(forLicense: candidate.info["License"]),
                sourceCodeURL: candidate.info["SourceCodeURL"].flatMap(URL.init(string:)),
                updateFeedURL: providerURL,
                versionProvider: CatalogVersionProvider(
                    type: .visualStudioMarketplace,
                    url: providerURL,
                    channel: "stable",
                    identifier: identifier,
                    targetPlatform: candidate.info["TargetPlatform"],
                    hostVersion: candidate.info["HostVersion"],
                    includePrerelease: candidate.info["IncludePrerelease"] == "true",
                    releaseChannel: candidate.info["IncludePrerelease"] == "true" ? .beta : .stable
                ),
                notes: String(localized: "The extension is checked separately from VS Code, using its installed channel, target platform, and IDE compatibility. Installation remains owned by VS Code.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if candidate.info["ManagedComponentType"] == "minecraft-instance",
           candidate.info["MinecraftVersionVerified"] == "true",
           let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json") {
            let isSnapshot = candidate.info["UpdateChannel"] == "nightly"
            return record(
                candidate,
                status: .supported,
                mechanism: .externalManager,
                mechanismName: isSnapshot
                    ? String(localized: "Minecraft Version Manifest · Snapshot", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "Minecraft Version Manifest · Release", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [
                    .init(title: String(localized: "Prism instance registry", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.path, level: .confirmed),
                    .init(title: String(localized: "Mojang release source", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: manifestURL.absoluteString, level: .confirmed)
                ],
                parentManagerBundleIdentifier: "org.prismlauncher.PrismLauncher",
                parentManagerName: "Prism Launcher",
                vendorURL: URL(string: "https://www.minecraft.net/"),
                updateFeedURL: manifestURL,
                versionProvider: CatalogVersionProvider(
                    type: .minecraftVersionManifest,
                    url: manifestURL,
                    channel: isSnapshot ? "snapshot" : "release",
                    releaseChannel: isSnapshot ? .nightly : .stable
                ),
                notes: String(localized: "Mojang's manifest tracks the selected Minecraft channel. Prism Launcher owns version changes; mods and packs may need separate compatibility checks.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if candidate.gamePlatform != .steam,
           candidate.parentManagerBundleIdentifier != nil,
           let entry = catalog.entries.first(where: { $0.match.matches(candidate) }) {
            return catalogRecord(candidate, entry: entry, revision: catalog.revision)
        }

        if let parentBundleID = candidate.parentManagerBundleIdentifier {
            let manager = managerDescriptor(for: parentBundleID)
            let steamTarget = parentBundleID == "com.valvesoftware.steam"
                ? SteamLocalUpdateEvidence.newerTarget(
                    installed: candidate.info["SteamBuildID"],
                    target: candidate.info["SteamTargetBuildID"]
                ) : nil
            let metadataPath = candidate.info["PrismMetadataPath"]
            let localEvidence: DetectionEvidence
            if parentBundleID == "org.prismlauncher.PrismLauncher" {
                localEvidence = DetectionEvidence(
                    title: metadataPath != nil
                        ? String(localized: "Prism content metadata", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "Prism instance file", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: metadataPath ?? candidate.path,
                    level: .confirmed
                )
            } else if parentBundleID == "com.valvesoftware.steam",
                      let manifestPath = candidate.info["SteamManifestPath"] {
                localEvidence = DetectionEvidence(
                    title: String(localized: "Steam app manifest", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: manifestPath,
                    level: .confirmed
                )
            } else {
                localEvidence = DetectionEvidence(
                    title: String(localized: "Nested bundle scan", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: String(localized: "Found inside a manager-owned installation directory.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    level: .confirmed
                )
            }
            return record(
                candidate,
                status: .managedExternally,
                mechanism: .externalManager,
                mechanismName: String(localized: "Managed by", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(manager.name)",
                confidence: .high,
                evidence: [
                    localEvidence,
                    .init(title: String(localized: "Parent manager", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: parentBundleID, level: .confirmed)
                ] + (candidate.info["SteamBuildID"].flatMap { $0.isEmpty ? nil : $0 }.map {
                    [.init(title: String(localized: "Steam installed build", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: $0, level: .confirmed)]
                } ?? []) + (steamTarget.map {
                    [.init(title: String(localized: "Steam target build", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: $0, level: .confirmed)]
                } ?? []),
                parentManagerBundleIdentifier: parentBundleID,
                parentManagerName: candidate.info["ParentDisplayName"] ?? manager.name,
                updateCheck: steamTarget.map { target in
                    UpdateCheckResult(
                        availability: .updateAvailable,
                        installedVersion: candidate.info["SteamBuildID"] ?? candidate.displayVersion,
                        latestVersion: target,
                        checkedAt: Date(),
                        source: .steamManifest,
                        detail: String(localized: "Steam's local manifest records a newer target build. Open Steam to download or finish this game's update.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    )
                },
                notes: manager.notes
            )
        }

        if candidate.isSystemApplication {
            return record(
                candidate,
                status: .managedExternally,
                mechanism: .system,
                mechanismName: String(localized: "Managed by macOS", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [.init(title: String(localized: "System location", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.path, level: .confirmed)],
                notes: String(localized: "This application is delivered and maintained with macOS.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if candidate.bundleIdentifier == "com.google.android.studio",
           candidate.info["AndroidStudioFullVersion"] == nil
                || candidate.info["AndroidStudioPreviewChannel"] != nil {
            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .externalManager,
                mechanismName: String(localized: "Android Studio Updater", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [.init(title: String(localized: "Bundle version", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.displayVersion, level: .confirmed)],
                vendorURL: URL(string: "https://developer.android.com/studio/releases"),
                notes: String(localized: "The full Android Studio release version or stable channel could not be verified from this bundle. Update Atlas will not compare a shortened or preview version with stable releases.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if let provenance = candidate.packageProvenance {
            let guardedVersionEntry = ["com.google.android.studio", "Qisda.DDPM"]
                .contains(candidate.bundleIdentifier)
                ? catalog.entries.first(where: { $0.match.matches(candidate) }) : nil
            let evidenceDetail: String
            switch provenance.manager {
            case .homebrewCask:
                evidenceDetail = String(localized: "Homebrew Cask declares this exact application target:", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    + " \(provenance.identifier)."
            case .homebrewFormula:
                evidenceDetail = String(localized: "Homebrew records this requested formula as installed:", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    + " \(provenance.identifier)."
            case .npm:
                evidenceDetail = provenance.identifier + " "
                    + String(localized: "is present in npm's global top-level package list.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .pythonPip:
                evidenceDetail = provenance.identifier + " "
                    + String(localized: "is a top-level package in this Python environment.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .pipx:
                evidenceDetail = provenance.identifier + " "
                    + String(localized: "is recorded in a pipx-managed environment.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .uvTool:
                evidenceDetail = provenance.identifier + " "
                    + String(localized: "is recorded as a persistent uv tool.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .cargo:
                evidenceDetail = provenance.identifier + " "
                    + String(localized: "is recorded by Cargo with an installed binary.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }

            var evidence = [
                DetectionEvidence(
                    title: String(localized: "Package manager provenance", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: evidenceDetail,
                    level: .confirmed
                ),
                DetectionEvidence(
                    title: String(localized: "Manager executable", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: provenance.managerExecutablePath,
                    level: .informational
                )
            ]
            if provenance.isOutdated == true {
                evidence.append(.init(
                    title: String(localized: "Manager status", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    detail: String(localized: "The package manager currently marks this item as outdated.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    level: .warning
                ))
            }

            return record(
                candidate,
                status: .supported,
                mechanism: provenance.manager.mechanism,
                mechanismName: "\(provenance.manager.title) · \(provenance.identifier)",
                confidence: provenance.manager == .pythonPip ? .high : .verified,
                evidence: evidence,
                vendorURL: provenance.homepage,
                updateFeedURL: guardedVersionEntry?.mechanism.versionProviders.first?.url,
                versionProviders: guardedVersionEntry?.mechanism.versionProviders ?? [],
                catalogEntryID: guardedVersionEntry?.id,
                notes: provenance.summary
                    ?? (String(localized: "This item is owned and checked by", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(provenance.manager.title).")
            )
        }

        if hasAppStoreReceipt(candidate) {
            let lookupURL = appStoreLookupURL(for: candidate)
            return record(
                candidate,
                status: lookupURL == nil ? .needsCatalog : .supported,
                mechanism: .appStore,
                mechanismName: "App Store",
                confidence: .verified,
                evidence: [.init(title: String(localized: "App Store receipt", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "A signed store receipt is present in the bundle.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed)],
                updateFeedURL: lookupURL,
                versionProvider: lookupURL.map {
                    CatalogVersionProvider(
                        type: .appleAppStoreLookup,
                        url: $0,
                        channel: candidate.info["AppStoreCountry"] ?? "tr",
                        identifier: candidate.bundleIdentifier
                    )
                },
                notes: String(localized: "Update availability can be checked through the App Store provider. Installation remains owned by the App Store.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if isHomebrewManaged(candidate) {
            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .homebrew,
                mechanismName: String(localized: "Homebrew · Unresolved Cask", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .high,
                evidence: [.init(title: String(localized: "Homebrew provenance", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "The application resolves into Homebrew's Caskroom.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed)],
                notes: String(localized: "The application is inside Homebrew's Caskroom, but its cask token was not resolved. A verified package record or catalog rule is required before checking updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        let isUnversionedDirectCLI = candidate.bundleIdentifier.hasPrefix("direct-cli:")
            && (candidate.displayVersion == "Unknown" || candidate.displayVersion == String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale))

        if !isUnversionedDirectCLI,
           let entry = catalog.entries.first(where: { $0.match.matches(candidate) }) {
            return catalogRecord(candidate, entry: entry, revision: catalog.revision)
        }

        if let documentation = candidate.info["DirectInstallSource"],
           let documentationURL = URL(string: documentation),
           let owner = candidate.info["DirectInstallOwner"] {
            let versionProven = candidate.info["DirectInstallVersionProven"] == "true"
            var directEvidence: [DetectionEvidence] = [
                .init(title: String(localized: "Executable at documented location", bundle: AppL10n.bundle, locale: AppL10n.locale),
                      detail: candidate.path, level: .confirmed),
                .init(title: String(localized: "Publisher installation guide", bundle: AppL10n.bundle, locale: AppL10n.locale),
                      detail: documentation, level: .informational)
            ]
            if let versionSource = candidate.info["DirectInstallVersionSource"] {
                directEvidence.append(
                    .init(title: String(localized: "Local version metadata", bundle: AppL10n.bundle, locale: AppL10n.locale),
                          detail: versionSource, level: .confirmed)
                )
            }
            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .publisherCLIInstaller,
                mechanismName: owner + " · " + String(localized: "Publisher CLI Installer", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: versionProven ? .high : .medium,
                evidence: directEvidence,
                vendorURL: documentationURL,
                notes: versionProven
                    ? String(localized: "The executable and its local version receipt were found at documented paths. A catalog rule can compare this version with upstream releases.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    : String(localized: "The executable is present at a documented default path. Its installer origin and installed version are not proven by that path alone; no executable is run during discovery.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if isGoogleUpdaterManaged(candidate) {
            let endpoint = candidate.info["KSUpdateURL"] ?? String(localized: "Embedded GoogleUpdater helper", bundle: AppL10n.bundle, locale: AppL10n.locale)
            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .googleUpdater,
                mechanismName: String(localized: "Google Updater detected", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .verified,
                evidence: [.init(title: String(localized: "Google updater", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: endpoint, level: .confirmed)],
                notes: String(localized: "The update mechanism is present, but a verified catalog rule is required to select the product and release channel.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if let manager = knownManagerDescriptor(for: candidate.bundleIdentifier) {
            return record(
                candidate,
                status: .managedExternally,
                mechanism: .externalManager,
                mechanismName: String(format: String(localized: "%@ Manager", bundle: AppL10n.bundle, locale: AppL10n.locale), manager.name),
                confidence: .verified,
                evidence: [.init(title: String(localized: "Known manager", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: manager.managerEvidence, level: .confirmed)],
                notes: manager.managerNotes
            )
        }

        if hasFramework(named: "Sparkle.framework", candidate: candidate) {
            if let feed = candidate.info["SUFeedURL"], let feedURL = URL(string: feed), feedURL.scheme == "https" {
                return record(
                    candidate,
                    status: .supported,
                    mechanism: .sparkle,
                    mechanismName: "Sparkle",
                    confidence: .verified,
                    evidence: [
                        .init(title: String(localized: "Sparkle framework", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "Embedded in the application bundle.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed),
                        .init(title: String(localized: "Public feed", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: feed, level: .confirmed)
                    ],
                    vendorURL: feedURL,
                    updateFeedURL: feedURL,
                    versionProvider: CatalogVersionProvider(
                        type: .sparkleAppcast,
                        url: feedURL,
                        channel: nil
                    ),
                    notes: String(localized: "The application exposes a public Sparkle feed.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }

            return record(
                candidate,
                status: .needsCatalog,
                mechanism: .sparkle,
                mechanismName: String(localized: "Sparkle detected", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: .medium,
                evidence: [
                    .init(title: String(localized: "Sparkle framework", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "Embedded in the application bundle.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed),
                    .init(title: String(localized: "Public feed", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "No static SUFeedURL was found; the feed may be configured at runtime.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .warning)
                ],
                notes: String(localized: "A catalog rule can identify the feed without requiring an application release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if hasFramework(named: "Squirrel.framework", candidate: candidate) {
            let configuration = electronConfiguration(at: candidate)
            return record(
                candidate,
                status: configuration == nil ? .needsCatalog : .supported,
                mechanism: .squirrel,
                mechanismName: String(localized: "Squirrel / Electron", bundle: AppL10n.bundle, locale: AppL10n.locale),
                confidence: configuration == nil ? .medium : .high,
                evidence: [
                    .init(title: String(localized: "Squirrel framework", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "Embedded in the application bundle.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .confirmed),
                    .init(
                        title: String(localized: "Update configuration", bundle: AppL10n.bundle, locale: AppL10n.locale),
                        detail: configuration ?? String(localized: "No public app-update.yml was found; configuration may be supplied at runtime.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                        level: configuration == nil ? .warning : .confirmed
                    )
                ],
                notes: configuration == nil
                    ? String(localized: "The update mechanism is known, but a catalog rule is needed to resolve its public feed.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    : String(localized: "The Electron update configuration is available for a provider to inspect.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        return record(
            candidate,
            status: .unsupported,
            mechanism: .unknown,
            mechanismName: String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale),
            confidence: .low,
            evidence: [
                .init(title: String(localized: "Bundle scanned", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.path, level: .informational),
                .init(title: String(localized: "Update metadata", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "No supported update mechanism was detected.", bundle: AppL10n.bundle, locale: AppL10n.locale), level: .warning)
            ],
            notes: String(localized: "No update status is claimed until a source is verified.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        )
    }

    private static func openSourceStatus(forLicense license: String?) -> Bool? {
        guard let license = license?.trimmingCharacters(in: .whitespacesAndNewlines),
              !license.isEmpty else { return nil }
        let normalized = license.uppercased()
        if normalized == "UNLICENSED" || normalized.contains("PROPRIETARY") { return false }
        return true
    }

    private func record(
        _ candidate: ApplicationCandidate,
        status: UpdateSupportStatus,
        mechanism: UpdateMechanismKind,
        mechanismName: String,
        confidence: DetectionConfidence,
        evidence: [DetectionEvidence],
        parentManagerBundleIdentifier: String? = nil,
        parentManagerName: String? = nil,
        vendorURL: URL? = nil,
        isOpenSource: Bool? = nil,
        sourceCodeURL: URL? = nil,
        releaseNotesURL: URL? = nil,
        updateFeedURL: URL? = nil,
        versionProvider: CatalogVersionProvider? = nil,
        versionProviders: [CatalogVersionProvider] = [],
        catalogEntryID: String? = nil,
        releaseChannel: ReleaseChannel? = nil,
        updateCheck: UpdateCheckResult? = nil,
        notes: String
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: candidate.inventoryID,
            path: candidate.path,
            name: candidate.name,
            bundleIdentifier: candidate.bundleIdentifier,
            displayVersion: candidate.displayVersion,
            buildVersion: candidate.buildVersion,
            teamIdentifier: candidate.teamIdentifier,
            status: status,
            mechanism: mechanism,
            mechanismName: mechanismName,
            confidence: confidence,
            evidence: evidence,
            parentInventoryID: candidate.parentInventoryID,
            parentManagerBundleIdentifier: parentManagerBundleIdentifier,
            parentManagerName: parentManagerName,
            vendorURL: vendorURL,
            updateFeedURL: updateFeedURL,
            versionProvider: versionProvider,
            versionProviders: versionProviders,
            catalogEntryID: catalogEntryID,
            isOpenSource: isOpenSource,
            sourceCodeURL: sourceCodeURL,
            releaseNotesURL: releaseNotesURL,
            iconPath: candidate.info["IconPath"].flatMap { $0.isEmpty ? nil : $0 },
            notes: notes,
            kind: candidate.kind,
            gamePlatform: candidate.gamePlatform,
            packageProvenance: candidate.packageProvenance,
            releaseChannel: releaseChannel ?? ReleaseChannel.detect(
                version: candidate.displayVersion,
                explicitName: candidate.info["UpdateChannel"]
                    ?? candidate.info["ReleaseChannel"]
                    ?? versionProviders.first?.releaseChannel?.rawValue
                    ?? versionProvider?.releaseChannel?.rawValue,
                bundleIdentifier: candidate.bundleIdentifier
            ),
            updateCheck: updateCheck,
            discovery: DiscoveryFacts(candidate.info)
        )
    }

    private func catalogRecord(
        _ candidate: ApplicationCandidate,
        entry: CatalogEntry,
        revision: Int
    ) -> InstalledApplication {
        let parentBundleIdentifier = entry.mechanism.managerBundleIdentifier
            ?? candidate.parentManagerBundleIdentifier
        let parentName = candidate.info["ParentDisplayName"]
            ?? parentBundleIdentifier.map { managerDescriptor(for: $0).name }
        return record(
            candidate,
            status: entry.support.appStatus,
            mechanism: entry.mechanism.type,
            mechanismName: entry.mechanism.name,
            confidence: .verified,
            evidence: [
                .init(title: String(localized: "Catalog rule", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: String(localized: "Matched catalog rule:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(entry.id) · \(revision)", level: .confirmed),
                .init(title: String(localized: "Signing identity", bundle: AppL10n.bundle, locale: AppL10n.locale), detail: candidate.teamIdentifier ?? String(localized: "Not available", bundle: AppL10n.bundle, locale: AppL10n.locale), level: candidate.teamIdentifier == nil ? .warning : .confirmed)
            ],
            parentManagerBundleIdentifier: parentBundleIdentifier,
            parentManagerName: parentName,
            vendorURL: entry.vendorURL,
            isOpenSource: entry.openSource,
            sourceCodeURL: entry.sourceCodeURL,
            releaseNotesURL: entry.releaseNotesURL,
            updateFeedURL: entry.mechanism.feedURL ?? entry.mechanism.versionProviders.first?.url,
            versionProviders: entry.mechanism.versionProviders,
            catalogEntryID: entry.id,
            notes: entry.notes ?? String(localized: "This application is classified by the remote catalog.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        )
    }

    private func managerDescriptor(for bundleIdentifier: String) -> ManagerDescriptor {
        if bundleIdentifier == "com.todesktop.241012ess7yxs0e" {
            return ManagerDescriptor(
                name: "Comfy Desktop",
                notes: String(localized: "Comfy Desktop owns this ComfyUI installation and can update it independently from the desktop shell.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "Comfy Desktop records this installation in its local manager state.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open Comfy Desktop to apply or roll back the ComfyUI update.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
        return knownManagerDescriptor(for: bundleIdentifier) ?? ManagerDescriptor(
            name: String(localized: "External Manager", bundle: AppL10n.bundle, locale: AppL10n.locale),
            notes: String(localized: "Update availability and installation are owned by the parent manager.", bundle: AppL10n.bundle, locale: AppL10n.locale),
            managerEvidence: String(localized: "This application manages nested software installations.", bundle: AppL10n.bundle, locale: AppL10n.locale),
            managerNotes: String(localized: "Open the manager to inspect and apply updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        )
    }

    private func knownManagerDescriptor(for bundleIdentifier: String) -> ManagerDescriptor? {
        let additionalManagers = [
            "com.setapp.DesktopClient": "Setapp",
            "com.jetbrains.toolbox": "JetBrains Toolbox",
            "com.heroicgameslauncher.hgl": "Heroic",
            "com.isaacmarovitz.Whisky": "Whisky",
            "com.codeweavers.CrossOver": "CrossOver",
            "com.paulthetall.portingkit": "Porting Kit",
            "io.github.kegworks-app.kegworks": "Kegworks",
            "app.getmythic.Mythic": "Mythic",
            "org.winehq.wine-stable": "Wine",
            "com.docker.docker": "Docker",
            "dev.kdrag0n.OrbStack": "OrbStack",
            "com.utmapp.UTM": "UTM",
            "com.vmware.fusion": "VMware Fusion",
            "com.parallels.desktop.console": "Parallels Desktop",
            "org.virtualbox.app.VirtualBox": "VirtualBox",
            "io.lima-vm.lima": "Lima",
            "io.colima.colima": "Colima",
            "net.battle.app": "Battle.net",
            "com.ea.mac.eaapp": "EA App",
            "com.riotgames.RiotGames.RiotClient": "Riot Client",
            "io.itch.mac": "itch",
            "com.modrinth.theseus": "Modrinth App",
            "com.overwolf.curseforge": "CurseForge",
            "com.libretro.RetroArch": "RetroArch"
        ]
        if let name = additionalManagers[bundleIdentifier] {
            return ManagerDescriptor(name: name,
                notes: String(localized: "Update availability and installation are owned by the parent manager.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "This application manages nested software installations.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open the manager to inspect and apply updates.", bundle: AppL10n.bundle, locale: AppL10n.locale))
        }
        return switch bundleIdentifier {
        case "com.unity3d.unityhub":
            ManagerDescriptor(
                name: "Unity Hub",
                notes: String(localized: "Unity can keep multiple editor releases side by side. A newer release may be a separate installation rather than an in-place update.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "Unity Hub owns Unity Editor installations.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open Unity Hub to manage installed editor versions and modules.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case "com.microsoft.autoupdate2":
            ManagerDescriptor(
                name: "Microsoft AutoUpdate",
                notes: String(localized: "Microsoft AutoUpdate owns availability checks and installation for this Microsoft application.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "The catalog associates this application with Microsoft AutoUpdate.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open Microsoft AutoUpdate to inspect and apply updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case "com.microsoft.VSCode":
            ManagerDescriptor(
                name: "Visual Studio Code",
                notes: String(localized: "Visual Studio Code owns installation and activation of this extension.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "The component is recorded in VS Code's extension registry.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open VS Code Extensions to install or remove extension updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case "org.prismlauncher.PrismLauncher":
            ManagerDescriptor(
                name: "Prism Launcher",
                notes: String(localized: "Prism Launcher owns this Minecraft instance, loaders, mods, shaders, and resource packs. Update Atlas does not infer compatible content updates from filenames.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "The instance is recorded in Prism Launcher's local instance registry.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open Prism Launcher to manage Minecraft, loaders, and instance updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case "com.valvesoftware.steam":
            ManagerDescriptor(
                name: "Steam",
                notes: String(localized: "Steam owns this game's update availability and installation. Update Atlas does not offer a separate update action.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "Steam owns games installed in its library folders.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open Steam to inspect downloads and manage game updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case "com.gog.galaxy":
            ManagerDescriptor(
                name: "GOG Galaxy",
                notes: String(localized: "GOG Galaxy owns this game's update availability and installation. Update Atlas does not offer a separate update action.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "GOG Galaxy owns games installed in its library folders.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open GOG Galaxy to inspect and manage game updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case "com.epicgames.EpicGamesLauncher":
            ManagerDescriptor(
                name: "Epic Games Launcher",
                notes: String(localized: "Epic Games Launcher owns this game's installation and update state.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerEvidence: String(localized: "The game is registered in an Epic Games Launcher library.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                managerNotes: String(localized: "Open Epic Games Launcher to inspect downloads and apply game updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        default:
            nil
        }
    }

    private func hasAppStoreReceipt(_ candidate: ApplicationCandidate) -> Bool {
        FileManager.default.fileExists(atPath: candidate.path + "/Contents/_MASReceipt/receipt")
            || FileManager.default.fileExists(atPath: candidate.path + "/WrappedBundle/_MASReceipt/receipt")
            || FileManager.default.fileExists(atPath: candidate.path + "/Wrapper/iTunesMetadata.plist")
    }

    private func appStoreLookupURL(for candidate: ApplicationCandidate) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        let country = candidate.info["AppStoreCountry"] ?? "tr"
        if let itemID = candidate.info["AppStoreItemID"] {
            components?.queryItems = [
                URLQueryItem(name: "id", value: itemID),
                URLQueryItem(name: "country", value: country)
            ]
        } else {
            components?.queryItems = [
                URLQueryItem(name: "bundleId", value: candidate.bundleIdentifier),
                URLQueryItem(name: "country", value: country)
            ]
        }
        return components?.url
    }

    private func visualStudioMarketplaceURL(identifier: String) -> URL? {
        let parts = identifier.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              var url = URL(string: "https://www.vscode-unpkg.net/_gallery") else { return nil }
        url.appendPathComponent(parts[0])
        url.appendPathComponent(parts[1])
        url.appendPathComponent("latest")
        return url
    }

    private func hasFramework(named name: String, candidate: ApplicationCandidate) -> Bool {
        FileManager.default.fileExists(atPath: candidate.path + "/Contents/Frameworks/" + name)
    }

    private func isGoogleUpdaterManaged(_ candidate: ApplicationCandidate) -> Bool {
        candidate.info["KSUpdateURL"] != nil
            || FileManager.default.fileExists(
                atPath: candidate.path + "/Contents/Frameworks/Google Chrome Framework.framework"
            )
    }

    private func isHomebrewManaged(_ candidate: ApplicationCandidate) -> Bool {
        let url = URL(fileURLWithPath: candidate.path)
        let fileManager = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: candidate.path) else {
            return candidate.path.contains("/Caskroom/")
        }
        return destination.contains("/Caskroom/")
    }

    private func electronConfiguration(at candidate: ApplicationCandidate) -> String? {
        let fileManager = FileManager.default
        let resources = URL(fileURLWithPath: candidate.path)
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        for name in ["app-update.yml", "app-update.yaml"] {
            let url = resources.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { return url.lastPathComponent }
        }
        return nil
    }
}

private struct ManagerDescriptor {
    let name: String
    let notes: String
    let managerEvidence: String
    let managerNotes: String
}
