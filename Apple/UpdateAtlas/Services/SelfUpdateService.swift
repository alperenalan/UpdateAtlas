import Foundation
import Sparkle

/// The app's own update channel is deliberately separate from software catalog checks.
@MainActor
final class SelfUpdateService {
    static let shared = SelfUpdateService()

    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    private init() {
        guard Self.isConfigured(in: .main) else {
            controller = nil
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    static func isConfigured(in bundle: Bundle) -> Bool {
        isConfigured(
            feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        )
    }

    static func isConfigured(feed: String?, publicKey: String?) -> Bool {
        guard let feed,
              let url = URL(string: feed),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.fragment == nil,
              let publicKey,
              Data(base64Encoded: publicKey)?.count == 32 else { return false }
        return true
    }
}
