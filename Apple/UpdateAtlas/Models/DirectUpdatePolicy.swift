import Foundation

/// Eligibility comes from the installed bundle, never a remotely supplied install recipe.
enum DirectUpdatePolicy {
    struct Configuration: Equatable {
        let bundleURL: URL
        let feedURL: URL
        let publicKey: String
    }

    static func configuration(for application: InstalledApplication) -> Configuration? {
        guard application.kind == .application, application.mechanism == .sparkle,
              application.packageProvenance == nil, !application.isManagedChild,
              application.bundleIdentifier != AppIdentity.bundleIdentifier,
              application.updateCheck.availability == .updateAvailable,
              application.releaseChannel.kind == .stable,
              application.path.hasSuffix(".app"),
              let info = ApplicationBundleMetadataReader.infoDictionary(at: URL(fileURLWithPath: application.path)),
              info["CFBundleIdentifier"] as? String == application.bundleIdentifier,
              !FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: application.path).appendingPathComponent("Contents/_MASReceipt/receipt").path),
              FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: application.path).appendingPathComponent("Contents/Frameworks/Sparkle.framework").path) else { return nil }
        return configuration(bundleURL: URL(fileURLWithPath: application.path), info: info)
    }

    static func allowsRelease(downloadURL: URL?, installationType: String, version: String,
                              channel: String?, informationOnly: Bool) -> Bool {
        guard let downloadURL, CatalogSettings.validatedRemoteURL(downloadURL.absoluteString) != nil,
              installationType == "application", !informationOnly,
              channel == nil || channel == "",
              ReleaseChannel.detect(version: version, explicitName: nil, bundleIdentifier: "").kind == .stable
        else { return false }
        return true
    }

    static func configuration(bundleURL: URL, info: [String: Any]) -> Configuration? {
        guard let feed = info["SUFeedURL"] as? String,
              let url = CatalogSettings.validatedRemoteURL(feed),
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        return Configuration(bundleURL: bundleURL, feedURL: url, publicKey: key)
    }
}
