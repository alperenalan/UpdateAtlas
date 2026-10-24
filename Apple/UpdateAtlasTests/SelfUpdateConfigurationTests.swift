import Foundation
import Testing
@testable import UpdateAtlas

private let validPublicKey = Data(repeating: 0x42, count: 32).base64EncodedString()

@Suite("Sparkle feed configuration")
struct SelfUpdateConfigurationTests {
    @Test("Only HTTPS feeds with a valid 32-byte Ed25519 public key enable self-updates",
          arguments: [
            (nil as String?, validPublicKey as String?, false),
            ("" as String?, validPublicKey as String?, false),
            ("http://updates.example.test/appcast.xml" as String?, validPublicKey as String?, false),
            ("https://updates.example.test/appcast.xml" as String?, nil as String?, false),
            ("https://updates.example.test/appcast.xml" as String?, "" as String?, false),
            ("https://updates.example.test/appcast.xml" as String?, "not-base64" as String?, false),
            ("https://updates.example.test/appcast.xml" as String?, "YWJj" as String?, false),
            ("https://user:password@updates.example.test/appcast.xml" as String?, validPublicKey as String?, false),
            ("https://updates.example.test/appcast.xml#fragment" as String?, validPublicKey as String?, false),
            ("https://updates.example.test/appcast.xml" as String?, validPublicKey as String?, true)
          ])
    @MainActor
    func requiresSecureFeedAndKey(feed: String?, key: String?, expected: Bool) {
        #expect(SelfUpdateService.isConfigured(feed: feed, publicKey: key) == expected)
    }
}
