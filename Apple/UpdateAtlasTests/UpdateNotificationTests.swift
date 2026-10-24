import XCTest
import UserNotifications
@testable import UpdateAtlas

@MainActor
final class UpdateNotificationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "notifications.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDefaultOnRequestsPermissionBeforeFirstScanButScanNeverPrompts() async {
        let scanOnlyDelivery = FakeUpdateNotificationDelivery()
        let scanOnlyService = UpdateNotificationService(defaults: defaults, delivery: scanOnlyDelivery)
        await scanOnlyService.processCompletedScan([item()])
        XCTAssertEqual(scanOnlyDelivery.requests, 0)

        let delivery = FakeUpdateNotificationDelivery()
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        XCTAssertTrue(service.isEnabled)
        await service.requestPermissionIfEnabled()
        XCTAssertEqual(delivery.requests, 1)
        XCTAssertEqual(service.permission, .allowed)
        await service.processCompletedScan([item()])
        XCTAssertEqual(delivery.requests, 1)
        await service.requestPermissionIfEnabled()
        XCTAssertEqual(delivery.requests, 1)
    }

    func testExplicitOffPreferenceSurvivesRelaunchAndSkipsPermissionRequest() async {
        defaults.set(false, forKey: UpdateNotificationSettings.enabledKey)
        let delivery = FakeUpdateNotificationDelivery()
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        XCTAssertFalse(service.isEnabled)
        await service.requestPermissionIfEnabled()
        XCTAssertEqual(delivery.requests, 0)
        await service.setEnabled(true)
        XCTAssertEqual(delivery.requests, 1)
        await service.setEnabled(false)
        let relaunched = UpdateNotificationService(defaults: defaults, delivery: delivery)
        XCTAssertFalse(relaunched.isEnabled)
        await relaunched.requestPermissionIfEnabled()
        XCTAssertEqual(delivery.requests, 1)
    }

    func testOneDigestIncludesChildrenDeduplicatesVersionsAcrossRelaunchAndRollback() async {
        let delivery = FakeUpdateNotificationDelivery()
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        await service.setEnabled(true)
        let parent = item(id: "parent")
        let child = item(id: "child", parent: "parent")
        await service.processCompletedScan([parent, child, parent, item(id: "pending", status: .sourcePending)])
        XCTAssertEqual(delivery.posts.count, 1)
        XCTAssertEqual(delivery.posts[0].count, 2)
        await service.processCompletedScan([parent, child])
        let relaunched = UpdateNotificationService(defaults: defaults, delivery: delivery)
        await relaunched.processCompletedScan([parent, child])
        XCTAssertEqual(delivery.posts.count, 1)
        await relaunched.processCompletedScan([item(id: "parent", latest: "3")])
        XCTAssertEqual(delivery.posts.count, 2)
        await relaunched.processCompletedScan([parent])
        XCTAssertEqual(delivery.posts.count, 2)
        let ledger = defaults.dictionary(forKey: UpdateNotificationSettings.notifiedVersionsKey) as! [String: [String]]
        XCTAssertTrue(ledger.keys.allSatisfy { $0.count == 32 && !$0.contains("/") })
        XCTAssertTrue(ledger.values.flatMap { $0 }.allSatisfy { $0.count == 32 })
    }

    func testDeniedPermissionAndFailedDeliveryDoNotConsumeVersion() async {
        let delivery = FakeUpdateNotificationDelivery()
        delivery.status = .denied
        defaults.set(true, forKey: UpdateNotificationSettings.enabledKey)
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        await service.processCompletedScan([item()])
        XCTAssertTrue(delivery.posts.isEmpty)
        XCTAssertEqual(delivery.requests, 0)
        delivery.status = .allowed
        delivery.failPost = true
        await service.processCompletedScan([item()])
        XCTAssertNil(defaults.object(forKey: UpdateNotificationSettings.notifiedVersionsKey))
        XCTAssertNotNil(service.errorMessage)
        delivery.failPost = false
        await service.processCompletedScan([item()])
        XCTAssertNotNil(defaults.object(forKey: UpdateNotificationSettings.notifiedVersionsKey))
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(delivery.posts.count, 2)
    }

    func testDisableDuringPermissionQueryDoesNotPromptOrReenable() async {
        let delivery = FakeUpdateNotificationDelivery()
        let gate = BackgroundTestGate()
        delivery.permissionGate = gate
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        let enable = Task { await service.setEnabled(true) }
        await gate.waitUntilEntered()
        await service.setEnabled(false)
        gate.release()
        await enable.value
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isRequestingPermission)
        XCTAssertEqual(delivery.requests, 0)
    }

    func testCoalescesOverlappingScansAndDisableClearsInFlightDelivery() async {
        let delivery = FakeUpdateNotificationDelivery()
        delivery.status = .allowed
        defaults.set(true, forKey: UpdateNotificationSettings.enabledKey)
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        let gate = BackgroundTestGate()
        delivery.postGate = gate
        let first = Task { await service.processCompletedScan([item()]) }
        await gate.waitUntilEntered()
        await service.processCompletedScan([item(latest: "3")])
        gate.release()
        await first.value
        XCTAssertEqual(delivery.posts.count, 2)
        XCTAssertEqual(delivery.posts.last?.first?.version, "3")
        await service.setEnabled(false)
        XCTAssertGreaterThan(delivery.clears, 0)
        await service.processCompletedScan([item(latest: "4")])
        XCTAssertEqual(delivery.posts.count, 2)
    }

    func testDisableDuringDeliveryDoesNotMarkVersionAsSent() async {
        let delivery = FakeUpdateNotificationDelivery()
        delivery.status = .allowed
        defaults.set(true, forKey: UpdateNotificationSettings.enabledKey)
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        let gate = BackgroundTestGate()
        delivery.postGate = gate
        let first = Task { await service.processCompletedScan([item()]) }
        await gate.waitUntilEntered()
        await service.setEnabled(false)
        gate.release()
        await first.value
        XCTAssertNil(defaults.object(forKey: UpdateNotificationSettings.notifiedVersionsKey))
        XCTAssertGreaterThanOrEqual(delivery.clears, 2)
    }

    func testNotificationClickBuffersUntilWindowRouteIsAttached() {
        let service = UpdateNotificationService(defaults: defaults, delivery: FakeUpdateNotificationDelivery())
        let opaqueID = CLIInventoryQuery.opaqueID("fixture")
        var opens: [[String]] = []
        service.handleOpen([opaqueID])
        XCTAssertTrue(opens.isEmpty)
        service.attach { opens.append($0) }
        XCTAssertEqual(opens, [[opaqueID]])
        service.attach { opens.append($0) }
        XCTAssertEqual(opens.count, 1)
        service.handleOpen([opaqueID])
        XCTAssertEqual(opens.count, 2)
    }

    func testNotificationSelectionUsesOpaqueIdentityAndDoesNotSelectStaleUpdates() {
        let application = item()
        let model = AppInventoryViewModel(initialApplications: [application])
        model.searchText = "unrelated"
        model.revealNotificationItems([CLIInventoryQuery.opaqueID(application.id)])
        XCTAssertEqual(model.selectedApplicationID, application.id)
        XCTAssertTrue(model.searchText.isEmpty)
        model.revealNotificationItems([CLIInventoryQuery.opaqueID("missing")])
        XCTAssertNil(model.selectedApplicationID)
        XCTAssertEqual(model.selectedFilterID, "update.updateAvailable")
    }

    func testDigestExpandsManagedChildInUpdateList() {
        let parent = item(id: "parent")
        let child = item(id: "child", parent: parent.id)
        let model = AppInventoryViewModel(initialApplications: [parent, child])
        model.expandedManagerIDs.removeAll()
        model.revealNotificationItems([])
        XCTAssertTrue(model.expandedManagerIDs.contains(parent.id))
        XCTAssertTrue(model.visibleTableApplicationIDs.contains(child.id))
    }

    func testNativeNotificationContentContainsOnlyOpaqueIDsAndOptionalSound() {
        let candidates = UpdateNotificationLedger(defaults: defaults).pending(in: [item()])
        let silent = SystemUpdateNotificationDelivery.content(for: candidates, sound: false)
        XCTAssertNil(silent.sound)
        XCTAssertEqual(silent.categoryIdentifier, "UPDATE_ATLAS_UPDATES")
        XCTAssertEqual(silent.userInfo["itemIDs"] as? [String], candidates.map(\.id))
        XCTAssertFalse(silent.body.contains("/private/"))
        XCTAssertEqual(silent.title, "fixture")
        XCTAssertTrue(silent.body.contains("2"))
        XCTAssertNotNil(SystemUpdateNotificationDelivery.content(for: candidates, sound: true).sound)
        let digest = SystemUpdateNotificationDelivery.content(for: candidates + candidates, sound: false)
        XCTAssertEqual(digest.userInfo["itemIDs"] as? [String], [])
        XCTAssertTrue(digest.body.contains("fixture → 2"))
    }

    func testLateDeliveryFailureDoesNotRestoreErrorAfterDisabling() async {
        let delivery = FakeUpdateNotificationDelivery()
        delivery.status = .allowed
        delivery.failPost = true
        defaults.set(true, forKey: UpdateNotificationSettings.enabledKey)
        let service = UpdateNotificationService(defaults: defaults, delivery: delivery)
        let gate = BackgroundTestGate()
        delivery.postGate = gate
        let first = Task { await service.processCompletedScan([item()]) }
        await gate.waitUntilEntered()
        await service.setEnabled(false)
        gate.release()
        await first.value
        XCTAssertFalse(service.isEnabled)
        XCTAssertNil(service.errorMessage)
        XCTAssertNil(defaults.object(forKey: UpdateNotificationSettings.notifiedVersionsKey))
    }

    private func item(id: String = "fixture", latest: String = "2", parent: String? = nil,
                      status: UpdateAvailability = .updateAvailable) -> InstalledApplication {
        InstalledApplication(inventoryID: "/private/fixture/" + id, path: "/private/fixture.app", name: id,
            bundleIdentifier: "test." + id, displayVersion: "1", buildVersion: "1", teamIdentifier: nil,
            status: .supported, mechanism: .sparkle, mechanismName: "Sparkle", confidence: .verified,
            evidence: [], parentInventoryID: parent, parentManagerBundleIdentifier: nil,
            parentManagerName: nil, vendorURL: nil, catalogEntryID: nil, notes: "", kind: .application,
            packageProvenance: nil, updateCheck: UpdateCheckResult(availability: status, installedVersion: "1",
                latestVersion: latest, checkedAt: nil, source: .sparkleAppcast, detail: ""))
    }
}

@MainActor
private final class FakeUpdateNotificationDelivery: UpdateNotificationDelivering {
    var status = NotificationPermission.notRequested
    var permissionReads = 0
    var requests = 0
    var clears = 0
    var posts: [[UpdateNotificationCandidate]] = []
    var failPost = false
    var permissionGate: BackgroundTestGate?
    var postGate: BackgroundTestGate?
    func permission() async -> NotificationPermission {
        permissionReads += 1
        if let permissionGate { await permissionGate.wait() }
        return status
    }
    func requestPermission() async throws -> Bool { requests += 1; status = .allowed; return true }
    func post(_ candidates: [UpdateNotificationCandidate], sound: Bool) async throws {
        posts.append(candidates)
        if let postGate { await postGate.wait() }
        if failPost { throw NSError(domain: "test", code: 1) }
    }
    func clear() { clears += 1 }
}
