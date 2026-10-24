import XCTest
@testable import UpdateAtlas

final class ScanReliabilityTests: XCTestCase {
    func testCommandOutputAndExitStatusArePreserved() throws {
        let result = try PackageCommandRunner.run(executable: "/bin/sh", arguments: ["-c", "printf '{\"ok\":true}'; exit 1"], control: ScanControl())
        XCTAssertEqual(String(data: result.output, encoding: .utf8), "{\"ok\":true}")
        XCTAssertEqual(result.terminationStatus, 1)
    }

    func testInstallRunnerStreamsStderrAndOverridesOnlyRequestedEnvironment() throws {
        let result = try PackageCommandRunner.run(executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$UA_MANAGER_FIXTURE\"; printf 'stderr' >&2"], control: ScanControl(),
            environmentOverrides: ["UA_MANAGER_FIXTURE": "override"], mergeStandardError: true)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "overridestderr")
        XCTAssertEqual(result.terminationStatus, 0)
    }

    private func assertFailure(_ reason: ScanDiagnostic.Reason, control: ScanControl = ScanControl(),
                               script: String, timeout: TimeInterval = 0.15, limit: Int = 4096) {
        let started = ContinuousClock.now
        XCTAssertThrowsError(try PackageCommandRunner.run(executable: "/bin/sh", arguments: ["-c", script],
                                                          timeout: timeout, control: control, maximumOutputBytes: limit)) { error in
            guard case PackageCommandError.failed(let actual) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(actual, reason)
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }

    func testTimeoutKillsCommandIgnoringSIGTERM() {
        assertFailure(.timedOut, script: "trap '' TERM; while :; do sleep 1; done")
    }
    func testChildHoldingPipeCannotHangScanAfterParentExits() {
        assertFailure(.timedOut, script: "sleep 10 & exit 0")
    }
    func testOutputLimitStopsAnUnboundedProducer() {
        assertFailure(.outputTooLarge, script: "while :; do printf '0123456789'; done", timeout: 1, limit: 128)
    }
    func testCancellationInterruptsAnActiveCommand() {
        let control = ScanControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { control.cancel() }
        assertFailure(.cancelled, control: control, script: "trap '' TERM; sleep 10", timeout: 5)
    }
    func testExpiredOverallBudgetDoesNotLaunchACommand() {
        assertFailure(.timedOut, control: ScanControl(timeout: 0), script: "exit 0")
    }
    func testInvalidExecutableIsAnExplicitFailure() {
        XCTAssertThrowsError(try PackageCommandRunner.run(executable: "/does-not-exist/update-atlas-fixture", arguments: [], control: ScanControl())) { error in
            guard case PackageCommandError.failed(.unavailable) = error else { return XCTFail("Expected unavailable") }
        }
    }
    func testEmptyInventoriesAreDistinctFromMalformedSchemas() {
        XCTAssertTrue(PackageInventoryScanner.validJSON(Data("{\"formulae\":[],\"casks\":[]}".utf8), arguments: ["--json=v2"]))
        XCTAssertFalse(PackageInventoryScanner.validJSON(Data("{}".utf8), arguments: ["--json=v2"]))
        XCTAssertFalse(PackageInventoryScanner.validJSON(Data("not json".utf8), arguments: ["--json"]))
        XCTAssertTrue(PackageInventoryScanner.validJSON(Data("[]".utf8), arguments: ["--format=json"]))
        XCTAssertFalse(PackageInventoryScanner.validJSON(Data("[{}]".utf8), arguments: ["--format=json"]))
        XCTAssertTrue(PackageInventoryScanner.validToolListing("", cargo: true))
        XCTAssertFalse(PackageInventoryScanner.validToolListing("unexpected output", cargo: true))
    }
    func testCoverageCountsCanonicalItemsAndDoesNotCallManagersVerified() {
        let verified = item("verified", .upToDate)
        let updated = item("updated", .updateAvailable)
        let failed = item("failed", .checkFailed)
        let pending = item("pending", .sourcePending)
        let managed = item("managed", .managedExternally)
        let summary = InventoryCoverageSummary([verified, updated, failed, pending, managed, verified])
        XCTAssertEqual(summary.inventoryItemCount, 5)
        XCTAssertEqual(summary.verifiedItemCount, 2)
        XCTAssertEqual(summary.unverifiedItemCount, 3)
        XCTAssertEqual(summary.failedItemCount, 1)
        XCTAssertEqual(summary.managerOwnedItemCount, 1)
    }

    private func item(_ id: String, _ availability: UpdateAvailability) -> InstalledApplication {
        var value = InstalledApplication(inventoryID: id, path: "/fixture/" + id, name: id, bundleIdentifier: "fixture." + id,
            displayVersion: "1.0", buildVersion: "1", teamIdentifier: nil, status: .needsCatalog,
            mechanism: .unknown, mechanismName: "Unknown", confidence: .low, evidence: [],
            parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
            catalogEntryID: nil, notes: "", kind: .application, packageProvenance: nil)
        value.updateCheck = UpdateCheckResult(availability: availability, installedVersion: "1.0", latestVersion: nil,
                                              checkedAt: nil, source: nil, detail: "fixture")
        return value
    }
}
