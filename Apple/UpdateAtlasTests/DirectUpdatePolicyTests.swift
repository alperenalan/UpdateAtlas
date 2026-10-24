import XCTest
import Sparkle
@testable import UpdateAtlas

@MainActor
final class DirectUpdatePolicyTests: XCTestCase {
    func testOnlyEmbeddedHTTPSFeedAndEdDSAKeyAreAccepted() {
        let url = URL(fileURLWithPath: "/Applications/Fixture.app")
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        let valid: [String: Any] = ["SUFeedURL": "https://publisher.example/appcast.xml", "SUPublicEDKey": key]
        XCTAssertNotNil(DirectUpdatePolicy.configuration(bundleURL: url, info: valid))
        for feed in ["http://publisher.example/feed", "file:///feed", "https://user:pass@publisher.example/feed", ""] {
            var invalid = valid
            invalid["SUFeedURL"] = feed
            XCTAssertNil(DirectUpdatePolicy.configuration(bundleURL: url, info: invalid))
        }
        for publicKey in ["", "not a key", Data(repeating: 0, count: 31).base64EncodedString()] {
            var invalid = valid
            invalid["SUPublicEDKey"] = publicKey
            XCTAssertNil(DirectUpdatePolicy.configuration(bundleURL: url, info: invalid))
        }
    }

    func testEligibilityRejectsManagersChildrenNonStableAndIdentityMismatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".temporary_files/direct-update-tests/" + UUID().uuidString)
        let appURL = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "test.fixture", "CFBundleName": "Fixture",
            "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
            "SUFeedURL": "https://publisher.example/feed", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        func item(mechanism: UpdateMechanismKind = .sparkle, parent: String? = nil,
                  channel: ReleaseChannel = .init(kind: .stable), bundleID: String = "test.fixture",
                  availability: UpdateAvailability = .updateAvailable) -> InstalledApplication {
            InstalledApplication(inventoryID: "fixture", path: appURL.path, name: "Fixture",
                bundleIdentifier: bundleID, displayVersion: "1", buildVersion: "1", teamIdentifier: nil,
                status: .supported, mechanism: mechanism, mechanismName: "Sparkle", confidence: .verified,
                evidence: [], parentInventoryID: parent, parentManagerBundleIdentifier: nil,
                parentManagerName: nil, vendorURL: nil, catalogEntryID: nil, notes: "",
                kind: .application, packageProvenance: nil, releaseChannel: channel,
                updateCheck: UpdateCheckResult(availability: availability, installedVersion: "1", latestVersion: "2",
                    checkedAt: nil, source: .sparkleAppcast, detail: ""))
        }
        XCTAssertNotNil(DirectUpdatePolicy.configuration(for: item()))
        let cached = Bundle(url: appURL)
        _ = cached?.infoDictionary
        var replacement = info
        replacement["SUFeedURL"] = "https://publisher.example/new-feed"
        try PropertyListSerialization.data(fromPropertyList: replacement, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(DirectUpdatePolicy.configuration(for: item())?.feedURL.absoluteString,
                       "https://publisher.example/new-feed")
        XCTAssertFalse(DirectUpdateService.hasValidSignature(appURL, bundleIdentifier: "test.fixture", teamIdentifier: "TESTTEAM"))
        XCTAssertFalse(DirectUpdateService.hasValidSignature(appURL, bundleIdentifier: "test.fixture", teamIdentifier: nil))
        XCTAssertNil(DirectUpdatePolicy.configuration(for: item(mechanism: .homebrew)))
        XCTAssertNil(DirectUpdatePolicy.configuration(for: item(parent: "owner")))
        XCTAssertNil(DirectUpdatePolicy.configuration(for: item(channel: .init(kind: .beta))))
        XCTAssertNil(DirectUpdatePolicy.configuration(for: item(bundleID: "test.other")))
        XCTAssertNil(DirectUpdatePolicy.configuration(for: item(availability: .upToDate)))
    }

    func testInstallerRejectsPackagesInsecureDownloadsAndPrereleases() {
        let url = URL(string: "https://publisher.example/update.zip")!
        XCTAssertTrue(DirectUpdatePolicy.allowsRelease(downloadURL: url, installationType: "application",
                      version: "2.0", channel: nil, informationOnly: false))
        XCTAssertFalse(DirectUpdatePolicy.allowsRelease(downloadURL: URL(string: "http://publisher.example/update.zip"), installationType: "application", version: "2.0", channel: nil, informationOnly: false))
        XCTAssertFalse(DirectUpdatePolicy.allowsRelease(downloadURL: url, installationType: "package", version: "2.0", channel: nil, informationOnly: false))
        XCTAssertFalse(DirectUpdatePolicy.allowsRelease(downloadURL: url, installationType: "application", version: "2.0 beta 1", channel: nil, informationOnly: false))
        XCTAssertFalse(DirectUpdatePolicy.allowsRelease(downloadURL: url, installationType: "application", version: "2.0", channel: "beta", informationOnly: false))
        XCTAssertFalse(DirectUpdatePolicy.allowsRelease(downloadURL: nil, installationType: "application", version: "2.0", channel: nil, informationOnly: true))
    }

    func testManualUpdaterDoesNotAlterHostAutomaticPreferences() {
        let bundle = Bundle.main
        let before = UserDefaults.standard.persistentDomain(forName: bundle.bundleIdentifier!) ?? [:]
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = ManualSparkleUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        // Do not start an updater or access the network during this test.
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        updater.sendsSystemProfile = true
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertFalse(updater.allowsAutomaticUpdates)
        XCTAssertFalse(updater.sendsSystemProfile)
        let after = UserDefaults.standard.persistentDomain(forName: bundle.bundleIdentifier!) ?? [:]
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUSendProfileInfo"] {
            XCTAssertEqual(before[key] as? Bool, after[key] as? Bool, key)
        }
    }
}
