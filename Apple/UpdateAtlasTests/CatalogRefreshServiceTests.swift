import XCTest
@testable import UpdateAtlas

@MainActor
final class CatalogRefreshServiceTests: XCTestCase {
    func testChecksEverySixHoursWithoutTheFullScanSetting() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var requests = 0
        let service = CatalogRefreshService(usesTimers: false, now: { now },
            isEligible: { true }, isBusy: { false }, refreshCatalog: { requests += 1; return true })
        service.start(observeWorkspace: false)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(CatalogRefreshService.interval))
        await service.checkIfDue()
        XCTAssertEqual(requests, 0)

        now.addTimeInterval(CatalogRefreshService.interval)
        await service.checkIfDue()
        await service.checkIfDue()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(CatalogRefreshService.interval))
    }

    func testLaunchRefreshResetsScheduleAndFailureGetsBoundedRetry() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var requests = 0
        let service = CatalogRefreshService(usesTimers: false, now: { now },
            isEligible: { true }, isBusy: { false }, refreshCatalog: { requests += 1; return false })
        service.start(observeWorkspace: false)
        now.addTimeInterval(300)
        service.recordRefresh(success: true)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(CatalogRefreshService.interval))
        now.addTimeInterval(CatalogRefreshService.interval)
        await service.checkIfDue()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(service.nextCheckDate, now.addingTimeInterval(CatalogRefreshService.retryInterval))
    }

    func testIneligibleBusyAndSleepingStatesNeverStartARequest() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var eligible = false
        var busy = false
        var requests = 0
        let service = CatalogRefreshService(usesTimers: false, now: { now },
            isEligible: { eligible }, isBusy: { busy }, refreshCatalog: { requests += 1; return true })
        service.start(observeWorkspace: false)
        now.addTimeInterval(CatalogRefreshService.interval)
        await service.checkIfDue()
        eligible = true
        busy = true
        service.refresh()
        await service.checkIfDue()
        service.systemWillSleep()
        busy = false
        await service.checkIfDue()
        XCTAssertEqual(requests, 0)
        service.systemDidWake()
        await service.checkIfDue()
        XCTAssertEqual(requests, 1)
    }
}
