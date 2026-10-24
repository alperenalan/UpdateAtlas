import Foundation
import XCTest
@testable import UpdateAtlas

final class BundledAppResourcesTests: XCTestCase {
    func testInstalledStyleSymlinkLoadsCatalogAndVersionFromActualApp() async throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanUp() }
        let link = fixture.root.appendingPathComponent("home/.local/bin/update-atlas")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.helper)
        let bundle = try XCTUnwrap(BundledAppResources.applicationBundle(executableURL: link))
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "28")
        let catalogURL = try XCTUnwrap(BundledAppResources.bootstrapCatalogURL(executableURL: link))
        XCTAssertEqual(catalogURL.resolvingSymlinksInPath(), fixture.catalog.resolvingSymlinksInPath())
        let snapshot = await fixture.service(catalogURL: catalogURL).snapshot(for: .localOnly)
        XCTAssertEqual(snapshot.catalog.revision, 7)
        XCTAssertEqual(snapshot.source, .bundled)
    }

    func testRelativeChainedLinksWorkWithRenamedAppAndSpaces() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanUp() }
        let alias = fixture.root.appendingPathComponent("alias")
        let link = fixture.root.appendingPathComponent("update-atlas")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.helper)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "alias")
        XCTAssertEqual(BundledAppResources.applicationBundle(executableURL: link)?.bundleURL.resolvingSymlinksInPath().path,
                       fixture.app.resolvingSymlinksInPath().path)
        XCTAssertEqual(BundledAppResources.bootstrapCatalogURL(executableURL: link)?.resolvingSymlinksInPath(),
                       fixture.catalog.resolvingSymlinksInPath())
    }

    func testGUIAndDirectHelperFindSameAppResources() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanUp() }
        for executable in [fixture.helper, fixture.app.appendingPathComponent("Contents/MacOS/Fixture")] {
            XCTAssertEqual(BundledAppResources.bootstrapCatalogURL(executableURL: executable)?.resolvingSymlinksInPath(),
                           fixture.catalog.resolvingSymlinksInPath())
        }
    }

    func testStandaloneAndBrokenLinksDoNotAdoptAdjacentCatalogs() throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanUp() }
        let standalone = fixture.root.appendingPathComponent("update-atlas")
        try Data().write(to: standalone)
        try Data(contentsOf: fixture.catalog).write(to: fixture.root.appendingPathComponent("BootstrapCatalog.json"))
        XCTAssertNil(BundledAppResources.applicationBundle(executableURL: standalone))
        XCTAssertNil(BundledAppResources.bootstrapCatalogURL(executableURL: standalone))
        let broken = fixture.root.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: fixture.root.appendingPathComponent("missing"))
        XCTAssertNil(BundledAppResources.bootstrapCatalogURL(executableURL: broken))
        XCTAssertNil(BundledAppResources.applicationBundle(executableURL: nil))
    }

    func testMissingOrMalformedCatalogStillFailsClosed() async throws {
        let fixture = try ResourceFixture()
        defer { fixture.cleanUp() }
        try Data("not a catalog".utf8).write(to: fixture.catalog)
        let malformed = await fixture.service(catalogURL: fixture.catalog).snapshot(for: .localOnly)
        XCTAssertEqual(malformed.catalog.revision, 0)
        XCTAssertTrue(malformed.catalog.entries.isEmpty)
        try FileManager.default.removeItem(at: fixture.catalog)
        let missing = await fixture.service(catalogURL: fixture.catalog).snapshot(for: .localOnly)
        XCTAssertEqual(missing.catalog.revision, 0)
        XCTAssertTrue(missing.catalog.entries.isEmpty)
    }
}

private struct ResourceFixture {
    let root: URL
    let app: URL
    let helper: URL
    let catalog: URL
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let id = UUID().uuidString
        root = project.appendingPathComponent(".temporary_files/bundle-resources-tests/" + id)
        app = root.appendingPathComponent("Renamed Update Atlas.app")
        helper = app.appendingPathComponent("Contents/MacOS/Helpers/update-atlas")
        catalog = app.appendingPathComponent("Contents/Resources/BootstrapCatalog.json")
        suite = AppIdentity.bundleIdentifier + ".tests.resources." + id
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = FileManager.default
        try manager.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: catalog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": suite, "CFBundleExecutable": "Fixture",
                                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "28"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: helper)
        try Data().write(to: app.appendingPathComponent("Contents/MacOS/Fixture"))
        let value = RemoteCatalog(schemaVersion: RemoteCatalog.supportedSchemaVersion, catalogID: "fixture", revision: 7,
                                  generatedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil, entries: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: catalog)
    }

    func service(catalogURL: URL?) -> RemoteCatalogService {
        RemoteCatalogService(cacheDirectory: root.appendingPathComponent("cache"), bundledCatalogURL: catalogURL)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
