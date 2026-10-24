import XCTest
@testable import UpdateAtlas

final class CatalogSettingsTests: XCTestCase {
    func testPublisherSearchReturnsAllItsRulesWhileAppSearchReturnsOnlyMatches() {
        let entries = [entry("alpha", publisher: "Vendor", name: "Alpha"),
                       entry("beta", publisher: "Vendor", name: "Beta"),
                       entry("other", publisher: "Other", name: "Unrelated")]
        XCTAssertEqual(CatalogPublisherGroup.matching(entries, query: "  vendor  ").first?.entries.count, 2)
        XCTAssertEqual(CatalogPublisherGroup.matching(entries, query: "BETA").flatMap(\.entries).map(\.id), ["beta"])
        XCTAssertEqual(CatalogPublisherGroup.matching(entries, query: "test.alpha").flatMap(\.entries).map(\.id), ["alpha"])
        XCTAssertTrue(CatalogPublisherGroup.matching(entries, query: "missing").isEmpty)
        XCTAssertEqual(CatalogPublisherGroup.matching(entries, query: " \n ").flatMap(\.entries).count, 3)
        let sorted = CatalogPublisherGroup.sorted(entries)
        for query in ["vendor", "BETA", "test.alpha", "missing", " \n "] {
            XCTAssertEqual(CatalogPublisherGroup.matching(sorted, query: query).flatMap(\.entries).map(\.id),
                           CatalogPublisherGroup.matching(entries, query: query).flatMap(\.entries).map(\.id))
        }
        let matches = CatalogPublisherGroup.matching(sorted, query: "vendor")
        XCTAssertEqual(CatalogPublisherGroup.automaticallyExpandedIDs(in: matches), Set(matches.map(\.id)))
        XCTAssertTrue(CatalogPublisherGroup.automaticallyExpandedIDs(in: matches, limit: 1).isEmpty)
        XCTAssertEqual(entries.count, 3)
    }

    func testMechanismGroupsConsolidatePublishersWithoutChangingRules() {
        let url = Bundle.main.url(forResource: "BootstrapCatalog", withExtension: "json")!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try! decoder.decode(RemoteCatalog.self, from: Data(contentsOf: url))
        let groups = CatalogPublisherGroup.sorted(catalog.entries)
        XCTAssertEqual(Set(groups.flatMap(\.entries).map(\.id)), Set(catalog.entries.map(\.id)))
        XCTAssertEqual(groups.flatMap(\.entries).count, catalog.entries.count)
        XCTAssertLessThanOrEqual(groups.count, 5)
        let github = groups.first { $0.category == .githubReleases }!
        XCTAssertTrue(github.entries.contains { $0.id == "prism-launcher-macos-stable" })
        XCTAssertTrue(github.entries.contains { $0.id == "open-design-macos-stable" })
        let updaters = groups.first { $0.category == .builtInUpdater }!
        XCTAssertTrue(updaters.entries.contains { $0.mechanism.type == .sparkle })
        XCTAssertTrue(updaters.entries.contains { $0.mechanism.type == .squirrel })
        XCTAssertTrue(updaters.entries.contains { $0.mechanism.type == .googleUpdater })
        XCTAssertEqual(CatalogPublisherGroup.matching(catalog.entries, query: "GitHub Releases").first?.id,
                       CatalogPublisherGroup.Category.githubReleases.rawValue)
    }

    func testRemoteSourceRejectsInvalidAndCredentialBearingURLs() {
        XCTAssertEqual(CatalogSettings.validatedRemoteURL("https://example.com/catalog.json")?.host, "example.com")
        for value in ["", "http://example.com/catalog.json", "file:///catalog.json", "https://",
                      " https://example.com/catalog.json ", "https://user:password@example.com/catalog.json"] {
            XCTAssertNil(CatalogSettings.validatedRemoteURL(value), value)
        }
    }

    private func entry(_ id: String, publisher: String, name: String) -> CatalogEntry {
        CatalogEntry(
            id: id, displayName: name, publisher: publisher,
            match: CatalogMatch(bundleIdentifiers: ["test." + id], teamIdentifiers: nil, pathSuffixes: nil),
            mechanism: CatalogMechanism(type: .externalManager, name: "Manager", feedURL: nil, managerBundleIdentifier: "test.manager"),
            support: .managedExternally, vendorURL: nil, notes: nil
        )
    }
}
