import XCTest
@testable import UpdateAtlas

final class UpdateCheckTests: XCTestCase {
    func testExplicitGUIAndCLIReleasePolicyMatchesForBothPreferenceStates() async throws {
        let suiteName = "fixture.release-policy." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let url = try XCTUnwrap(URL(string: "https://fixture.example.com/beta.json"))
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(#"{"version":"2.0.0-beta.1"}"#.utf8))]
        defer { ProviderFallbackURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let app = InstalledApplication(inventoryID: "release-policy", path: "/fixture.app", name: "Fixture",
            bundleIdentifier: "fixture.policy", displayVersion: "1.0.0", buildVersion: "1", teamIdentifier: nil,
            status: .supported, mechanism: .website, mechanismName: "Website", confidence: .verified, evidence: [],
            parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
            versionProvider: CatalogVersionProvider(type: .jsonVersion, url: url, channel: "version"),
            catalogEntryID: "fixture", notes: "", kind: .application, packageProvenance: nil)
        for allowed in [true, false] {
            preferences.set(allowed, forKey: ReleaseChannelSettings.allowPrereleaseForStableKey)
            let gui = await UpdateCheckService(session: session, allowPrereleaseForStable: allowed).check([app])
            let cli = await UpdateCheckService(session: session, allowPrereleaseForStable: ReleaseChannelSettings.current(from: preferences)).check([app])
            XCTAssertEqual(gui.first?.updateCheck.availability, cli.first?.updateCheck.availability)
            XCTAssertEqual(cli.first?.updateCheck.availability, allowed ? .updateAvailable : .upToDate)
        }
    }

    func testAppStoreLookupMatchesIdentityAndResolvesProductPage() async throws {
        let url = URL(string: "https://itunes.apple.com/lookup?bundleId=fixture.store&country=tr")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ProviderFallbackURLProtocol.responses = [:] }
        let item = InstalledApplication(inventoryID: "store-fixture", path: "/Fixture.app", name: "Fixture",
            bundleIdentifier: "fixture.store", displayVersion: "1", buildVersion: "1", teamIdentifier: nil,
            status: .supported, mechanism: .appStore, mechanismName: "App Store", confidence: .verified, evidence: [],
            parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
            versionProvider: CatalogVersionProvider(type: .appleAppStoreLookup, url: url, channel: "tr", identifier: "fixture.store"),
            catalogEntryID: nil, notes: "", kind: .application, packageProvenance: nil)
        XCTAssertEqual(ManagerUpdatePolicy.action(for: item)?.rawValue, "appStorePage")
        let checker = UpdateCheckService(session: session)
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(#"{"results":[{"bundleId":"wrong.app","version":"99","trackViewUrl":"https://apps.apple.com/app/id999"},{"bundleId":"fixture.store","version":"2","trackViewUrl":"https://apps.apple.com/tr/app/fixture/id123"}]}"#.utf8))]
        let checked = await checker.check([item])
        XCTAssertEqual(checked.first?.updateCheck.latestVersion, "2")
        let page = try await checker.appStorePage(for: item)
        XCTAssertEqual(page.absoluteString, "https://apps.apple.com/tr/app/fixture/id123")
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(#"{"results":[{"bundleId":"wrong.app","version":"99","trackViewUrl":"https://apps.apple.com/app/id999"}]}"#.utf8))]
        let unmatched = await checker.check([item])
        XCTAssertEqual(unmatched.first?.updateCheck.availability, .checkFailed)
        do { _ = try await checker.appStorePage(for: item); XCTFail("Wrong product must not open") } catch {}
    }

    func testNumericVersionComparisonDoesNotOfferSameVersion() {
        XCTAssertTrue(VersionComparator.isSame("v2.0.9", "2.0.9"))
        XCTAssertFalse(VersionComparator.isNewer("2.0.9", than: "2.0.9"))
        XCTAssertTrue(VersionComparator.isNewer("2.0.10", than: "2.0.9"))
        XCTAssertTrue(VersionComparator.isSame("release-5.2.3", "5.2.3"))
    }

    func testChromeCheckTargetsOnlyCurrentFullyRolledOutReleases() throws {
        let url = try XCTUnwrap(
            UpdateCheckService.chromeReleaseURL(platform: "mac_arm64", channel: "stable")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(
            components.path,
            "/v1/chrome/platforms/mac_arm64/channels/stable/versions/all/releases"
        )
        XCTAssertEqual(query["filter"], "fraction=1,endtime=none")
        XCTAssertEqual(query["order_by"], "version desc")
        XCTAssertEqual(query["page_size"], "1")
    }

    func testChromeCheckIgnoresPartialRollouts() throws {
        let response = #"""
        {
          "releases": [
            { "version": "154.0.8037.44", "fraction": 0.005 },
            { "version": "153.0.8010.48", "fraction": 1 }
          ]
        }
        """#

        XCTAssertEqual(
            try UpdateCheckService.fullyRolledOutChromeVersion(from: Data(response.utf8)),
            "153.0.8010.48"
        )
    }

    func testProviderChainFallsBackAfterPrimarySourceFailure() async throws {
        let primaryURL = try XCTUnwrap(URL(string: "https://primary.example.com/version.json"))
        let fallbackURL = try XCTUnwrap(URL(string: "https://fallback.example.com/version.json"))
        ProviderFallbackURLProtocol.responses = [
            primaryURL.absoluteString: (500, Data()),
            fallbackURL.absoluteString: (200, Data(#"{"version":"2.0.0"}"#.utf8))
        ]
        defer { ProviderFallbackURLProtocol.responses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let application = InstalledApplication(
            inventoryID: "fallback-test",
            path: "/tmp/Fallback.app",
            name: "Fallback",
            bundleIdentifier: "com.example.fallback",
            displayVersion: "1.0.0",
            buildVersion: "1.0.0",
            teamIdentifier: nil,
            status: .supported,
            mechanism: .website,
            mechanismName: "Official release sources",
            confidence: .verified,
            evidence: [],
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            versionProviders: [
                CatalogVersionProvider(type: .jsonVersion, url: primaryURL, channel: "version"),
                CatalogVersionProvider(type: .jsonVersion, url: fallbackURL, channel: "version")
            ],
            catalogEntryID: "fallback-test",
            notes: "",
            kind: .application,
            packageProvenance: nil
        )

        let results = await UpdateCheckService(session: session).check([application])
        let checked = try XCTUnwrap(results.first)
        XCTAssertEqual(checked.updateCheck.availability, .updateAvailable)
        XCTAssertEqual(checked.updateCheck.latestVersion, "2.0.0")
        XCTAssertEqual(checked.updateCheck.source, .jsonDocument)
        XCTAssertTrue(
            checked.updateCheck.detail.contains(String(localized: "A fallback update source succeeded."))
        )
    }

    func testAppleSystemApplicationUsesManagedStatus() async {
        let application = InstalledApplication(
            inventoryID: "apple",
            path: "/System/Applications/Example.app",
            name: "Example",
            bundleIdentifier: "com.apple.Example",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: nil,
            status: .managedExternally,
            mechanism: .system,
            mechanismName: "Managed by macOS",
            confidence: .verified,
            evidence: [],
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            catalogEntryID: nil,
            notes: "",
            kind: .application,
            packageProvenance: nil
        )

        let checked = await UpdateCheckService().check([application]).first
        XCTAssertEqual(checked?.updateCheck.availability, .managedBySystem)
    }

    func testCatalogVersionProviderRoundTripsReleaseTagPrefix() throws {
        let provider = CatalogVersionProvider(
            type: .githubLatestRelease,
            url: URL(string: "https://api.github.com/repos/example/example/releases/latest")!,
            channel: "stable",
            versionPrefix: "example-v",
            versionRegex: #"Example v([0-9]+(?:\.[0-9]+)+)"#,
            releaseChannel: .releaseCandidate
        )
        let decoded = try JSONDecoder().decode(
            CatalogVersionProvider.self,
            from: JSONEncoder().encode(provider)
        )

        XCTAssertEqual(decoded.versionPrefix, "example-v")
        XCTAssertEqual(decoded.versionRegex, #"Example v([0-9]+(?:\.[0-9]+)+)"#)
        XCTAssertEqual(decoded.releaseChannel, .releaseCandidate)
    }

    func testPlatformDownloadVersionDoesNotUseGlobalOrOtherOperatingSystemRelease() {
        let page = """
        <a>Latest: v5.2.4</a>
        <h2>Windows 10+</h2><a>Download qBittorrent v5.2.4</a>
        <h2>macOS 13+</h2><a>Download qBittorrent v5.2.3</a>
        <h2>Linux</h2><a>Download qBittorrent v5.2.4</a>
        """
        XCTAssertEqual(
            UpdateCheckService.platformDownloadVersion(
                in: page, platform: "macOS",
                versionPattern: #"Download\s+qBittorrent\s+v([0-9]+(?:\.[0-9]+){1,3})"#
            ),
            "5.2.3"
        )
        XCTAssertNil(UpdateCheckService.platformDownloadVersion(
            in: page, platform: "FreeBSD", versionPattern: #"v([0-9]+(?:\.[0-9]+){1,3})"#
        ))
    }

    func testMacOSDownloadProviderIgnoresNewerSourceAndPrerelease() async throws {
        let url = try XCTUnwrap(URL(string: "https://www.qbittorrent.org/download"))
        let page = """
        <a>Latest: v5.2.4</a>
        <h3>Windows 10+</h3><a>Download qBittorrent v5.2.4</a>
        <h3>macOS 13+</h3><a>Download qBittorrent v5.3.0rc1</a>
        <a>Download qBittorrent v5.2.3</a>
        <h3>Linux</h3><a>Download qBittorrent v5.2.4</a>
        """
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(page.utf8))]
        defer { ProviderFallbackURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let application = githubApplication(
            installedVersion: "5.2.3",
            provider: CatalogVersionProvider(
                type: .platformDownloadPage,
                url: url,
                channel: "stable",
                targetPlatform: "macOS",
                versionRegex: #"Download\s+qBittorrent\s+v([0-9]+(?:\.[0-9]+){1,3})(?![A-Za-z0-9._-])"#,
                releaseChannel: .stable
            )
        )
        let result = await UpdateCheckService(session: URLSession(configuration: configuration)).check([application])
        XCTAssertEqual(result.first?.updateCheck.availability, .upToDate)
        XCTAssertEqual(result.first?.updateCheck.latestVersion, "5.2.3")
        XCTAssertEqual(result.first?.updateCheck.source, .platformDownloads)
    }

    func testCachedOldQBitGitHubRuleCannotReportMacUpdate() async throws {
        let official = try XCTUnwrap(URL(string: "https://www.qbittorrent.org/download"))
        let oldGitHub = try XCTUnwrap(URL(string: "https://api.github.com/repos/qbittorrent/qBittorrent/releases/latest"))
        ProviderFallbackURLProtocol.responses = [
            official.absoluteString: (200, Data("<h3>macOS 13+</h3><a>Download qBittorrent v5.2.3</a><h3>Linux</h3>".utf8)),
            oldGitHub.absoluteString: (200, Data(#"{"tag_name":"release-5.2.4"}"#.utf8))
        ]
        defer { ProviderFallbackURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let application = githubApplication(
            installedVersion: "5.2.3",
            provider: CatalogVersionProvider(
                type: .githubLatestRelease, url: oldGitHub, channel: "stable", versionPrefix: "release-"
            ),
            bundleIdentifier: "org.qbittorrent.qBittorrent",
            catalogEntryID: "qbittorrent-macos-stable"
        )
        let result = await UpdateCheckService(session: URLSession(configuration: configuration)).check([application])
        XCTAssertEqual(result.first?.updateCheck.availability, .upToDate)
        XCTAssertEqual(result.first?.updateCheck.latestVersion, "5.2.3")
        XCTAssertEqual(result.first?.updateCheck.source, .platformDownloads)
    }

    func testGitHubReleaseListSelectsNewestMatchingProductTag() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/repos/example/monorepo/releases?per_page=100"))
        let response = #"""
        [
          {"tag_name":"another-product-v99.0.0","name":"Other","draft":false,"prerelease":false},
          {"tag_name":"open-design-v0.22.1","name":"Open Design 0.22.1","draft":false,"prerelease":false},
          {"tag_name":"open-design-v0.22.2","name":"Open Design 0.22.2","draft":false,"prerelease":false}
        ]
        """#
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(response.utf8))]
        defer { ProviderFallbackURLProtocol.responses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let application = githubApplication(
            installedVersion: "0.22.1",
            provider: CatalogVersionProvider(
                type: .githubLatestRelease,
                url: url,
                channel: "stable",
                versionPrefix: "open-design-v",
                releaseChannel: .stable
            )
        )
        let results = await UpdateCheckService(session: session).check([application])
        let checked = try XCTUnwrap(results.first)

        XCTAssertEqual(checked.updateCheck.availability, .updateAvailable)
        XCTAssertEqual(checked.updateCheck.latestVersion, "0.22.2")
    }

    func testGitHubReleaseCanExtractProductVersionFromReleaseName() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/repos/example/hermes/releases?per_page=100"))
        let response = #"""
        [
          {"tag_name":"v2026.9.14","name":"Hermes Agent v0.21.3 (v2026.9.14)","draft":false,"prerelease":false},
          {"tag_name":"v2026.9.11","name":"Hermes Agent v0.21.2 (v2026.9.11)","draft":false,"prerelease":false}
        ]
        """#
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(response.utf8))]
        defer { ProviderFallbackURLProtocol.responses = [:] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let application = githubApplication(
            installedVersion: "0.21.2",
            provider: CatalogVersionProvider(
                type: .githubLatestRelease,
                url: url,
                channel: "stable",
                versionRegex: #"Hermes Agent v([0-9]+(?:\.[0-9]+)+)"#,
                releaseChannel: .stable
            )
        )
        let results = await UpdateCheckService(session: session).check([application])
        let checked = try XCTUnwrap(results.first)

        XCTAssertEqual(checked.updateCheck.availability, .updateAvailable)
        XCTAssertEqual(checked.updateCheck.latestVersion, "0.21.3")
    }

    func testHermesRuntimeMetadataReadsManagedVersionInsteadOfBootstrapShell() {
        XCTAssertEqual(
            HermesRuntimeMetadata.version(fromUpdateCheckData: Data(#"{"ver":"0.21.3"}"#.utf8)),
            "0.21.3"
        )
        XCTAssertEqual(
            HermesRuntimeMetadata.version(fromPyprojectData: Data("[project]\nversion = \"0.21.3\"\n".utf8)),
            "0.21.3"
        )
    }

    func testAndroidStudioCaskPackageRevisionDoesNotBecomeAnIDEUpdate() async throws {
        let url = try XCTUnwrap(URL(string: "https://formulae.brew.sh/api/cask/android-studio.json"))
        ProviderFallbackURLProtocol.responses = [
            url.absoluteString: (200, Data(#"{"version":"2026.2.1.8,rabbit1-patch1"}"#.utf8))
        ]
        defer { ProviderFallbackURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let application = InstalledApplication(
            inventoryID: "android-studio-test", path: "/Applications/Android Studio.app",
            name: "Android Studio", bundleIdentifier: "com.google.android.studio",
            displayVersion: "2026.2.1", buildVersion: "AI-262.9437.185.2621.16467767",
            teamIdentifier: nil, status: .supported, mechanism: .externalManager,
            mechanismName: "Android Studio Updater", confidence: .verified, evidence: [],
            parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
            versionProvider: CatalogVersionProvider(type: .homebrewCask, url: url, channel: "stable"),
            catalogEntryID: "android-studio-macos-stable", notes: "", kind: .application,
            packageProvenance: nil
        )
        let results = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(results.first?.updateCheck.availability, .sourcePending)

        ProviderFallbackURLProtocol.responses = [
            url.absoluteString: (200, Data(#"{"version":"2026.3.1.2,rabbit2-patch1"}"#.utf8))
        ]
        let newerResults = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(newerResults.first?.updateCheck.availability, .updateAvailable)
        XCTAssertEqual(newerResults.first?.updateCheck.latestVersion, "2026.3.1")
    }

    func testGoogleAppsDoNotClaimCurrentWhenHomebrewCaskLags() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ProviderFallbackURLProtocol.responses = [:] }

        for (bundleID, cask, installed, tracked) in [
            ("com.google.GeminiMacOS", "google-gemini", "1.135.1.1291", "1.135.1.1290"),
            ("com.google.antigravity", "antigravity", "2.28.2", "2.28.1"),
            ("com.google.antigravity-ide", "antigravity-ide", "2.6.1", "2.6.0")
        ] {
            let url = try XCTUnwrap(URL(string: "https://formulae.brew.sh/api/cask/\(cask).json"))
            ProviderFallbackURLProtocol.responses = [
                url.absoluteString: (200, Data(#"{"version":"\#(tracked)"}"#.utf8))
            ]
            let application = InstalledApplication(
                inventoryID: bundleID, path: "/Applications/Fixture.app", name: cask,
                bundleIdentifier: bundleID, displayVersion: installed, buildVersion: "",
                teamIdentifier: "EQHXZ8M8AV", status: .supported, mechanism: .externalManager,
                mechanismName: "In-app updater", confidence: .verified, evidence: [],
                parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
                versionProvider: CatalogVersionProvider(type: .homebrewCask, url: url, channel: "stable"),
                catalogEntryID: cask, notes: "", kind: .application, packageProvenance: nil
            )
            let results = await UpdateCheckService(session: session).check([application])
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.updateCheck.availability, .sourcePending, bundleID)
        }
    }

    func testDellCaskDoesNotTreatDifferentPackageRevisionAsSoftwareUpdate() async throws {
        let url = try XCTUnwrap(URL(string: "https://formulae.brew.sh/api/cask/ddpm.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProviderFallbackURLProtocol.responses = [:]
            session.invalidateAndCancel()
        }
        let application = InstalledApplication(
            inventoryID: "ddpm-test", path: "/Applications/DDPM/DDPM.app",
            name: "DDPM", bundleIdentifier: "Qisda.DDPM",
            displayVersion: "2.3.0.0023", buildVersion: "1",
            teamIdentifier: nil, status: .supported, mechanism: .externalManager,
            mechanismName: "Dell Display and Peripheral Manager", confidence: .verified,
            evidence: [], parentManagerBundleIdentifier: nil, parentManagerName: nil,
            vendorURL: nil,
            versionProvider: CatalogVersionProvider(type: .homebrewCask, url: url, channel: "stable"),
            catalogEntryID: "dell-ddpm-macos", notes: "", kind: .application,
            packageProvenance: nil
        )

        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(#"{"version":"2.3.0.2004"}"#.utf8))]
        let sameFamily = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(sameFamily.first?.updateCheck.availability, .sourcePending)

        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(#"{"version":"2.4.0.2001"}"#.utf8))]
        let newerFamily = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(newerFamily.first?.updateCheck.availability, .updateAvailable)
        XCTAssertEqual(newerFamily.first?.updateCheck.latestVersion, "2.4.0")
    }

    func testHomebrewManagedDDPMDoesNotUsePackageRevisionAsUpdate() async throws {
        let catalogURL = try XCTUnwrap(Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RemoteCatalog.self, from: Data(contentsOf: catalogURL))
        let provenance = PackageProvenance(
            identifier: "ddpm", manager: .homebrewCask,
            managerExecutablePath: "/opt/homebrew/bin/brew",
            installLocation: "/Applications/DDPM/DDPM.app", explicitlyInstalled: true,
            homepage: nil, summary: nil, isOutdated: true, latestVersion: "2.3.0.2004"
        )
        let candidate = ApplicationCandidate(
            path: "/Applications/DDPM/DDPM.app", name: "DDPM",
            bundleIdentifier: "Qisda.DDPM", displayVersion: "2.3.0.0023",
            buildVersion: "1", teamIdentifier: nil, parentManagerBundleIdentifier: nil,
            isSystemApplication: false, info: [:], packageProvenance: provenance
        )
        let application = try XCTUnwrap(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        XCTAssertEqual(application.versionProvider?.type, .homebrewCask)
        let url = try XCTUnwrap(application.versionProvider?.url)
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(#"{"version":"2.3.0.2004"}"#.utf8))]
        defer { ProviderFallbackURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let checked = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(checked.first?.updateCheck.availability, .sourcePending)
    }

    func testCanonFixedSupportPageOnlyProvesNewerVersion() async throws {
        let url = try XCTUnwrap(URL(string: "https://asia.canon/en/support/0200660310/"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProviderFallbackURLProtocol.responses = [:]
            session.invalidateAndCancel()
        }
        let page = #"<title>IJ Scan Utility2 Ver.2.4.3 (Mac) | Canon</title>"#
        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(page.utf8))]
        let provider = CatalogVersionProvider(type: .canonSupportRelease, url: url, channel: "stable")
        func application(version: String) -> InstalledApplication {
            InstalledApplication(
                inventoryID: "canon-test", path: "/Applications/Canon Utilities/IJ Scan Utility/Canon IJ Scan Utility2.app",
                name: "Canon IJ Scan Utility2", bundleIdentifier: "jp.co.canon.ij.scanutility2",
                displayVersion: version, buildVersion: version, teamIdentifier: nil,
                status: .supported, mechanism: .website, mechanismName: "Canon Support",
                confidence: .verified, evidence: [], parentManagerBundleIdentifier: nil,
                parentManagerName: nil, vendorURL: nil, versionProvider: provider,
                catalogEntryID: "canon-ij-scan-utility2-macos", notes: "", kind: .application,
                packageProvenance: nil
            )
        }

        let older = await UpdateCheckService(session: session).check([application(version: "2.4.2")])
        XCTAssertEqual(older.first?.updateCheck.availability, .updateAvailable, older.first?.updateCheck.detail ?? "missing result")
        XCTAssertEqual(older.first?.updateCheck.latestVersion, "2.4.3")

        let same = await UpdateCheckService(session: session).check([application(version: "2.4.3")])
        XCTAssertEqual(same.first?.updateCheck.availability, .sourcePending)
        XCTAssertNil(same.first?.updateCheck.latestVersion)
    }

    func testLogiOptionsPlusChecksSoftwareVersionFromCask() async throws {
        let url = try XCTUnwrap(URL(string: "https://formulae.brew.sh/api/cask/logi-options%2B.json"))
        ProviderFallbackURLProtocol.responses = [
            url.absoluteString: (200, Data(#"{"version":"2.8.981479"}"#.utf8))
        ]
        defer { ProviderFallbackURLProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let application = InstalledApplication(
            inventoryID: "logi-options-plus-test", path: "/Applications/logioptionsplus.app",
            name: "Logi Options+", bundleIdentifier: "com.logi.optionsplus",
            displayVersion: "2.7.900000", buildVersion: "2.7.900000", teamIdentifier: nil,
            status: .supported, mechanism: .externalManager,
            mechanismName: "Logi Options+ Updater", confidence: .verified,
            evidence: [], parentManagerBundleIdentifier: nil, parentManagerName: nil,
            vendorURL: nil,
            versionProvider: CatalogVersionProvider(type: .homebrewCask, url: url, channel: "stable"),
            catalogEntryID: "logi-options-plus-macos", notes: "", kind: .application,
            packageProvenance: nil
        )

        let checked = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(checked.first?.updateCheck.availability, .updateAvailable)
        XCTAssertEqual(checked.first?.updateCheck.latestVersion, "2.8.981479")
    }

    func testAndroidStudioUsesProductMetadataInsteadOfShortBundleVersion() throws {
        let productInfo = Data(#"{"dataDirectoryName":"AndroidStudio2026.2.1","versionSuffix":""}"#.utf8)
        let release = try XCTUnwrap(AndroidStudioMetadata.release(from: productInfo, bundleVersion: "2026.2"))
        XCTAssertEqual(release.version, "2026.2.1")
        XCTAssertNil(AndroidStudioMetadata.release(from: productInfo, bundleVersion: "2026.1"))
        XCTAssertNil(AndroidStudioMetadata.release(from: Data("{}".utf8), bundleVersion: "2026.2"))
    }

    func testAndroidStudioOfficialReleasePageMatchesInstalledFamily() throws {
        let html = Data(#"<h2 class="hide-from-toc" id="download" data-text="Download Android Studio Rabbit 1 | 2026.2.1">Download Android Studio Rabbit 1 | 2026.2.1</h2>"#.utf8)
        let release = try XCTUnwrap(AndroidStudioOfficialReleaseParser.latestStable(from: html))
        XCTAssertEqual(release.version, "2026.2.1")
        XCTAssertNil(release.patch)

        let patchHTML = Data(#"<h2>Download Android Studio Rabbit 1 | 2026.2.1 Patch 1</h2>"#.utf8)
        XCTAssertEqual(AndroidStudioOfficialReleaseParser.latestStable(from: patchHTML)?.patch, 1)
        XCTAssertNil(AndroidStudioOfficialReleaseParser.latestStable(from: Data("No stable release".utf8)))
    }

    func testAndroidStudioOfficialSourceDoesNotShowAnAvailableUpdateForInstalledRabbit1() async throws {
        let catalogURL = try XCTUnwrap(Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RemoteCatalog.self, from: Data(contentsOf: catalogURL))
        let candidate = ApplicationCandidate(
            path: "/Applications/Android Studio.app", name: "Android Studio",
            bundleIdentifier: "com.google.android.studio", displayVersion: "2026.2.1",
            buildVersion: "AI-262.9437.185.2621.16467767", teamIdentifier: nil,
            parentManagerBundleIdentifier: nil, isSystemApplication: false,
            info: ["AndroidStudioFullVersion": "2026.2.1"]
        )
        let application = try XCTUnwrap(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        XCTAssertEqual(application.versionProviders.first?.type, .androidStudioReleasePage)
        let url = try XCTUnwrap(application.versionProviders.first?.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProviderFallbackURLProtocol.responses = [:]
            session.invalidateAndCancel()
        }
        ProviderFallbackURLProtocol.responses = [
            url.absoluteString: (200, Data(#"<h2>Download Android Studio Rabbit 1 | 2026.2.1</h2>"#.utf8))
        ]
        let checked = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(checked.first?.updateCheck.availability, .upToDate)
        XCTAssertEqual(checked.first?.updateCheck.latestVersion, "2026.2.1")

        ProviderFallbackURLProtocol.responses = [
            url.absoluteString: (200, Data(#"<h2>Download Android Studio Rabbit 1 | 2026.2.1 Patch 1</h2>"#.utf8))
        ]
        let patch = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(patch.first?.updateCheck.availability, .sourcePending)
    }

    func testHomebrewManagedAndroidStudioUsesIDEReleaseInsteadOfOutdatedCaskFlag() async throws {
        let catalogURL = try XCTUnwrap(Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RemoteCatalog.self, from: Data(contentsOf: catalogURL))
        let provenance = PackageProvenance(
            identifier: "android-studio", manager: .homebrewCask,
            managerExecutablePath: "/opt/homebrew/bin/brew", installLocation: "/Applications/Android Studio.app",
            explicitlyInstalled: true, homepage: nil, summary: nil,
            isOutdated: true, latestVersion: "2026.2.1.8"
        )
        let candidate = ApplicationCandidate(
            path: "/Applications/Android Studio.app", name: "Android Studio",
            bundleIdentifier: "com.google.android.studio", displayVersion: "2026.2.1",
            buildVersion: "AI-262.9437.185.2621.16467767", teamIdentifier: nil,
            parentManagerBundleIdentifier: nil, isSystemApplication: false,
            info: ["AndroidStudioFullVersion": "2026.2.1"], packageProvenance: provenance
        )
        let application = try XCTUnwrap(UpdateDetectionEngine().classify([candidate], catalog: catalog).first)
        XCTAssertEqual(application.mechanism, .homebrew)
        XCTAssertEqual(application.versionProviders.first?.type, .androidStudioReleasePage)
        let officialURL = try XCTUnwrap(application.versionProviders.first?.url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProviderFallbackURLProtocol.responses = [:]
            session.invalidateAndCancel()
        }
        ProviderFallbackURLProtocol.responses = [
            officialURL.absoluteString: (200, Data(#"<h2>Download Android Studio Rabbit 1 | 2026.2.1</h2>"#.utf8))
        ]
        let checked = await UpdateCheckService(session: session).check([application])
        XCTAssertEqual(checked.first?.updateCheck.availability, .upToDate)
        XCTAssertEqual(checked.first?.updateCheck.source, .androidStudioOfficial)

        let abbreviated = ApplicationCandidate(
            path: candidate.path, name: candidate.name, bundleIdentifier: candidate.bundleIdentifier,
            displayVersion: "2026.2", buildVersion: candidate.buildVersion, teamIdentifier: nil,
            parentManagerBundleIdentifier: nil, isSystemApplication: false,
            info: [:], packageProvenance: provenance
        )
        let unresolved = try XCTUnwrap(UpdateDetectionEngine().classify([abbreviated], catalog: catalog).first)
        XCTAssertEqual(unresolved.status, .needsCatalog)
        let unresolvedCheck = await UpdateCheckService(session: session).check([unresolved])
        XCTAssertEqual(unresolvedCheck.first?.updateCheck.availability, .sourcePending)
    }

    func testHermesSourceRequiresLiveLauncherAndReadsPackedMainRevision() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".temporary_files/hermes-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent(".hermes/hermes-agent")
        let binary = checkout.appendingPathComponent(".hermes/bin/hermes")
        let launcher = root.appendingPathComponent(".local/bin/hermes")
        let revision = String(repeating: "a", count: 40)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: checkout.appendingPathComponent(".git/HEAD"))
        try Data("\(revision) refs/heads/main\n".utf8).write(to: checkout.appendingPathComponent(".git/packed-refs"))
        XCTAssertNil(HermesRuntimeMetadata.sourceCandidate(parentInventoryID: nil, homeDirectory: root))
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexec \(binary.path) \"$@\"\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let candidate = try XCTUnwrap(HermesRuntimeMetadata.sourceCandidate(parentInventoryID: "desktop", homeDirectory: root))
        XCTAssertEqual(candidate.info["SourceRevision"], revision)
        XCTAssertEqual(candidate.info["SourceBranch"], "main")
        XCTAssertEqual(candidate.parentInventoryID, "desktop")
        XCTAssertEqual(candidate.kind, .runtime)
        try FileManager.default.removeItem(at: launcher)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)
        XCTAssertNotNil(HermesRuntimeMetadata.sourceCandidate(parentInventoryID: nil, homeDirectory: root))
    }

    func testHermesGitComparisonDoesNotClaimDivergedCheckoutIsOutdated() async throws {
        let revision = String(repeating: "a", count: 40)
        let url = try XCTUnwrap(URL(string: "https://api.github.com/repos/NousResearch/hermes-agent/compare/\(revision)...main?per_page=1"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            ProviderFallbackURLProtocol.responses = [:]
            session.invalidateAndCancel()
        }
        let application = githubApplication(
            installedVersion: String(revision.prefix(10)),
            provider: CatalogVersionProvider(type: .githubCommitCompare, url: url, channel: "main")
        )
        for (status, aheadBy, expected) in [
            ("identical", 0, UpdateAvailability.upToDate),
            ("ahead", 3, .updateAvailable),
            ("diverged", 2, .sourcePending),
            ("behind", 0, .sourcePending)
        ] {
            ProviderFallbackURLProtocol.responses = [
                url.absoluteString: (200, Data("{\"status\":\"\(status)\",\"ahead_by\":\(aheadBy)}".utf8))
            ]
            let results = await UpdateCheckService(session: session).check([application])
            let checked = try XCTUnwrap(results.first)
            XCTAssertEqual(checked.updateCheck.availability, expected, status)
        }
    }

    func testReleaseChannelAliasesAndDetection() {
        XCTAssertEqual(ReleaseChannel(rawValue: "LTS"), .lts)
        XCTAssertEqual(ReleaseChannel(rawValue: "release-candidate"), .releaseCandidate)
        XCTAssertEqual(ReleaseChannel(rawValue: "Insiders"), .canary)
        XCTAssertEqual(ReleaseChannel(rawValue: "snapshot"), .nightly)
        XCTAssertEqual(ReleaseChannel.detect(version: "4.2.0-beta.3"), .beta)
        XCTAssertEqual(
            ReleaseChannel.detect(
                version: "1.99.0",
                bundleIdentifier: "com.microsoft.VSCodeInsiders"
            ),
            .canary
        )
    }

    func testStableChannelRejectsOtherChannelsUnlessPrereleaseOptInIsEnabled() {
        XCTAssertTrue(ReleaseChannelPolicy.allows(
            candidate: .stable,
            for: .stable,
            allowPrereleaseForStable: false
        ))
        XCTAssertFalse(ReleaseChannelPolicy.allows(
            candidate: .lts,
            for: .stable,
            allowPrereleaseForStable: false
        ))
        XCTAssertFalse(ReleaseChannelPolicy.allows(
            candidate: .beta,
            for: .stable,
            allowPrereleaseForStable: false
        ))
        XCTAssertTrue(ReleaseChannelPolicy.allows(
            candidate: .beta,
            for: .stable,
            allowPrereleaseForStable: true
        ))
    }

    func testPrereleaseInstallationsStayOnTheirOwnChannel() {
        XCTAssertTrue(ReleaseChannelPolicy.allows(
            candidate: .beta,
            for: .beta,
            allowPrereleaseForStable: false
        ))
        XCTAssertFalse(ReleaseChannelPolicy.allows(
            candidate: .releaseCandidate,
            for: .beta,
            allowPrereleaseForStable: true
        ))
        XCTAssertFalse(ReleaseChannelPolicy.allows(
            candidate: .stable,
            for: .beta,
            allowPrereleaseForStable: true
        ))
    }

    func testSparkleParserSelectsLatestBuildAndDisplayVersion() {
        let xml = #"""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:version="209" sparkle:shortVersionString="2.0.9" />
            </item>
            <item>
              <enclosure sparkle:version="210" sparkle:shortVersionString="2.0.10" />
            </item>
            <item>
              <sparkle:channel>beta</sparkle:channel>
              <enclosure sparkle:version="999" sparkle:shortVersionString="9.9.9-beta" />
            </item>
          </channel>
        </rss>
        """#

        XCTAssertEqual(
            SparkleAppcastParser.latestRelease(in: Data(xml.utf8)),
            SparkleRelease(buildVersion: "210", displayVersion: "2.0.10")
        )
        XCTAssertEqual(
            SparkleAppcastParser.latestRelease(in: Data(xml.utf8), desiredChannel: .beta),
            SparkleRelease(buildVersion: "999", displayVersion: "9.9.9-beta", channel: .beta)
        )
    }

    func testEmptySparkleFeedIsPendingRatherThanFailedOrUpToDate() async throws {
        let url = try XCTUnwrap(URL(string: "https://fixture.example.com/appcast.xml"))
        let emptyFeed = #"<rss version="2.0"><channel><title>Unpublished</title></channel></rss>"#
        let malformedFeed = #"<rss><channel><item></channel></rss>"#
        let incompatibleFeed = #"<rss><channel><item><sparkle:channel>beta</sparkle:channel><enclosure sparkle:version="2" sparkle:shortVersionString="2.0" /></item></channel></rss>"#
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFallbackURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ProviderFallbackURLProtocol.responses = [:] }
        let application = InstalledApplication(
            inventoryID: "self-update-fixture", path: "/Applications/Update Atlas.app",
            name: "Update Atlas", bundleIdentifier: AppIdentity.bundleIdentifier,
            displayVersion: "0.1.0", buildVersion: "37", teamIdentifier: nil,
            status: .supported, mechanism: .sparkle, mechanismName: "Sparkle",
            confidence: .verified, evidence: [], parentManagerBundleIdentifier: nil,
            parentManagerName: nil, vendorURL: url,
            versionProvider: CatalogVersionProvider(type: .sparkleAppcast, url: url, channel: nil),
            catalogEntryID: nil, notes: "", kind: .application, packageProvenance: nil
        )
        let checker = UpdateCheckService(session: session)

        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(emptyFeed.utf8))]
        let unpublishedScan = await checker.check([application])
        let unpublished = try XCTUnwrap(unpublishedScan.first?.updateCheck)
        XCTAssertEqual(unpublished.availability, .sourcePending)
        XCTAssertEqual(unpublished.source, .sparkleAppcast)
        XCTAssertNil(unpublished.latestVersion)
        XCTAssertNotNil(unpublished.checkedAt)

        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(malformedFeed.utf8))]
        let malformedScan = await checker.check([application])
        let malformed = try XCTUnwrap(malformedScan.first?.updateCheck)
        XCTAssertEqual(malformed.availability, .checkFailed)

        ProviderFallbackURLProtocol.responses = [url.absoluteString: (200, Data(incompatibleFeed.utf8))]
        let incompatibleScan = await checker.check([application])
        let incompatible = try XCTUnwrap(incompatibleScan.first?.updateCheck)
        XCTAssertEqual(incompatible.availability, .checkFailed)
    }

    func testPackageProviderSuppressesFalsePositiveWhenVersionsMatch() async {
        let provenance = PackageProvenance(
            identifier: "sample",
            manager: .npm,
            managerExecutablePath: "/opt/homebrew/bin/npm",
            installLocation: nil,
            explicitlyInstalled: true,
            homepage: nil,
            summary: nil,
            isOutdated: true,
            latestVersion: "2.0.9"
        )
        let application = InstalledApplication(
            inventoryID: "sample",
            path: "/tmp/sample",
            name: "Sample",
            bundleIdentifier: "sample",
            displayVersion: "2.0.9",
            buildVersion: "2.0.9",
            teamIdentifier: nil,
            status: .supported,
            mechanism: .npm,
            mechanismName: "npm",
            confidence: .verified,
            evidence: [],
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            catalogEntryID: nil,
            notes: "",
            kind: .package,
            packageProvenance: provenance
        )

        let checked = await UpdateCheckService().check([application]).first
        XCTAssertEqual(checked?.updateCheck.availability, .upToDate)
        XCTAssertEqual(checked?.updateCheck.latestVersion, "2.0.9")
    }

    func testSystemAppsAreExcludedByDefault() {
        XCTAssertFalse(InventorySettings.defaultIncludeSystemApplications)
    }

    func testUpdateAvailableIsTheDefaultView() {
        XCTAssertEqual(InventorySettings.defaultView, .updateAvailable)
        XCTAssertEqual(
            InventorySettings.defaultView.filterID,
            "update.updateAvailable"
        )
    }

    func testNestedGameComponentsDoNotInflateGameTotals() {
        let game = installedItem(
            id: "game",
            kind: .game,
            gamePlatform: .standalone
        )
        let client = installedItem(
            id: "client",
            kind: .application,
            gamePlatform: .steam
        )
        let runtime = installedItem(
            id: "runtime",
            kind: .runtime,
            gamePlatform: .standalone
        )
        let mod = installedItem(
            id: "mod",
            kind: .mod,
            gamePlatform: .standalone
        )

        XCTAssertTrue(game.contributesToGameCount)
        XCTAssertTrue(client.contributesToGameCount)
        XCTAssertFalse(runtime.contributesToGameCount)
        XCTAssertFalse(mod.contributesToGameCount)
    }

    @MainActor
    func testAllInOneGameCountDoesNotChangeWhenManagerCollapses() throws {
        let client = installedItem(
            id: "client",
            kind: .application,
            gamePlatform: .steam
        )
        let game = installedItem(
            id: "game",
            kind: .game,
            gamePlatform: .steam,
            parentInventoryID: client.id
        )
        let runtime = installedItem(
            id: "runtime",
            kind: .runtime,
            gamePlatform: .steam,
            parentInventoryID: game.id
        )
        let viewModel = AppInventoryViewModel(initialApplications: [client, game, runtime])
        viewModel.selectedFilterID = InventoryScope.allInOne.id
        viewModel.expandedManagerIDs = [client.id, game.id]

        XCTAssertEqual(viewModel.visibleApplications.count, 3)
        XCTAssertEqual(viewModel.gameFilters.first?.count, 2)

        viewModel.expandedManagerIDs = []

        XCTAssertEqual(viewModel.visibleApplications.count, 1)
        XCTAssertEqual(viewModel.gameFilters.first?.count, 2)
    }

    func testMenuBarSummaryCountsConfirmedUpdatesOnceAcrossCategories() {
        let update = UpdateCheckResult(
            availability: .updateAvailable,
            installedVersion: "1.0",
            latestVersion: "2.0",
            checkedAt: Date(),
            source: .packageManager,
            detail: ""
        )
        let current = UpdateCheckResult(
            availability: .upToDate,
            installedVersion: "1.0",
            latestVersion: "1.0",
            checkedAt: Date(),
            source: .packageManager,
            detail: ""
        )
        let package = PackageProvenance(
            identifier: "sample",
            manager: .homebrewFormula,
            managerExecutablePath: "/opt/homebrew/bin/brew",
            installLocation: nil,
            explicitlyInstalled: true,
            homepage: nil,
            summary: nil,
            isOutdated: true
        )
        let app = installedItem(id: "app", kind: .application, gamePlatform: nil, updateCheck: update)
        let game = installedItem(id: "game", kind: .game, gamePlatform: .steam, updateCheck: update)
        let packageItem = installedItem(
            id: "package",
            kind: .package,
            gamePlatform: nil,
            packageProvenance: package,
            updateCheck: update
        )
        let upToDate = installedItem(id: "current", kind: .application, gamePlatform: nil, updateCheck: current)
        let summary = MenuBarUpdateSummary.count([app, game, packageItem, app, upToDate])

        XCTAssertEqual(summary.applications, 1)
        XCTAssertEqual(summary.games, 1)
        XCTAssertEqual(summary.packages, 1)
        XCTAssertEqual(summary.total, 3)
    }

    func testApplicationMetadataReaderSeesVersionReplacementAtSamePath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationURL = temporaryRoot.appendingPathComponent("Example.app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        func writeVersion(_ version: String) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "com.example.app",
                    "CFBundleShortVersionString": version
                ],
                format: .binary,
                options: 0
            )
            try data.write(to: infoURL, options: .atomic)
        }

        try writeVersion("1.0.0")
        XCTAssertEqual(
            ApplicationBundleMetadataReader.infoDictionary(at: applicationURL)?["CFBundleShortVersionString"] as? String,
            "1.0.0"
        )

        try writeVersion("2.0.0")
        XCTAssertEqual(
            ApplicationBundleMetadataReader.infoDictionary(at: applicationURL)?["CFBundleShortVersionString"] as? String,
            "2.0.0"
        )
    }

    func testWrappedAppStoreBundleMetadataIsReadWithoutLaunchingTheApp() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationURL = temporaryRoot.appendingPathComponent("Wrapped.app", isDirectory: true)
        let wrappedApplicationURL = applicationURL
            .appendingPathComponent("Wrapper", isDirectory: true)
            .appendingPathComponent("Inner.app", isDirectory: true)
        try FileManager.default.createDirectory(at: wrappedApplicationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.wrapped",
                "CFBundleShortVersionString": "7.5.0",
                "CFBundleVersion": "18547"
            ],
            format: .binary,
            options: 0
        )
        try infoData.write(to: wrappedApplicationURL.appendingPathComponent("Info.plist"))
        try FileManager.default.createSymbolicLink(
            atPath: applicationURL.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Inner.app"
        )

        let storeData = try PropertyListSerialization.data(
            fromPropertyList: [
                "itemId": 1_119_601_770,
                "storefrontCountryCode": "tr"
            ],
            format: .binary,
            options: 0
        )
        try storeData.write(to: applicationURL.appendingPathComponent("Wrapper/iTunesMetadata.plist"))

        XCTAssertEqual(
            ApplicationBundleMetadataReader.infoDictionary(at: applicationURL)?["CFBundleIdentifier"] as? String,
            "com.example.wrapped"
        )
        XCTAssertEqual(
            ApplicationBundleMetadataReader.appStoreMetadata(at: applicationURL)?["itemId"] as? NSNumber,
            NSNumber(value: 1_119_601_770)
        )
    }

    private func installedItem(
        id: String,
        kind: InventoryItemKind,
        gamePlatform: GamePlatformKind?,
        parentInventoryID: String? = nil,
        packageProvenance: PackageProvenance? = nil,
        updateCheck: UpdateCheckResult? = nil
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: id,
            path: "/tmp/\(id)",
            name: id,
            bundleIdentifier: "test.\(id)",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: nil,
            status: .managedExternally,
            mechanism: .externalManager,
            mechanismName: "Test Manager",
            confidence: .verified,
            evidence: [],
            parentInventoryID: parentInventoryID,
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            catalogEntryID: nil,
            notes: "",
            kind: kind,
            gamePlatform: gamePlatform,
            packageProvenance: packageProvenance,
            updateCheck: updateCheck
        )
    }

    private func githubApplication(
        installedVersion: String,
        provider: CatalogVersionProvider,
        bundleIdentifier: String = "com.example.github",
        catalogEntryID: String = "github-test"
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: "github-test",
            path: "/tmp/GitHub.app",
            name: "GitHub Test",
            bundleIdentifier: bundleIdentifier,
            displayVersion: installedVersion,
            buildVersion: installedVersion,
            teamIdentifier: nil,
            status: .supported,
            mechanism: .githubReleases,
            mechanismName: "GitHub Releases",
            confidence: .verified,
            evidence: [],
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            versionProvider: provider,
            catalogEntryID: catalogEntryID,
            notes: "",
            kind: .application,
            packageProvenance: nil
        )
    }
}

private final class ProviderFallbackURLProtocol: URLProtocol {
    static var responses: [String: (statusCode: Int, data: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = Self.responses[url.absoluteString],
              let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
