import XCTest
@testable import UpdateAtlas

@MainActor
final class BackgroundChecksTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "background.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOptInAndManualCompletionAnchorNextCheckWithoutChangingExistingSettings() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var scans = 0
        defaults.set(false, forKey: MenuBarSettings.enabledKey)
        let service = BackgroundCheckService(defaults: defaults, usesTimers: false, now: { now }, isBusy: { false }, isOnboarded: { true }, scan: { scans += 1 })
        service.start(observeWorkspace: false)
        XCTAssertNil(service.nextCheckDate)
        await service.checkIfDue()
        XCTAssertEqual(scans, 0)
        service.setEnabled(true)
        service.setInterval(.hourly)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(3_600))
        now.addTimeInterval(1_000)
        service.scanCompleted(at: now)
        now.addTimeInterval(3_599)
        await service.checkIfDue()
        XCTAssertEqual(scans, 0)
        now.addTimeInterval(1)
        await service.checkIfDue()
        XCTAssertEqual(scans, 1)
        await service.checkIfDue()
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(3_600))
        XCTAssertFalse(defaults.bool(forKey: MenuBarSettings.enabledKey))
    }

    func testOverdueWakeDoesOneCheckAndBusyScanDefersIt() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var busy = true
        var scans = 0
        let service = BackgroundCheckService(defaults: defaults, usesTimers: false, now: { now }, isBusy: { busy }, isOnboarded: { true }, scan: { scans += 1 })
        service.start(observeWorkspace: false)
        service.setEnabled(true)
        service.systemWillSleep()
        now.addTimeInterval(48 * 3_600)
        await service.checkIfDue()
        XCTAssertEqual(scans, 0)
        service.systemDidWake()
        await service.checkIfDue()
        XCTAssertEqual(scans, 0)
        busy = false
        await service.checkIfDue()
        await service.checkIfDue()
        XCTAssertEqual(scans, 1)
        let relaunched = BackgroundCheckService(defaults: defaults, usesTimers: false, now: { now }, isBusy: { false }, isOnboarded: { true }, scan: { scans += 1 })
        relaunched.start(observeWorkspace: false)
        await relaunched.checkIfDue()
        XCTAssertEqual(scans, 1)
        XCTAssertEqual(relaunched.nextCheckDate, now.addingTimeInterval(6 * 3_600))
    }

    func testSleepCancelsScheduledTaskAndRetriesAfterWake() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let gate = BackgroundTestGate()
        var cancelled = false
        let service = BackgroundCheckService(defaults: defaults, usesTimers: false, now: { now }, isBusy: { false }, isOnboarded: { true }, scan: {
            await gate.wait()
            cancelled = Task.isCancelled
        })
        service.start(observeWorkspace: false)
        service.setEnabled(true)
        now.addTimeInterval(6 * 3_600)
        let task = Task { await service.checkIfDue() }
        await gate.waitUntilEntered()
        XCTAssertTrue(service.isRunningScheduledScan)
        service.systemWillSleep()
        gate.release()
        await task.value
        XCTAssertTrue(cancelled)
        XCTAssertNil(service.nextCheckDate)
        now.addTimeInterval(60)
        service.systemDidWake()
        XCTAssertEqual(service.nextCheckDate, now)
        service.setEnabled(false)
        XCTAssertNil(service.nextCheckDate)
    }

    func testInvalidIntervalAndFutureDateRecoverWithoutRunningBeforeOnboarding() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var onboarded = false
        var scans = 0
        defaults.set(true, forKey: BackgroundCheckSettings.enabledKey)
        defaults.set(-1, forKey: BackgroundCheckSettings.intervalKey)
        defaults.set(now.addingTimeInterval(365 * 86_400), forKey: BackgroundCheckSettings.lastAttemptKey)
        let service = BackgroundCheckService(defaults: defaults, usesTimers: false, now: { now }, isBusy: { false }, isOnboarded: { onboarded }, scan: { scans += 1 })
        service.start(observeWorkspace: false)
        await service.checkIfDue()
        XCTAssertNil(service.nextCheckDate)
        XCTAssertEqual(scans, 0)
        onboarded = true
        service.refresh()
        XCTAssertEqual(service.interval, .sixHours)
        XCTAssertEqual(defaults.object(forKey: BackgroundCheckSettings.lastAttemptKey) as? Date, now)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(6 * 3_600))
    }

    func testNativeTimerRunsADeferredCheckExactlyOnce() async {
        let now = Date()
        let fired = expectation(description: "native timer initiated scan")
        var scans = 0
        defaults.set(true, forKey: BackgroundCheckSettings.enabledKey)
        defaults.set(now.addingTimeInterval(-6 * 3_600), forKey: BackgroundCheckSettings.lastAttemptKey)
        let service = BackgroundCheckService(defaults: defaults, now: { now }, isBusy: { false }, isOnboarded: { true }, scan: {
            scans += 1
            fired.fulfill()
        })
        service.start(observeWorkspace: false)
        await fulfillment(of: [fired], timeout: 5)
        service.setEnabled(false)
        XCTAssertEqual(scans, 1)
        XCTAssertNil(service.nextCheckDate)
    }

    func testScheduledScanDoesNotAdvanceSupportReminder() {
        let preferences = SupportPreferences(defaults: defaults)
        let model = AppInventoryViewModel(supportPreferences: preferences)
        model.recordSupportScanCompletion(successful: true, itemCount: 20, trigger: .scheduled)
        XCTAssertEqual(preferences.successfulScanCount, 0)
        XCTAssertFalse(model.isSupportReminderPresented)
    }
}

/// Gates async work without sleeping, making cancellation/reentrancy tests deterministic.
@MainActor
final class BackgroundTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false
    func wait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
