import Foundation
import os
import Testing
@testable import UpdateAtlas

@Suite("Version comparison and unreadable installed versions")
struct VersionComparisonTests {
    @Test("Ordered version pairs compare as older, equal or newer", arguments: [
        ("2.0", "2.0.0", ComparisonResult.orderedSame),
        ("2.0.0.0", "2", .orderedSame),
        ("v2.0.9", "2.0.9", .orderedSame),
        ("release-5.2.3", "5.2.3", .orderedSame),
        ("2.0.9", "2.0.10", .orderedAscending),
        ("1.10", "1.9.9", .orderedDescending),
        ("1.2", "1.2.1", .orderedAscending),
        ("1.2.0-beta.1", "1.2.0", .orderedAscending),
        ("1.2.0", "1.2.0-rc1", .orderedDescending),
        ("1.2.0b2", "1.2.0", .orderedAscending),
        ("1.2.0-alpha.3", "1.2.0-beta.1", .orderedAscending),
        ("1.2.0-beta.2", "1.2.0-beta.10", .orderedAscending),
        ("1.2.0-rc.1", "1.2.0-beta.4", .orderedDescending),
        ("1.2.0-beta.1", "1.1.9", .orderedDescending),
        ("1.2.3 (456)", "1.2.3 (457)", .orderedAscending),
        ("1.2.3", "1.2.3 (456)", .orderedAscending),
        ("1.2.3_1", "1.2.3", .orderedDescending),
        ("2024.3.1", "2024.3.1", .orderedSame),
        ("20231012123456789012", "20231012123456789011", .orderedDescending)
    ])
    func comparesVersions(lhs: String, rhs: String, expected: ComparisonResult) {
        #expect(VersionComparator.compare(lhs, rhs) == expected)
        #expect(VersionComparator.compare(rhs, lhs) == expected.reversed)
    }

    @Test("Prerelease builds never outrank their final release")
    func prereleaseIsNotNewerThanRelease() {
        #expect(!VersionComparator.isNewer("3.0.0-beta.1", than: "3.0.0"))
        #expect(VersionComparator.isNewer("3.0.0", than: "3.0.0-beta.1"))
        #expect(VersionComparator.isSame("3.0", "3.0.0"))
    }

    @Test("Only versions with a digit are comparable", arguments: [
        ("1.0", true), ("37", true), ("", false), ("Unknown", false), ("Bilinmiyor", false), ("—", false)
    ])
    func comparableVersionNeedsADigit(version: String, comparable: Bool) {
        #expect(UpdateCheckService.hasComparableVersion(version) == comparable)
    }

    @Test("An unreadable installed version is pending, never current or outdated", arguments: ["Unknown", "", "n/a"])
    func unreadableVersionIsPending(installed: String) async throws {
        let url = try #require(URL(string: "https://version-fixture.example.com/\(UUID().uuidString).json"))
        FixtureVersionURLProtocol.set(Data(#"{"version":"2.0.0"}"#.utf8), for: url)
        defer { FixtureVersionURLProtocol.remove(url) }
        let provider = CatalogVersionProvider(type: .jsonVersion, url: url, channel: "version")
        let application = makeApplication(version: installed, build: installed, mechanism: .website, provider: provider)

        let result = try #require(await UpdateCheckService(session: FixtureVersionURLProtocol.session()).check([application]).first)

        #expect(result.updateCheck.availability == .sourcePending)
        #expect(result.updateCheck.latestVersion == nil)
    }

    @Test("A Sparkle app without a readable build number is pending")
    func unreadableSparkleBuildIsPending() async throws {
        let url = try #require(URL(string: "https://version-fixture.example.com/\(UUID().uuidString)/appcast.xml"))
        let feed = #"<rss><channel><item><enclosure sparkle:version="2" sparkle:shortVersionString="2.0" /></item></channel></rss>"#
        FixtureVersionURLProtocol.set(Data(feed.utf8), for: url)
        defer { FixtureVersionURLProtocol.remove(url) }
        let provider = CatalogVersionProvider(type: .sparkleAppcast, url: url, channel: nil)
        let application = makeApplication(version: "Unknown", build: "Unknown", mechanism: .sparkle, provider: provider)

        let result = try #require(await UpdateCheckService(session: FixtureVersionURLProtocol.session()).check([application]).first)

        #expect(result.updateCheck.availability == .sourcePending)
        #expect(result.updateCheck.source == .sparkleAppcast)
    }

    @Test("A readable installed version still reaches a verdict")
    func readableVersionStillCompares() async throws {
        let url = try #require(URL(string: "https://version-fixture.example.com/\(UUID().uuidString).json"))
        FixtureVersionURLProtocol.set(Data(#"{"version":"2.0.0"}"#.utf8), for: url)
        defer { FixtureVersionURLProtocol.remove(url) }
        let provider = CatalogVersionProvider(type: .jsonVersion, url: url, channel: "version")
        let checker = UpdateCheckService(session: FixtureVersionURLProtocol.session())

        let older = try #require(await checker.check([makeApplication(version: "1.9", build: "1", mechanism: .website, provider: provider)]).first)
        let same = try #require(await checker.check([makeApplication(version: "2.0", build: "1", mechanism: .website, provider: provider)]).first)

        #expect(older.updateCheck.availability == .updateAvailable)
        #expect(same.updateCheck.availability == .upToDate)
    }

    @Test("An npm latest tag older than the installed prerelease is not an update")
    func npmOlderLatestTagIsNotAnUpdate() async throws {
        func package(installed: String, latest: String) -> InstalledApplication {
            let provenance = PackageProvenance(
                identifier: "cf", manager: .npm, managerExecutablePath: "/opt/homebrew/bin/npm",
                installLocation: nil, explicitlyInstalled: true, homepage: nil, summary: nil,
                isOutdated: true, latestVersion: latest
            )
            return InstalledApplication(
                inventoryID: "npm-fixture", path: "/opt/homebrew/lib/node_modules/cf", name: "cf",
                bundleIdentifier: "npm:cf", displayVersion: installed, buildVersion: installed, teamIdentifier: nil,
                status: .supported, mechanism: .npm, mechanismName: "npm", confidence: .verified, evidence: [],
                parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
                versionProvider: nil, catalogEntryID: nil, notes: "", kind: .commandLineTool, packageProvenance: provenance
            )
        }
        let checker = UpdateCheckService(session: FixtureVersionURLProtocol.session())

        let downgrade = try #require(await checker.check([package(installed: "1.0.0-beta.12", latest: "0.15.0")]).first)
        let upgrade = try #require(await checker.check([package(installed: "0.14.0", latest: "0.15.0")]).first)

        #expect(downgrade.updateCheck.availability == .upToDate)
        #expect(upgrade.updateCheck.availability == .updateAvailable)
    }

    private func makeApplication(
        version: String,
        build: String,
        mechanism: UpdateMechanismKind,
        provider: CatalogVersionProvider
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: "version-fixture", path: "/Applications/Fixture.app", name: "Fixture",
            bundleIdentifier: "fixture.version", displayVersion: version, buildVersion: build, teamIdentifier: nil,
            status: .supported, mechanism: mechanism, mechanismName: "Fixture", confidence: .verified, evidence: [],
            parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
            versionProvider: provider, catalogEntryID: "fixture", notes: "", kind: .application, packageProvenance: nil
        )
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}

/// Serves fixture bodies keyed by unique URLs, so parallel tests never share a response.
private final class FixtureVersionURLProtocol: URLProtocol {
    private static let responses = OSAllocatedUnfairLock(initialState: [String: Data]())

    static func set(_ data: Data, for url: URL) {
        responses.withLock { $0[url.absoluteString] = data }
    }

    static func remove(_ url: URL) {
        _ = responses.withLock { $0.removeValue(forKey: url.absoluteString) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureVersionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let data = Self.responses.withLock({ $0[url.absoluteString] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
