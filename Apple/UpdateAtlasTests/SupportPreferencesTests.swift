import XCTest
@testable import UpdateAtlas

final class SupportPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "support-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testThirdSuccessfulNonemptyScanBecomesEligibleWithoutUpdateRequirement() {
        withDefaults { defaults in
            let state = SupportPreferences(defaults: defaults)
            let destination = URL(string: "https://example.invalid/support")!
            for count in 1...3 {
                state.recordCompletedScan(successful: true, itemCount: 1)
                XCTAssertEqual(state.successfulScanCount, count)
                XCTAssertEqual(state.shouldPresentReminder(destination: destination), count == 3)
            }
            XCTAssertFalse(state.hasShownReminder)
        }
    }

    func testFailedEmptyAndCancelledOutcomesDoNotAdvanceExistingCount() {
        withDefaults { defaults in
            let state = SupportPreferences(defaults: defaults)
            state.recordCompletedScan(successful: true, itemCount: 7)
            state.recordCompletedScan(successful: false, itemCount: 7)
            state.recordCompletedScan(successful: true, itemCount: 0)
            state.recordCompletedScan(successful: false, itemCount: 0)
            XCTAssertEqual(state.successfulScanCount, 1)
        }
    }

    func testRelaunchRestoresCountAndShownReminderNeverRecursEvenWithoutDismissal() {
        withDefaults { defaults in
            let destination = URL(string: "https://example.invalid/support")!
            SupportPreferences(defaults: defaults).recordCompletedScan(successful: true, itemCount: 2)
            let restored = SupportPreferences(defaults: defaults)
            XCTAssertEqual(restored.successfulScanCount, 1)
            restored.recordCompletedScan(successful: true, itemCount: 2)
            restored.recordCompletedScan(successful: true, itemCount: 2)
            restored.markReminderShown()
            let relaunched = SupportPreferences(defaults: defaults)
            for _ in 0..<10 { relaunched.recordCompletedScan(successful: true, itemCount: 2) }
            XCTAssertEqual(relaunched.successfulScanCount, 3)
            XCTAssertTrue(relaunched.hasShownReminder)
            XCTAssertFalse(relaunched.hasDismissedReminder)
            XCTAssertFalse(relaunched.shouldPresentReminder(destination: destination))
        }
    }

    func testMissingDestinationDoesNotConsumeReminderAndDismissalSurvivesRelaunch() {
        withDefaults { defaults in
            let state = SupportPreferences(defaults: defaults)
            for _ in 0..<3 { state.recordCompletedScan(successful: true, itemCount: 2) }
            XCTAssertFalse(state.shouldPresentReminder(destination: nil))
            XCTAssertFalse(state.hasShownReminder)
            let destination = URL(string: "https://example.invalid/support")!
            XCTAssertTrue(state.shouldPresentReminder(destination: destination))
            state.dismissReminder()
            let restored = SupportPreferences(defaults: defaults)
            XCTAssertTrue(restored.hasShownReminder)
            XCTAssertTrue(restored.hasDismissedReminder)
            XCTAssertFalse(restored.shouldPresentReminder(destination: destination))
        }
    }

    @MainActor
    func testViewModelRecordsOnlyCompletedQualifyingScansAndDismisses() {
        withDefaults { defaults in
            let state = SupportPreferences(defaults: defaults)
            let model = AppInventoryViewModel(supportPreferences: state)
            model.recordSupportScanCompletion(successful: false, itemCount: 20)
            model.recordSupportScanCompletion(successful: true, itemCount: 0)
            XCTAssertEqual(state.successfulScanCount, 0)
            for _ in 0..<3 { model.recordSupportScanCompletion(successful: true, itemCount: 20) }
            XCTAssertEqual(model.isSupportReminderPresented, SupportSettings.configuredURL != nil)
            model.markSupportReminderShown()
            model.dismissSupportReminder()
            XCTAssertFalse(model.isSupportReminderPresented)
            model.recordSupportScanCompletion(successful: true, itemCount: 20)
            XCTAssertFalse(model.isSupportReminderPresented)
        }
    }

    func testAddingSupportKeysPreservesExistingPreferences() {
        withDefaults { defaults in
            defaults.set(true, forKey: OnboardingSettings.completedKey)
            defaults.set("games", forKey: InventorySettings.defaultViewKey)
            let state = SupportPreferences(defaults: defaults)
            XCTAssertEqual(state.successfulScanCount, 0)
            state.recordCompletedScan(successful: true, itemCount: 1)
            XCTAssertTrue(defaults.bool(forKey: OnboardingSettings.completedKey))
            XCTAssertEqual(defaults.string(forKey: InventorySettings.defaultViewKey), "games")
        }
    }

    func testOnlyConfiguredHTTPSDestinationWithoutCredentialsIsAccepted() {
        for value in [nil, "", " ", "https://", "http://example.invalid", "file:///tmp/test", "javascript:alert(1)", "https://user:pass@example.invalid", " https://example.invalid"] {
            XCTAssertNil(SupportSettings.validatedURL(value), value ?? "nil")
        }
        XCTAssertEqual(SupportSettings.validatedURL("https://buymeacoffee.com/alperenalan")?.host, "buymeacoffee.com")
    }

    func testAboutLinksPointToSingleSourceRepository() {
        XCTAssertEqual(AboutLinks.repositoryURL.absoluteString, "https://github.com/alperenalan/UpdateAtlas")
    }
}
