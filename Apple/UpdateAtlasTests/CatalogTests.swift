import XCTest
@testable import UpdateAtlas

final class CatalogTests: XCTestCase {
    func testBundledCatalogContainsVerifiedChromeRule() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RemoteCatalog.self, from: data)

        XCTAssertNoThrow(try CatalogValidator.validate(catalog))
        let chrome = try XCTUnwrap(
            catalog.entries.first(where: { $0.id == "google-chrome-stable-macos" })
        )
        XCTAssertEqual(chrome.match.bundleIdentifiers, ["com.google.Chrome"])
        XCTAssertEqual(chrome.match.teamIdentifiers, ["EQHXZ8M8AV"])
        XCTAssertEqual(chrome.mechanism.type, .googleUpdater)
        XCTAssertEqual(chrome.mechanism.provider?.type, .chromeVersionHistory)
        XCTAssertEqual(chrome.support, .supported)
        XCTAssertEqual(chrome.publisher, "Google")
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "comfyui-managed-stable" }))
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "chatgpt-macos-stable" }))
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "visual-studio-code-stable-macos" }))
        XCTAssertEqual(catalog.revision, 14)
        XCTAssertGreaterThanOrEqual(catalog.entries.count, 200)
        let vendorSources: [(String, String, CatalogVersionProviderKind)] = [
            ("canon-ij-scan-utility2-macos", "jp.co.canon.ij.scanutility2", .canonSupportRelease),
            ("dell-ddpm-macos", "Qisda.DDPM", .homebrewCask),
            ("logi-options-plus-macos", "com.logi.optionsplus", .homebrewCask)
        ]
        for (id, bundleID, providerKind) in vendorSources {
            let entry = try XCTUnwrap(catalog.entries.first(where: { $0.id == id }))
            XCTAssertTrue(entry.match.bundleIdentifiers?.contains(bundleID) == true, id)
            XCTAssertEqual(entry.mechanism.provider?.type, providerKind, id)
            XCTAssertEqual(entry.support, .supported, id)
        }
        let newSources: [(String, String, CatalogVersionProviderKind)] = [
            ("firefox-macos-stable", "org.mozilla.firefox", .jsonVersion),
            ("utm-macos-stable", "com.utmapp.UTM", .githubLatestRelease),
            ("slack-macos-stable", "com.tinyspeck.slackmacgap", .homebrewCask),
            ("microsoft-teams-macos-stable", "com.microsoft.teams2", .homebrewCask),
            ("antigravity-macos-stable", "com.google.antigravity", .homebrewCask),
            ("cursor-macos-stable", "com.todesktop.230313mzl4w4u92", .homebrewCask),
            ("spotify-macos-stable", "com.spotify.client", .homebrewCask),
            ("tor-browser-macos-stable", "org.torproject.torbrowser", .homebrewCask)
        ]
        for (id, bundleID, providerKind) in newSources {
            let entry = try XCTUnwrap(catalog.entries.first(where: { $0.id == id }))
            XCTAssertTrue(entry.match.bundleIdentifiers?.contains(bundleID) == true, id)
            XCTAssertEqual(entry.mechanism.provider?.type, providerKind, id)
            XCTAssertEqual(entry.support, .supported, id)
        }
        let androidStudio = try XCTUnwrap(catalog.entries.first(where: { $0.id == "android-studio-macos-stable" }))
        XCTAssertEqual(androidStudio.match.bundleIdentifiers, ["com.google.android.studio"])
        XCTAssertEqual(androidStudio.mechanism.versionProviders.map(\.type), [.androidStudioReleasePage, .homebrewCask])
        XCTAssertEqual(
            catalog.entries.first(where: { $0.id == "firefox-macos-stable" })?.mechanism.provider?.channel,
            "LATEST_FIREFOX_VERSION"
        )
        for id in ["minecraft-launcher-macos", "logitech-options-legacy-macos", "citrix-workspace-macos"] {
            XCTAssertEqual(catalog.entries.first(where: { $0.id == id })?.support, .managedExternally, id)
        }
        XCTAssertEqual(
            catalog.entries.first(where: { $0.id == "es-de-macos-stable" })?.mechanism.provider?.type,
            .jsonVersion
        )
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "retroarch-macos-stable" }))
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "jellyfin-server-macos-stable" }))
        XCTAssertEqual(
            catalog.entries.first(where: { $0.id == "open-design-macos-stable" })?.mechanism.versionProviders.first?.versionPrefix,
            "open-design-v"
        )
        XCTAssertEqual(
            catalog.entries.first(where: { $0.id == "open-design-macos-stable" })?.mechanism.versionProviders.count,
            2
        )
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "obsidian-desktop-stable" })?.openSource, false)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "qbittorrent-macos-stable" })?.openSource, true)
        XCTAssertEqual(
            catalog.entries.first(where: { $0.id == "qbittorrent-macos-stable" })?.mechanism.provider?.type,
            .platformDownloadPage
        )
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "qbittorrent-macos-stable" })?.mechanism.provider?.targetPlatform, "macOS")
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "prism-launcher-macos-stable" })?.sourceCodeURL)
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "sentinel-macos-stable" }))
        XCTAssertNotNil(catalog.entries.first(where: { $0.id == "raspberry-pi-imager-macos-stable" }))
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "hermes-desktop-macos" })?.support, .needsCatalog)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "hermes-desktop-macos" })?.mechanism.type, .squirrel)
        XCTAssertNil(catalog.entries.first(where: { $0.id == "hermes-desktop-macos" })?.mechanism.provider)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "cua-driver-macos-stable" })?.support, .supported)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "unity-hub-macos-stable" })?.support, .supported)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "steam-client-macos" })?.support, .managedExternally)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "gog-galaxy-client-macos" })?.support, .managedExternally)
        XCTAssertEqual(catalog.entries.first(where: { $0.id == "vmware-fusion-macos" })?.support, .managedExternally)

        let detected = UpdateDetectionEngine().classify(
            [
                ApplicationCandidate(
                    path: "/Applications/Google Chrome.app",
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    displayVersion: "153.0.8010.48",
                    buildVersion: "8010.48",
                    teamIdentifier: "EQHXZ8M8AV",
                    parentManagerBundleIdentifier: nil,
                    isSystemApplication: false,
                    info: [:]
                )
            ],
            catalog: catalog
        ).first

        XCTAssertEqual(detected?.catalogEntryID, "google-chrome-stable-macos")
        XCTAssertEqual(detected?.mechanism, .googleUpdater)
        XCTAssertEqual(detected?.status, .supported)
    }

    func testMechanismGroupingSortsAppsWithoutChangingRuleIDs() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RemoteCatalog.self, from: Data(contentsOf: url))
        let groups = CatalogPublisherGroup.sorted(Array(catalog.entries.reversed()))

        XCTAssertEqual(groups.map(\.category), CatalogPublisherGroup.Category.allCases.filter {
            category in groups.contains { $0.category == category }
        })
        for group in groups {
            let names = group.entries.map { $0.displayName ?? $0.id }
            XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        let updaters = groups.first { $0.category == .builtInUpdater }!
        XCTAssertGreaterThanOrEqual(updaters.entries.filter { $0.publisher == "Google" }.count, 3)
        XCTAssertEqual(updaters.entries.filter { $0.publisher == "Affinity" }.count, 4)
        XCTAssertEqual(Set(groups.flatMap(\.entries).map(\.id)), Set(catalog.entries.map(\.id)))
    }

    func testLegacyEntryWithoutPublisherStillDecodes() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(RemoteCatalog.self, from: Data(contentsOf: url))
        let chrome = try XCTUnwrap(catalog.entries.first(where: { $0.id == "google-chrome-stable-macos" }))
        let data = try JSONEncoder().encode(chrome)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "publisher")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(CatalogEntry.self, from: legacyData)
        XCTAssertNil(legacy.publisher)
        XCTAssertEqual(CatalogPublisherGroup.sorted([legacy]).first?.category, .builtInUpdater)
    }

    func testValidatorRejectsBlankPublisher() {
        let entry = CatalogEntry(
            id: "blank-publisher",
            displayName: "Example",
            publisher: "  ",
            match: CatalogMatch(
                bundleIdentifiers: ["com.example.app"],
                teamIdentifiers: nil,
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .externalManager,
                name: "Example Manager",
                feedURL: nil,
                managerBundleIdentifier: nil
            ),
            support: .managedExternally,
            vendorURL: nil,
            notes: nil
        )
        XCTAssertThrowsError(try CatalogValidator.validate(makeCatalog(revision: 1, entries: [entry]))) {
            XCTAssertEqual($0 as? CatalogValidationError, .invalidPublisher("blank-publisher"))
        }
    }

    func testCatalogMatchRequiresConfiguredTeamIdentifier() {
        let rule = CatalogMatch(
            bundleIdentifiers: ["com.example.app"],
            teamIdentifiers: ["TEAM123"],
            pathSuffixes: nil
        )

        XCTAssertTrue(rule.matches(candidate(teamIdentifier: "TEAM123")))
        XCTAssertFalse(rule.matches(candidate(teamIdentifier: "OTHER")))
        XCTAssertFalse(rule.matches(candidate(teamIdentifier: nil)))
    }

    func testBundleIdentityIgnoresLocalizedPathAndIdentifierCase() {
        let rule = CatalogMatch(
            bundleIdentifiers: ["COM.EXAMPLE.APP"],
            teamIdentifiers: ["TEAM123"],
            pathSuffixes: ["/Example App.app"]
        )
        let localized = ApplicationCandidate(
            path: "/Applications/Örnek Uygulama.app",
            name: "Örnek Uygulama",
            bundleIdentifier: "com.example.app",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: "team123",
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [:]
        )

        XCTAssertTrue(rule.matches(localized))
    }

    func testExecutableFallbackSurvivesLocalizedAndUnicodePath() {
        let rule = CatalogMatch(
            bundleIdentifiers: nil,
            teamIdentifiers: ["TEAM123"],
            pathSuffixes: ["/Example.app"],
            executableNames: ["stable-helper"]
        )
        let localized = ApplicationCandidate(
            path: "/Applications/Örnek.app",
            name: "Örnek",
            bundleIdentifier: "1.0",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: "TEAM123",
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: ["CFBundleExecutable": "STABLE-HELPER"]
        )

        XCTAssertTrue(rule.matches(localized))
    }

    func testExecutableOnlyFallbackAgreesWithPublishedSchema() throws {
        let entry = CatalogEntry(id: "executable-only", displayName: "Example",
            match: CatalogMatch(bundleIdentifiers: nil, teamIdentifiers: ["TEAM123"],
                                pathSuffixes: nil, executableNames: ["stable-helper"]),
            mechanism: CatalogMechanism(type: .externalManager, name: "Manager", feedURL: nil,
                                        managerBundleIdentifier: nil),
            support: .managedExternally, vendorURL: nil, notes: nil)
        XCTAssertNoThrow(try CatalogValidator.validate(makeCatalog(revision: 1, entries: [entry])))
    }

    func testNewRevisionPreservesPersistedRuleIDs() {
        let existing = CatalogEntry(id: "original", displayName: "Original",
            match: CatalogMatch(bundleIdentifiers: ["com.example.original"], teamIdentifiers: nil,
                                pathSuffixes: nil),
            mechanism: CatalogMechanism(type: .externalManager, name: "Manager", feedURL: nil,
                                        managerBundleIdentifier: nil),
            support: .managedExternally, vendorURL: nil, notes: nil)
        XCTAssertThrowsError(try CatalogValidator.validate(
            makeCatalog(revision: 2), cached: makeCatalog(revision: 1, entries: [existing]))) {
            XCTAssertEqual($0 as? CatalogValidationError, .removedEntryID("original"))
        }
    }

    func testCatalogCanMatchBrokenBundleIdentifierBySigningTeamAndPath() throws {
        let rule = CatalogMatch(
            bundleIdentifiers: nil,
            teamIdentifiers: ["K56UAA4SXL"],
            pathSuffixes: ["/ES-DE.app"]
        )
        let application = ApplicationCandidate(
            path: "/Applications/ES-DE.app",
            name: "ES-DE",
            bundleIdentifier: "3.4.1",
            displayVersion: "3.4.1",
            buildVersion: "3.4.1",
            teamIdentifier: "K56UAA4SXL",
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [:]
        )

        XCTAssertTrue(rule.matches(application))
    }

    func testCatalogActivationCanDisableOneRuleOrAllMatching() {
        let entry = CatalogEntry(
            id: "sample-rule",
            displayName: "Sample",
            match: CatalogMatch(
                bundleIdentifiers: ["com.example.app"],
                teamIdentifiers: nil,
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .website,
                name: "Website",
                feedURL: nil,
                managerBundleIdentifier: nil
            ),
            support: .supported,
            vendorURL: URL(string: "https://example.com"),
            notes: nil
        )
        let catalog = makeCatalog(revision: 1, entries: [entry])
        let key = CatalogActivationPolicy.ruleKey(
            catalogID: catalog.catalogID,
            entryID: entry.id
        )

        XCTAssertEqual(
            CatalogActivationPolicy.applying(
                to: catalog,
                matchingEnabled: true,
                disabledRuleKeys: []
            ).entries.count,
            1
        )
        XCTAssertTrue(
            CatalogActivationPolicy.applying(
                to: catalog,
                matchingEnabled: true,
                disabledRuleKeys: [key]
            ).entries.isEmpty
        )
        XCTAssertTrue(
            CatalogActivationPolicy.applying(
                to: catalog,
                matchingEnabled: false,
                disabledRuleKeys: []
            ).entries.isEmpty
        )
        XCTAssertFalse(CatalogLoadPurpose.disabled.requiresRemoteRefresh)
    }

    func testValidatorRejectsInsecureFeedURL() {
        let entry = CatalogEntry(
            id: "insecure",
            displayName: nil,
            match: CatalogMatch(
                bundleIdentifiers: ["com.example.app"],
                teamIdentifiers: nil,
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .sparkle,
                name: "Sparkle",
                feedURL: URL(string: "http://example.com/appcast.xml"),
                managerBundleIdentifier: nil
            ),
            support: .supported,
            vendorURL: nil,
            notes: nil
        )
        let catalog = makeCatalog(revision: 1, entries: [entry])

        XCTAssertThrowsError(try CatalogValidator.validate(catalog)) { error in
            guard case CatalogValidationError.insecureURL = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testValidatorRejectsCatalogRollback() {
        XCTAssertThrowsError(
            try CatalogValidator.validate(
                makeCatalog(revision: 4),
                cached: makeCatalog(revision: 5)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogValidationError, .rollback(remote: 4, cached: 5))
        }
    }

    func testValidatorRejectsSupportedEntryWithoutVersionProvider() {
        let entry = CatalogEntry(
            id: "missing-feed",
            displayName: nil,
            match: CatalogMatch(
                bundleIdentifiers: ["com.example.app"],
                teamIdentifiers: nil,
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .sparkle,
                name: "Sparkle",
                feedURL: nil,
                managerBundleIdentifier: nil
            ),
            support: .supported,
            vendorURL: nil,
            notes: nil
        )

        XCTAssertThrowsError(try CatalogValidator.validate(makeCatalog(revision: 1, entries: [entry]))) {
            XCTAssertEqual($0 as? CatalogValidationError, .missingVersionProvider("missing-feed"))
        }
    }

    func testCatalogCarriesAnOrderedProviderChainIntoDetectedSoftware() throws {
        let primary = CatalogVersionProvider(
            type: .jsonVersion,
            url: URL(string: "https://updates.example.com/version.json")!,
            channel: "version"
        )
        let fallback = CatalogVersionProvider(
            type: .githubLatestRelease,
            url: URL(string: "https://api.github.com/repos/example/app/releases/latest")!,
            channel: "stable"
        )
        let entry = CatalogEntry(
            id: "provider-chain",
            displayName: "Example",
            match: CatalogMatch(
                bundleIdentifiers: ["com.example.app"],
                teamIdentifiers: ["TEAM123"],
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .website,
                name: "Official release sources",
                feedURL: nil,
                managerBundleIdentifier: nil,
                providers: [primary, fallback]
            ),
            support: .supported,
            vendorURL: URL(string: "https://example.com"),
            notes: nil
        )
        let catalog = makeCatalog(revision: 1, entries: [entry])

        XCTAssertNoThrow(try CatalogValidator.validate(catalog))
        XCTAssertEqual(entry.mechanism.versionProviders, [primary, fallback])

        let application = try XCTUnwrap(
            UpdateDetectionEngine().classify(
                [candidate(teamIdentifier: "TEAM123")],
                catalog: catalog
            ).first
        )
        XCTAssertEqual(application.versionProviders, [primary, fallback])
    }

    func testValidatorRejectsAnInsecureFallbackProvider() {
        let entry = CatalogEntry(
            id: "insecure-fallback",
            displayName: "Example",
            match: CatalogMatch(
                bundleIdentifiers: ["com.example.app"],
                teamIdentifiers: nil,
                pathSuffixes: nil
            ),
            mechanism: CatalogMechanism(
                type: .website,
                name: "Release sources",
                feedURL: nil,
                managerBundleIdentifier: nil,
                providers: [
                    CatalogVersionProvider(
                        type: .jsonVersion,
                        url: URL(string: "https://updates.example.com/version.json")!,
                        channel: "version"
                    ),
                    CatalogVersionProvider(
                        type: .jsonVersion,
                        url: URL(string: "http://fallback.example.com/version.json")!,
                        channel: "version"
                    )
                ]
            ),
            support: .supported,
            vendorURL: nil,
            notes: nil
        )

        XCTAssertThrowsError(try CatalogValidator.validate(makeCatalog(revision: 1, entries: [entry]))) {
            guard case CatalogValidationError.insecureURL = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    private func candidate(teamIdentifier: String?) -> ApplicationCandidate {
        ApplicationCandidate(
            path: "/Applications/Example.app",
            name: "Example",
            bundleIdentifier: "com.example.app",
            displayVersion: "1.0",
            buildVersion: "1",
            teamIdentifier: teamIdentifier,
            parentManagerBundleIdentifier: nil,
            isSystemApplication: false,
            info: [:]
        )
    }

    private func makeCatalog(
        revision: Int,
        entries: [CatalogEntry] = []
    ) -> RemoteCatalog {
        RemoteCatalog(
            schemaVersion: 1,
            catalogID: "test",
            revision: revision,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: nil,
            entries: entries
        )
    }
}
