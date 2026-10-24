import Foundation

struct UpdateCheckService: Sendable {
    private static let maximumResponseSize = 2 * 1_024 * 1_024
    private let session: URLSession

    private let releasePolicyOverride: Bool?
    init(session: URLSession? = nil, allowPrereleaseForStable: Bool? = nil) {
        self.session = session ?? Self.makeSession()
        self.releasePolicyOverride = allowPrereleaseForStable
    }

    func check(_ applications: [InstalledApplication], control: ScanControl = ScanControl(),
               progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [InstalledApplication] {
        // Snapshot policy once for the whole scan; the CLI supplies the GUI suite value.
        let checker = UpdateCheckService(session: session, allowPrereleaseForStable: allowPrereleaseForStable)
        progress(0, applications.count)
        let task = Task {
            await withTaskGroup(of: (String, UpdateCheckResult).self) { group in
                var next = 0
                func enqueue(_ application: InstalledApplication) {
                    group.addTask {
                        guard !Task.isCancelled, !control.shouldStop else {
                            return (application.id, checker.failure(application, source: nil,
                                detail: String(localized: "The update check did not complete. Scan again to retry.", bundle: AppL10n.bundle, locale: AppL10n.locale)))
                        }
                        return (application.id, await checker.check(application))
                    }
                }
                while next < min(8, applications.count) { enqueue(applications[next]); next += 1 }
                var completed = 0
                var results: [String: UpdateCheckResult] = [:]
                for await (id, result) in group {
                    results[id] = result
                    completed += 1
                    progress(completed, applications.count)
                    if next < applications.count { enqueue(applications[next]); next += 1 }
                }
                return applications.map { application in
                    var checked = application
                    if let result = results[application.id] { checked.updateCheck = result }
                    return checked
                }
            }
        }
        let timeout = Task {
            do { try await Task.sleep(until: control.deadline, clock: .continuous) }
            catch { return }
            task.cancel()
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func check(_ application: InstalledApplication) async -> UpdateCheckResult {
        if application.updateCheck.source == .steamManifest,
           application.updateCheck.availability == .updateAvailable {
            return application.updateCheck
        }
        if let provenance = application.packageProvenance,
           !["com.google.android.studio", "Qisda.DDPM"].contains(application.bundleIdentifier) {
            return packageManagerResult(application: application, provenance: provenance)
        }

        if application.mechanism == .system {
            return UpdateCheckResult(
                availability: .managedBySystem,
                installedVersion: application.displayVersion,
                latestVersion: nil,
                checkedAt: Date(),
                source: nil,
                detail: String(localized: "Apple delivers this application as part of macOS. Its version follows Software Update.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        switch application.status {
        case .supported:
            break
        case .managedExternally:
            return .managedExternally(
                installedVersion: application.displayVersion,
                detail: String(localized: "Update ownership belongs to", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(application.mechanismName). "
                    + String(localized: "Open its manager to inspect or install updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case .needsCatalog, .unsupported:
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "No supported update source was found. No freshness claim is made.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case .checkFailed:
            return failure(
                application,
                source: nil,
                detail: String(localized: "The update-source check failed during detection and should be retried.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        // A cached revision-11 catalog can still select qBittorrent's old cross-platform
        // GitHub tag. Never surface that tag as a Mac update while a newer DMG is absent.
        if application.bundleIdentifier == "org.qbittorrent.qBittorrent",
           application.catalogEntryID == "qbittorrent-macos-stable",
           application.versionProviders.contains(where: { $0.type == .githubLatestRelease }),
           let url = URL(string: "https://www.qbittorrent.org/download") {
            return await checkPlatformDownloadPage(
                application,
                provider: CatalogVersionProvider(
                    type: .platformDownloadPage,
                    url: url,
                    channel: "stable",
                    targetPlatform: "macOS",
                    versionRegex: #"Download\s+qBittorrent\s+v([0-9]+(?:\.[0-9]+){1,3})(?![A-Za-z0-9._-])"#,
                    releaseChannel: .stable
                )
            )
        }

        if !application.versionProviders.isEmpty {
            var failures: [UpdateCheckResult] = []
            for (index, provider) in application.versionProviders.enumerated() {
                let result = await check(application, with: provider)
                if result.availability != .checkFailed {
                    guard index > 0 else { return result }
                    return result.withDetail(
                        String(localized: "A fallback update source succeeded.", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(result.detail)"
                    )
                }
                failures.append(result)
            }

            let summary = failures.map(\.detail).joined(separator: " ")
            return failure(
                application,
                source: failures.last?.source,
                detail: String(localized: "All configured update sources failed.", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(summary)"
            )
        }

        switch application.mechanism {
        case .appStore:
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "The App Store identity is awaiting catalog source resolution.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )

        case .homebrew, .npm, .python, .pipx, .uvTool, .cargo:
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "Package-manager provenance must be resolved before a safe version query can run.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )

        case .sparkle, .googleUpdater, .squirrel, .githubReleases, .ideExtension, .publisherCLIInstaller,
             .website, .externalManager, .system, .unknown:
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "The detected mechanism is awaiting a verified catalog source chain.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
    }

    private func check(
        _ application: InstalledApplication,
        with provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        switch provider.type {
        case .sparkleAppcast:
            return await checkSparkle(application, feedURL: provider.url)
        case .chromeVersionHistory:
            let channel = provider.channel
                ?? Self.chromeChannel(bundleIdentifier: application.bundleIdentifier)
                ?? "stable"
            return await checkChrome(application, channel: channel)
        case .githubLatestRelease:
            return await checkGitHubRelease(application, provider: provider)
        case .platformDownloadPage:
            return await checkPlatformDownloadPage(application, provider: provider)
        case .githubCommitCompare:
            return await checkGitHubCommitCompare(application, provider: provider)
        case .electronYAML:
            return await checkElectronManifest(application, provider: provider)
        case .visualStudioCode:
            return await checkVisualStudioCode(application, provider: provider)
        case .blenderDownloadPage:
            return await checkBlender(application, provider: provider)
        case .homebrewCask:
            return await checkHomebrewCask(application, provider: provider)
        case .androidStudioReleasePage:
            return await checkAndroidStudioReleasePage(application, provider: provider)
        case .canonSupportRelease:
            return await checkCanonSupportRelease(application, provider: provider)
        case .appleAppStoreLookup:
            return await checkAppStore(application, provider: provider)
        case .jsonVersion:
            return await checkJSONVersion(application, provider: provider)
        case .visualStudioMarketplace:
            return await checkVisualStudioMarketplace(application, provider: provider)
        case .minecraftVersionManifest:
            return await checkMinecraftVersion(application, provider: provider)
        }
    }

    private func checkGitHubCommitCompare(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        guard provider.url.host == "api.github.com",
              provider.url.path.hasPrefix("/repos/NousResearch/hermes-agent/compare/") else {
            return failure(application, source: .githubCompare,
                           detail: String(localized: "The GitHub comparison source is not the verified Hermes repository.", bundle: AppL10n.bundle, locale: AppL10n.locale))
        }
        do {
            let data = try await fetch(provider.url)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = response["status"] as? String,
                  let aheadBy = response["ahead_by"] as? Int else {
                return failure(application, source: .githubCompare,
                               detail: String(localized: "The GitHub comparison response was incomplete.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            }
            switch status {
            case "identical":
                return UpdateCheckResult(
                    availability: .upToDate,
                    installedVersion: application.displayVersion,
                    latestVersion: application.displayVersion,
                    checkedAt: Date(), source: .githubCompare,
                    detail: String(localized: "The installed Hermes Agent commit matches the official main branch.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            case "ahead" where aheadBy > 0:
                return UpdateCheckResult(
                    availability: .updateAvailable,
                    installedVersion: application.displayVersion,
                    latestVersion: "main (+\(aheadBy))",
                    checkedAt: Date(), source: .githubCompare,
                    detail: String(localized: "The official Hermes Agent main branch has newer commits. Hermes owns the update.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            case "behind", "diverged":
                return .sourcePending(
                    installedVersion: application.displayVersion,
                    detail: String(localized: "This Hermes Agent checkout is ahead of or diverged from main; Update Atlas cannot recommend replacing it.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            default:
                return failure(application, source: .githubCompare,
                               detail: String(localized: "The GitHub comparison returned an unknown revision state.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            }
        } catch {
            return failure(application, source: .githubCompare,
                           detail: String(localized: "Hermes Agent GitHub comparison failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)")
        }
    }

    private func packageManagerResult(
        application: InstalledApplication,
        provenance: PackageProvenance
    ) -> UpdateCheckResult {
        let now = Date()
        guard let isOutdated = provenance.isOutdated else {
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: provenance.manager.title + " "
                    + String(localized: "records this installation, but no verified latest version is available yet.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        if isOutdated,
           let latestVersion = provenance.latestVersion,
           VersionComparator.isSame(latestVersion, application.displayVersion) {
            return UpdateCheckResult(
                availability: .upToDate,
                installedVersion: application.displayVersion,
                latestVersion: latestVersion,
                checkedAt: now,
                source: .packageManager,
                detail: String(localized: "The provider reported the same installed and latest version; no update is shown.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        // `npm outdated` also lists a package whose `latest` dist-tag is older than the installed
        // prerelease; offering that would be a downgrade.
        if isOutdated, provenance.manager == .npm,
           let latestVersion = provenance.latestVersion,
           Self.hasComparableVersion(latestVersion), Self.hasComparableVersion(application.displayVersion),
           !VersionComparator.isNewer(latestVersion, than: application.displayVersion) {
            return UpdateCheckResult(
                availability: .upToDate,
                installedVersion: application.displayVersion,
                latestVersion: latestVersion,
                checkedAt: now,
                source: .packageManager,
                detail: String(localized: "The installed version is newer than the latest release the package manager offers; no update is shown.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        return UpdateCheckResult(
            availability: isOutdated ? .updateAvailable : .upToDate,
            installedVersion: application.displayVersion,
            latestVersion: provenance.latestVersion ?? (isOutdated ? nil : application.displayVersion),
            checkedAt: now,
            source: .packageManager,
            detail: isOutdated
                ? provenance.manager.title + " " + String(localized: "reports a newer release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                : provenance.manager.title + " " + String(localized: "reports this item as current.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        )
    }

    private func checkSparkle(
        _ application: InstalledApplication,
        feedURL: URL
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(feedURL)
            let appcast = SparkleAppcastParser.parse(
                in: data,
                desiredChannel: application.releaseChannel,
                allowPrereleaseForStable: allowPrereleaseForStable
            )
            if appcast?.itemCount == 0 {
                return UpdateCheckResult(
                    availability: .sourcePending,
                    installedVersion: application.displayVersion,
                    latestVersion: nil,
                    checkedAt: Date(),
                    source: .sparkleAppcast,
                    detail: String(localized: "The appcast did not contain a release compatible with the installed channel.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            guard let release = appcast?.latestRelease else {
                return failure(
                    application,
                    source: .sparkleAppcast,
                    detail: String(localized: "The appcast did not contain a release compatible with the installed channel.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }

            guard Self.hasComparableVersion(application.buildVersion) else {
                return unreadableInstalledVersion(application, source: .sparkleAppcast)
            }
            let available = VersionComparator.isNewer(
                release.buildVersion,
                than: application.buildVersion
            )
            return UpdateCheckResult(
                availability: available ? .updateAvailable : .upToDate,
                installedVersion: application.displayVersion,
                latestVersion: release.displayVersion,
                checkedAt: Date(),
                source: .sparkleAppcast,
                detail: available
                    ? String(localized: "The Sparkle appcast contains a newer build.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    : String(localized: "The installed build matches or exceeds the latest Sparkle release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: release.channel
            )
        } catch {
            return failure(
                application,
                source: .sparkleAppcast,
                detail: String(localized: "Sparkle feed check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkChrome(
        _ application: InstalledApplication,
        channel: String
    ) async -> UpdateCheckResult {
        #if arch(arm64)
        let platform = "mac_arm64"
        #else
        let platform = "mac"
        #endif

        guard let url = Self.chromeReleaseURL(platform: platform, channel: channel) else {
            return failure(
                application,
                source: .chromeVersionHistory,
                detail: String(localized: "The Chrome version endpoint could not be constructed.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }

        do {
            let data = try await fetch(url)
            guard let latest = try Self.fullyRolledOutChromeVersion(from: data) else {
                return failure(
                    application,
                    source: .chromeVersionHistory,
                    detail: String(localized: "Google Version History returned no fully rolled-out release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            guard Self.hasComparableVersion(application.displayVersion) else {
                return unreadableInstalledVersion(application, source: .chromeVersionHistory)
            }
            let available = VersionComparator.isNewer(latest, than: application.displayVersion)
            return UpdateCheckResult(
                availability: available ? .updateAvailable : .upToDate,
                installedVersion: application.displayVersion,
                latestVersion: latest,
                checkedAt: Date(),
                source: .chromeVersionHistory,
                detail: available
                    ? String(localized: "Google Version History reports a newer fully rolled-out release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    : String(localized: "The installed version matches or exceeds Google's latest fully rolled-out release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: ReleaseChannel(rawValue: channel)
            )
        } catch {
            return failure(
                application,
                source: .chromeVersionHistory,
                detail: String(localized: "Chrome version check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    static func chromeReleaseURL(platform: String, channel: String) -> URL? {
        var components = URLComponents(
            string: "https://versionhistory.googleapis.com/v1/chrome/platforms/\(platform)/channels/\(channel)/versions/all/releases"
        )
        components?.queryItems = [
            URLQueryItem(name: "filter", value: "fraction=1,endtime=none"),
            URLQueryItem(name: "order_by", value: "version desc"),
            URLQueryItem(name: "page_size", value: "1")
        ]
        return components?.url
    }

    static func fullyRolledOutChromeVersion(from data: Data) throws -> String? {
        let response = try JSONDecoder().decode(ChromeReleaseResponse.self, from: data)
        return response.releases.first(where: { $0.fraction >= 1 })?.version
    }

    private func checkPlatformDownloadPage(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        guard let platform = provider.targetPlatform,
              let pattern = provider.versionRegex else {
            return failure(application, source: .platformDownloads,
                           detail: String(localized: "The platform download rule is incomplete.", bundle: AppL10n.bundle, locale: AppL10n.locale))
        }
        do {
            let data = try await fetch(provider.url)
            guard let html = String(data: data, encoding: .utf8),
                  let version = Self.platformDownloadVersion(in: html, platform: platform, versionPattern: pattern) else {
                return failure(application, source: .platformDownloads,
                               detail: String(localized: "The official download page did not confirm a version for this platform.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            }
            return versionResult(
                application,
                latestVersion: version,
                source: .platformDownloads,
                newerDetail: String(localized: "The official macOS download page offers a newer compatible build.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds the official macOS download.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseNotesURL: application.releaseNotesURL,
                releaseChannel: provider.releaseChannel
            )
        } catch {
            return failure(application, source: .platformDownloads,
                           detail: String(localized: "The official platform download check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)")
        }
    }

    static func platformDownloadVersion(in html: String, platform: String, versionPattern: String) -> String? {
        // Scope a version match to one platform heading. A global latest-version banner or
        // another OS section must never be interpreted as a compatible macOS binary.
        guard let headings = try? NSRegularExpression(
            pattern: #"<h[2-4]\b[^>]*>[\s\S]*?</h[2-4]>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = headings.matches(in: html, range: fullRange)
        guard let index = matches.firstIndex(where: { match in
            guard let range = Range(match.range, in: html) else { return false }
            let heading = String(html[range]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            return heading.localizedCaseInsensitiveContains(platform)
        }), let start = Range(matches[index].range, in: html)?.upperBound else { return nil }
        let end = index + 1 < matches.count
            ? Range(matches[index + 1].range, in: html)?.lowerBound ?? html.endIndex
            : html.endIndex
        guard start <= end else { return nil }
        let section = String(html[start..<end]).replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return firstVersionMatch(in: section, pattern: versionPattern)
    }

    private static func firstVersionMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              regex.numberOfCaptureGroups >= 1,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range])
        return value.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil ? value : nil
    }

    private func checkGitHubRelease(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            let releases: [GitHubLatestRelease]
            if let response = try? JSONDecoder().decode(GitHubLatestRelease.self, from: data) {
                releases = [response]
            } else {
                releases = try JSONDecoder().decode([GitHubLatestRelease].self, from: data)
            }
            let compatible = releases.filter { release in
                guard release.draft != true else { return false }
                guard provider.includePrerelease == true || release.prerelease != true else { return false }
                guard githubVersion(for: release, provider: provider) != nil else { return false }
                let channel = releaseChannel(for: release, provider: provider)
                return ReleaseChannelPolicy.allows(
                    candidate: channel,
                    for: application.releaseChannel,
                    allowPrereleaseForStable: allowPrereleaseForStable
                )
            }
            guard let response = compatible.max(by: {
                guard let lhs = githubVersion(for: $0, provider: provider),
                      let rhs = githubVersion(for: $1, provider: provider) else { return false }
                return VersionComparator.compare(lhs, rhs) == .orderedAscending
            }) else {
                return failure(
                    application,
                    source: .githubReleases,
                    detail: String(localized: "GitHub returned no release compatible with the installed channel.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            guard let latestVersion = githubVersion(for: response, provider: provider) else {
                return failure(
                    application,
                    source: .githubReleases,
                    detail: String(localized: "GitHub returned releases, but none exposed a comparable product version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: latestVersion,
                source: .githubReleases,
                newerDetail: String(localized: "GitHub Releases reports a newer release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds the latest GitHub release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseNotesURL: response.htmlURL ?? application.releaseNotesURL,
                releaseNotesSummary: response.body,
                releaseChannel: releaseChannel(for: response, provider: provider)
            )
        } catch {
            return failure(
                application,
                source: .githubReleases,
                detail: String(localized: "GitHub release check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkElectronManifest(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            guard let text = String(data: data, encoding: .utf8),
                  let latest = firstMatch(
                    in: text,
                    pattern: #"(?m)^version:\s*['"]?([^'"\s]+)"#
                  ) else {
                return failure(
                    application,
                    source: .electronManifest,
                    detail: String(localized: "The Electron manifest has no version field.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .electronManifest,
                newerDetail: String(localized: "The Electron release manifest reports a newer build.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds the Electron release manifest.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.releaseChannel ?? .stable
            )
        } catch {
            return failure(
                application,
                source: .electronManifest,
                detail: String(localized: "Electron manifest check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkVisualStudioCode(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            let response = try JSONDecoder().decode(VisualStudioCodeRelease.self, from: data)
            guard let latest = response.productVersion ?? response.name else {
                return failure(
                    application,
                    source: .visualStudioCode,
                    detail: String(localized: "The VS Code update service returned no product version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .visualStudioCode,
                newerDetail: String(localized: "Microsoft's VS Code update service reports a newer release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds Microsoft's latest VS Code release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.releaseChannel ?? ReleaseChannel(rawValue: provider.channel ?? "stable")
            )
        } catch {
            return failure(
                application,
                source: .visualStudioCode,
                detail: String(localized: "VS Code update check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkBlender(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            guard let html = String(data: data, encoding: .utf8),
                  let latest = firstMatch(
                    in: html,
                    pattern: #"blender-([0-9]+\.[0-9]+\.[0-9]+)-macos-(?:arm64|x64)\.dmg"#
                  ) else {
                return failure(
                    application,
                    source: .blenderDownloads,
                    detail: String(localized: "Blender's download page did not expose a macOS release version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .blenderDownloads,
                newerDetail: String(localized: "Blender's official download page reports a newer macOS release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds Blender's current macOS release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.releaseChannel ?? .stable
            )
        } catch {
            return failure(
                application,
                source: .blenderDownloads,
                detail: String(localized: "Blender update check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkHomebrewCask(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        if application.bundleIdentifier == "Qisda.DDPM",
           provider.url.absoluteString != "https://formulae.brew.sh/api/cask/ddpm.json" {
            return failure(
                application, source: .homebrewCaskCatalog,
                detail: String(localized: "Dell's catalog source does not match the reviewed DDPM package.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
        do {
            let data = try await fetch(provider.url)
            let response = try JSONDecoder().decode(HomebrewCaskRelease.self, from: data)
            let latest = response.version.split(separator: ",", maxSplits: 1).first.map(String.init)
            guard let latest, !latest.isEmpty, latest != "latest" else {
                return failure(
                    application,
                    source: .homebrewCaskCatalog,
                    detail: String(localized: "The Homebrew cask catalog returned no comparable version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            if application.bundleIdentifier == "com.google.android.studio" {
                return androidStudioCaskResult(application, latestVersion: latest)
            }
            if application.bundleIdentifier == "Qisda.DDPM" {
                return dellDDPMCaskResult(application, latestVersion: latest)
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .homebrewCaskCatalog,
                newerDetail: String(localized: "The Homebrew cask catalog reports a newer vendor release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds the version tracked by Homebrew Cask.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.releaseChannel ?? .stable
            )
        } catch {
            return failure(
                application,
                source: .homebrewCaskCatalog,
                detail: String(localized: "Homebrew cask catalog check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkAndroidStudioReleasePage(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            guard let release = AndroidStudioOfficialReleaseParser.latestStable(from: data) else {
                return failure(
                    application, source: .androidStudioOfficial,
                    detail: String(localized: "Google's Android Studio stable release page did not contain a comparable version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            if release.patch != nil,
               VersionComparator.isSame(release.version, application.displayVersion) {
                return .sourcePending(
                    installedVersion: application.displayVersion,
                    detail: String(localized: "Google lists a patch within the installed Android Studio release family, but the bundle does not expose a comparable patch number.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: release.version,
                source: .androidStudioOfficial,
                newerDetail: String(localized: "Google's Android Studio stable release page reports a newer release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed Android Studio release matches or exceeds Google's stable release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: .stable
            )
        } catch {
            return failure(
                application, source: .androidStudioOfficial,
                detail: String(localized: "Android Studio official release check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func androidStudioCaskResult(
        _ application: InstalledApplication,
        latestVersion: String
    ) -> UpdateCheckResult {
        guard let cask = AndroidStudioCaskVersion(latestVersion),
              let installed = AndroidStudioCaskVersion(application.displayVersion) else {
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "The Homebrew Android Studio version could not be compared with the installed release family.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
        switch VersionComparator.compare(cask.releaseFamily, installed.releaseFamily) {
        case .orderedAscending:
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "Homebrew is tracking an older Android Studio release; it cannot confirm the installed release is current.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case .orderedSame where cask.packageRevision != nil:
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "Homebrew's extra Android Studio package revision is not comparable with the installed IDE release version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case .orderedSame, .orderedDescending:
            return versionResult(
                application,
                latestVersion: cask.releaseFamily,
                source: .homebrewCaskCatalog,
                newerDetail: String(localized: "Homebrew tracks a newer Android Studio release family.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed Android Studio release matches Homebrew's tracked release family.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: .stable
            )
        }
    }

    private func dellDDPMCaskResult(
        _ application: InstalledApplication,
        latestVersion: String
    ) -> UpdateCheckResult {
        // Dell's app reports e.g. 2.3.0.0023 while the cask may report
        // 2.3.0.2004. Those fourth components are not interchangeable.
        guard let tracked = DellDDPMVersion(latestVersion),
              let installed = DellDDPMVersion(application.displayVersion) else {
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "Dell's installed and catalog versions could not be safely compared.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
        guard VersionComparator.isNewer(tracked.releaseFamily, than: installed.releaseFamily) else {
            return .sourcePending(
                installedVersion: application.displayVersion,
                detail: String(localized: "Dell's catalog uses a different package revision; only a newer software release family proves an update.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
        return versionResult(
            application,
            latestVersion: tracked.releaseFamily,
            source: .homebrewCaskCatalog,
            newerDetail: String(localized: "Homebrew tracks a newer Dell software release family.", bundle: AppL10n.bundle, locale: AppL10n.locale),
            currentDetail: String(localized: "Dell's installed software matches the tracked release family.", bundle: AppL10n.bundle, locale: AppL10n.locale),
            releaseChannel: .stable
        )
    }

    private func checkCanonSupportRelease(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        // Canon assigns a new issue URL per release; this page proves a release
        // exists, but matching it cannot prove that no newer issue exists.
        guard application.bundleIdentifier == "jp.co.canon.ij.scanutility2",
              provider.url.absoluteString == "https://asia.canon/en/support/0200660310/" else {
            return failure(
                application, source: .canonSupport,
                detail: String(localized: "Canon's update source does not match the verified utility page.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
        do {
            let data = try await fetch(provider.url)
            guard let html = String(data: data, encoding: .utf8),
                  let published = firstMatch(
                    in: html,
                    pattern: #"IJ\s+Scan\s+Utility\s*2\s+Ver\.?\s*([0-9]+(?:\.[0-9]+){1,3})\s*\(Mac\)"#
                  ) else {
                return failure(
                    application, source: .canonSupport,
                    detail: String(localized: "Canon's utility page did not contain a comparable macOS software version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            guard VersionComparator.isNewer(published, than: application.displayVersion) else {
                return .sourcePending(
                    installedVersion: application.displayVersion,
                    detail: String(localized: "The installed Canon utility is not older than this published release, but this fixed page cannot prove it is the latest release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: published,
                source: .canonSupport,
                newerDetail: String(localized: "Canon's official support page confirms a newer IJ Scan Utility2 release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed Canon utility matches this published release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: .stable
            )
        } catch {
            return failure(
                application, source: .canonSupport,
                detail: String(localized: "Canon support page check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    /// Resolves a real product page, matching bundle identity rather than the first search result.
    func appStorePage(for application: InstalledApplication) async throws -> URL {
        guard application.mechanism == .appStore else { throw URLError(.unsupportedURL) }
        if let page = AppStoreDestination.validatedPage(application.updateCheck.releaseNotesURL) { return page }
        guard let provider = application.versionProviders.first(where: { $0.type == .appleAppStoreLookup }),
              provider.url.scheme == "https", provider.url.host == "itunes.apple.com", provider.url.path == "/lookup" else {
            throw URLError(.unsupportedURL)
        }
        let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: await fetch(provider.url))
        guard let release = response.results.first(where: { $0.bundleIdentifier == application.bundleIdentifier }),
              let page = AppStoreDestination.validatedPage(release.trackViewURL) else { throw URLError(.resourceUnavailable) }
        return page
    }

    private func checkAppStore(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            let release = response.results.first(where: {
                $0.bundleIdentifier == application.bundleIdentifier
            })
            guard let latest = release?.version, !latest.isEmpty else {
                return failure(
                    application,
                    source: .appStore,
                    detail: String(localized: "The App Store lookup returned no matching application release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .appStore,
                newerDetail: String(localized: "The App Store storefront reports a newer release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds the App Store storefront release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseNotesURL: AppStoreDestination.validatedPage(release?.trackViewURL),
                releaseNotesSummary: release?.releaseNotes,
                releaseChannel: provider.releaseChannel ?? .stable
            )
        } catch {
            return failure(
                application,
                source: .appStore,
                detail: String(localized: "App Store version check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkJSONVersion(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            let document = try JSONSerialization.jsonObject(with: data)
            let keyPath = provider.channel ?? "version"
            guard let latest = jsonValue(at: keyPath, in: document) else {
                return failure(
                    application,
                    source: .jsonDocument,
                    detail: String(localized: "The vendor JSON document has no comparable value at", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(keyPath)."
                )
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .jsonDocument,
                newerDetail: String(localized: "The vendor release document reports a newer release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed version matches or exceeds the vendor release document.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.releaseChannel
            )
        } catch {
            return failure(
                application,
                source: .jsonDocument,
                detail: String(localized: "Vendor release document check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkVisualStudioMarketplace(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            let response = try JSONDecoder().decode(VisualStudioMarketplaceExtension.self, from: data)
            let target = provider.targetPlatform.flatMap {
                $0 == "universal" || $0 == "undefined" ? nil : $0
            }
            let allowPrerelease = provider.includePrerelease == true
            let compatible = response.versions.filter { version in
                (allowPrerelease || !version.isPrerelease)
                    && isCompatible(engine: version.engine, withHostVersion: provider.hostVersion)
            }
            let platformSpecific = target.map { wanted in
                compatible.filter { $0.targetPlatform == wanted }
            } ?? []
            let universal = compatible.filter { $0.targetPlatform == nil }
            let candidates = platformSpecific.isEmpty ? universal : platformSpecific
            guard let latest = candidates.max(by: {
                VersionComparator.compare($0.version, $1.version) == .orderedAscending
            })?.version else {
                return failure(
                    application,
                    source: .ideMarketplace,
                    detail: String(localized: "The Marketplace returned no release compatible with this IDE, platform, and channel.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
            }
            return versionResult(
                application,
                latestVersion: latest,
                source: .ideMarketplace,
                newerDetail: String(localized: "VS Code Marketplace reports a compatible extension update.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "The installed extension matches the latest compatible Marketplace release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.releaseChannel ?? application.releaseChannel
            )
        } catch {
            return failure(
                application,
                source: .ideMarketplace,
                detail: String(localized: "VS Code extension check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func checkMinecraftVersion(
        _ application: InstalledApplication,
        provider: CatalogVersionProvider
    ) async -> UpdateCheckResult {
        do {
            let data = try await fetch(provider.url)
            let manifest = try JSONDecoder().decode(MinecraftVersionManifest.self, from: data)
            let latest = provider.channel == "snapshot"
                ? manifest.latest.snapshot
                : manifest.latest.release
            return versionResult(
                application,
                latestVersion: latest,
                source: .minecraftVersionManifest,
                newerDetail: String(localized: "Mojang reports a newer Minecraft release, but Prism owns instance migration and mod compatibility is not verified.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                currentDetail: String(localized: "This instance matches or exceeds Mojang's latest release.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseChannel: provider.channel == "snapshot" ? .nightly : .stable
            )
        } catch {
            return failure(
                application,
                source: .minecraftVersionManifest,
                detail: String(localized: "Minecraft version check failed:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)"
            )
        }
    }

    private func versionResult(
        _ application: InstalledApplication,
        latestVersion: String,
        source: UpdateCheckSource,
        newerDetail: String,
        currentDetail: String,
        releaseNotesURL: URL? = nil,
        releaseNotesSummary: String? = nil,
        releaseChannel: ReleaseChannel? = nil
    ) -> UpdateCheckResult {
        guard Self.hasComparableVersion(application.displayVersion) else {
            return unreadableInstalledVersion(application, source: source)
        }
        let candidateChannel = releaseChannel
            ?? ReleaseChannel.detect(version: latestVersion)
        let channelAllowed = ReleaseChannelPolicy.allows(
            candidate: candidateChannel,
            for: application.releaseChannel,
            allowPrereleaseForStable: allowPrereleaseForStable
        )
        let available = VersionComparator.isNewer(latestVersion, than: application.displayVersion)
        if available && !channelAllowed {
            return UpdateCheckResult(
                availability: .upToDate,
                installedVersion: application.displayVersion,
                latestVersion: nil,
                checkedAt: Date(),
                source: source,
                detail: String(localized: "A newer release exists on another channel, but this installation does not accept that channel.", bundle: AppL10n.bundle, locale: AppL10n.locale),
                releaseNotesURL: releaseNotesURL ?? application.releaseNotesURL,
                releaseNotesSummary: nil,
                releaseChannel: application.releaseChannel
            )
        }
        return UpdateCheckResult(
            availability: available ? .updateAvailable : .upToDate,
            installedVersion: application.displayVersion,
            latestVersion: latestVersion,
            checkedAt: Date(),
            source: source,
            detail: available ? newerDetail : currentDetail,
            releaseNotesURL: releaseNotesURL ?? application.releaseNotesURL,
            releaseNotesSummary: releaseNotesSummary,
            releaseChannel: candidateChannel
        )
    }

    /// A version without any digit ("", "Unknown" or its translation) cannot be compared;
    /// such an installation is never reported as current or outdated.
    static func hasComparableVersion(_ version: String) -> Bool {
        version.contains { $0.isASCII && $0.isNumber }
    }

    private func unreadableInstalledVersion(
        _ application: InstalledApplication,
        source: UpdateCheckSource
    ) -> UpdateCheckResult {
        UpdateCheckResult(
            availability: .sourcePending,
            installedVersion: application.displayVersion,
            latestVersion: nil,
            checkedAt: Date(),
            source: source,
            detail: String(localized: "The installed version could not be read, so it cannot be compared with the latest release.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        )
    }

    private var allowPrereleaseForStable: Bool {
        releasePolicyOverride ?? ReleaseChannelSettings.current(from: .standard)
    }

    private func releaseChannel(
        for release: GitHubLatestRelease,
        provider: CatalogVersionProvider
    ) -> ReleaseChannel {
        if let explicit = provider.releaseChannel { return explicit }
        if release.prerelease == true {
            let detected = ReleaseChannel.detect(version: release.tagName)
            return detected.isPrerelease ? detected : .beta
        }
        return ReleaseChannel.detect(version: release.tagName)
    }

    private func githubVersion(
        for release: GitHubLatestRelease,
        provider: CatalogVersionProvider
    ) -> String? {
        if let prefix = provider.versionPrefix,
           !release.tagName.hasPrefix(prefix) {
            return nil
        }
        if let pattern = provider.versionRegex {
            let source = [release.tagName, release.name].compactMap { $0 }.joined(separator: "\n")
            return firstMatch(in: source, pattern: pattern)
        }
        if let prefix = provider.versionPrefix {
            return String(release.tagName.dropFirst(prefix.count))
        }
        return release.tagName
    }

    private func firstMatch(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[capture])
    }

    private func jsonValue(at keyPath: String, in document: Any) -> String? {
        var current: Any = document
        for key in keyPath.split(separator: ".").map(String.init) {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else { return nil }
            current = next
        }
        if let value = current as? String { return value }
        if let value = current as? NSNumber { return value.stringValue }
        return nil
    }

    private func isCompatible(engine: String?, withHostVersion hostVersion: String?) -> Bool {
        guard let engine, let hostVersion,
              let minimum = firstMatch(in: engine, pattern: #"([0-9]+(?:\.[0-9]+)+)"#) else {
            return true
        }
        return VersionComparator.compare(hostVersion, minimum) != .orderedAscending
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("UpdateAtlas/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            return try await fetchBounded(request: request, maximumBytes: Self.maximumResponseSize)
        } catch let error as URLError where [
            .timedOut, .networkConnectionLost, .cannotConnectToHost
        ].contains(error.code) {
            return try await fetchBounded(request: request, maximumBytes: Self.maximumResponseSize)
        }
    }

    private func fetchBounded(request: URLRequest, maximumBytes: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if http.expectedContentLength > Int64(maximumBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(http.expectedContentLength), maximumBytes))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maximumBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
        }
        return data
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }

    private func failure(
        _ application: InstalledApplication,
        source: UpdateCheckSource?,
        detail: String
    ) -> UpdateCheckResult {
        UpdateCheckResult(
            availability: .checkFailed,
            installedVersion: application.displayVersion,
            latestVersion: nil,
            checkedAt: Date(),
            source: source,
            detail: detail
        )
    }

    private static func chromeChannel(bundleIdentifier: String) -> String? {
        switch bundleIdentifier {
        case "com.google.Chrome": "stable"
        case "com.google.Chrome.beta": "beta"
        case "com.google.Chrome.dev": "dev"
        case "com.google.Chrome.canary": "canary"
        default: nil
        }
    }
}

enum VersionComparator {
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    /// Release numbers compare component by component, padding the shorter one with zeros,
    /// so "2.0" equals "2.0.0". A prerelease suffix ("-beta.1", "rc1", "b2") sorts below the
    /// same release; any other suffix, such as a build number, keeps numeric text ordering.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard let leftVersion = ParsedVersion(left), let rightVersion = ParsedVersion(right) else {
            return left.compare(right, options: [.numeric, .caseInsensitive])
        }
        let maxCount = max(leftVersion.components.count, rightVersion.components.count)
        for index in 0..<maxCount {
            let result = compareNumber(
                index < leftVersion.components.count ? leftVersion.components[index] : "0",
                index < rightVersion.components.count ? rightVersion.components[index] : "0"
            )
            if result != .orderedSame { return result }
        }
        return compareSuffix(leftVersion.suffix, rightVersion.suffix)
    }

    private struct ParsedVersion {
        let components: [Substring]
        let suffix: Substring

        init?(_ text: String) {
            var components: [Substring] = []
            var index = text.startIndex
            while index < text.endIndex, text[index].isASCIIDigit {
                let start = index
                while index < text.endIndex, text[index].isASCIIDigit { index = text.index(after: index) }
                components.append(text[start..<index])
                let next = index < text.endIndex ? text.index(after: index) : index
                guard index < text.endIndex, text[index] == ".",
                      next < text.endIndex, text[next].isASCIIDigit else { break }
                index = next
            }
            guard !components.isEmpty else { return nil }
            self.components = components
            suffix = text[index...]
        }
    }

    private static func compareNumber(_ lhs: Substring, _ rhs: Substring) -> ComparisonResult {
        let left = lhs.drop { $0 == "0" }
        let right = rhs.drop { $0 == "0" }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private static func compareSuffix(_ lhs: Substring, _ rhs: Substring) -> ComparisonResult {
        switch (prerelease(lhs), prerelease(rhs)) {
        case (nil, nil):
            return String(lhs).compare(String(rhs), options: [.numeric, .caseInsensitive])
        case (.some, nil):
            return .orderedAscending
        case (nil, .some):
            return .orderedDescending
        case let (.some(left), .some(right)):
            if left.rank != right.rank { return left.rank < right.rank ? .orderedAscending : .orderedDescending }
            return left.rest.compare(right.rest, options: [.numeric, .caseInsensitive])
        }
    }

    /// Recognises "-beta.1", ".rc2", "b3" or " Alpha" and ranks dev < alpha < beta < preview < rc.
    private static func prerelease(_ suffix: Substring) -> (rank: Int, rest: String)? {
        let tag = suffix.drop { "-._~ ".contains($0) }.lowercased()
        let words = [("dev", 0), ("alpha", 1), ("beta", 2), ("preview", 3), ("pre", 3), ("rc", 4)]
        for (word, rank) in words where tag.hasPrefix(word) {
            return (rank, String(tag.dropFirst(word.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-._~ ")))
        }
        let rest = tag.dropFirst()
        if let letter = tag.first, letter == "a" || letter == "b", rest.first?.isASCIIDigit == true {
            return (letter == "a" ? 1 : 2, String(rest))
        }
        return nil
    }

    private static func normalized(_ version: String) -> String {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["release-", "version-", "ver-"] where normalized.lowercased().hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            break
        }
        if normalized.count > 1,
           normalized.first?.lowercased() == "v",
           normalized.dropFirst().first?.isNumber == true {
            return String(normalized.dropFirst())
        }
        return normalized
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

struct AndroidStudioCaskVersion {
    let releaseFamily: String
    let packageRevision: String?

    init?(_ rawVersion: String) {
        let version = rawVersion.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let components = version.split(separator: ".")
        guard (3...4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components[0].count == 4 else { return nil }
        releaseFamily = components.prefix(3).joined(separator: ".")
        packageRevision = components.count == 4 ? String(components[3]) : nil
    }
}

struct DellDDPMVersion {
    let releaseFamily: String

    init?(_ rawVersion: String) {
        let components = rawVersion.split(separator: ".")
        guard (3...4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        releaseFamily = components.prefix(3).joined(separator: ".")
    }
}

enum AndroidStudioOfficialReleaseParser {
    static func latestStable(from data: Data) -> (version: String, patch: Int?)? {
        guard let html = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"<h2\b[^>]*>\s*Download Android Studio[^<]{1,120}\|\s*([0-9]{4}\.[0-9]+\.[0-9]+)(?:\s+Patch\s+([0-9]+))?\s*</h2>"#,
                options: [.caseInsensitive]
              ),
              let match = expression.firstMatch(
                in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)
              ),
              let versionRange = Range(match.range(at: 1), in: html) else { return nil }
        let patch = Range(match.range(at: 2), in: html).flatMap { Int(html[$0]) }
        return (String(html[versionRange]), patch)
    }
}

private struct MinecraftVersionManifest: Decodable {
    struct Latest: Decodable {
        let release: String
        let snapshot: String
    }

    let latest: Latest
}

struct SparkleRelease: Equatable, Sendable {
    let buildVersion: String
    let displayVersion: String
    let channel: ReleaseChannel

    init(
        buildVersion: String,
        displayVersion: String,
        channel: ReleaseChannel = .stable
    ) {
        self.buildVersion = buildVersion
        self.displayVersion = displayVersion
        self.channel = channel
    }
}

final class SparkleAppcastParser: NSObject, XMLParserDelegate {
    struct ParsedAppcast {
        let itemCount: Int
        let latestRelease: SparkleRelease?
    }

    private var releases: [SparkleRelease] = []
    private var itemCount = 0
    private var sawRSS = false
    private var sawChannel = false
    private var insideItem = false
    private var currentElement = ""
    private var currentText = ""
    private var buildVersion: String?
    private var displayVersion: String?
    private var channel: String?

    static func latestRelease(
        in data: Data,
        desiredChannel: ReleaseChannel = .stable,
        allowPrereleaseForStable: Bool = false
    ) -> SparkleRelease? {
        parse(
            in: data,
            desiredChannel: desiredChannel,
            allowPrereleaseForStable: allowPrereleaseForStable
        )?.latestRelease
    }

    static func parse(
        in data: Data,
        desiredChannel: ReleaseChannel = .stable,
        allowPrereleaseForStable: Bool = false
    ) -> ParsedAppcast? {
        let delegate = SparkleAppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRSS, delegate.sawChannel else { return nil }
        let latestRelease = delegate.releases.filter {
            ReleaseChannelPolicy.allows(
                candidate: $0.channel,
                for: desiredChannel,
                allowPrereleaseForStable: allowPrereleaseForStable
            )
        }.max {
            VersionComparator.compare($0.buildVersion, $1.buildVersion) == .orderedAscending
        }
        return ParsedAppcast(itemCount: delegate.itemCount, latestRelease: latestRelease)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        if localName(elementName) == "rss" { sawRSS = true }
        if localName(elementName) == "channel" { sawChannel = true }
        if localName(elementName) == "item" {
            itemCount += 1
            insideItem = true
            buildVersion = nil
            displayVersion = nil
            channel = nil
        } else if insideItem, localName(elementName) == "enclosure" {
            buildVersion = attributeDict["sparkle:version"]
                ?? attributeDict.first(where: { localName($0.key) == "version" })?.value
                ?? buildVersion
            displayVersion = attributeDict["sparkle:shortVersionString"]
                ?? attributeDict.first(where: { localName($0.key) == "shortVersionString" })?.value
                ?? displayVersion
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard insideItem else { return }
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch localName(elementName) {
        case "version" where !value.isEmpty:
            buildVersion = value
        case "shortVersionString" where !value.isEmpty:
            displayVersion = value
        case "channel" where !value.isEmpty:
            channel = value
        case "item":
            if let buildVersion,
               !buildVersion.isEmpty {
                releases.append(
                    SparkleRelease(
                        buildVersion: buildVersion,
                        displayVersion: displayVersion ?? buildVersion,
                        channel: ReleaseChannel(rawValue: channel ?? "stable")
                    )
                )
            }
            insideItem = false
        default:
            break
        }
        currentText = ""
    }

    private func localName(_ value: String) -> String {
        String(value.split(separator: ":").last ?? Substring(value))
    }
}

private struct ChromeReleaseResponse: Decodable {
    let releases: [ChromeRelease]
}

private struct ChromeRelease: Decodable {
    let version: String
    let fraction: Double
}

private struct GitHubLatestRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL?
    let body: String?
    let prerelease: Bool?
    let draft: Bool?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case prerelease
        case draft
    }
}

private struct VisualStudioCodeRelease: Decodable {
    let name: String?
    let productVersion: String?
}

private struct HomebrewCaskRelease: Decodable {
    let version: String
}

private struct AppStoreLookupResponse: Decodable {
    struct Release: Decodable {
        let bundleIdentifier: String?
        let version: String?
        let releaseNotes: String?
        let trackViewURL: URL?

        enum CodingKeys: String, CodingKey {
            case bundleIdentifier = "bundleId"
            case version
            case releaseNotes
            case trackViewURL = "trackViewUrl"
        }
    }

    let results: [Release]
}

private struct VisualStudioMarketplaceExtension: Decodable {
    struct Version: Decodable {
        struct Property: Decodable {
            let key: String
            let value: String
        }

        let version: String
        let targetPlatform: String?
        let properties: [Property]?

        var isPrerelease: Bool {
            property("Microsoft.VisualStudio.Code.PreRelease") == "true"
        }

        var engine: String? {
            property("Microsoft.VisualStudio.Code.Engine")
        }

        private func property(_ key: String) -> String? {
            properties?.first(where: { $0.key == key })?.value
        }
    }

    let versions: [Version]
}
