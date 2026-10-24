import Foundation
import XCTest
@testable import UpdateAtlas

final class CLIInventoryQueryTests: XCTestCase {
    func testFiltersIntersectWithoutChangingCanonicalInventoryOrSummary() throws {
        let owner = item("owner")
        let game = item("game", parentID: owner.id, kind: .game, status: .updateAvailable)
        let mod = item("mod", parentID: game.id, kind: .mod, status: .sourcePending)
        let other = item("other", status: .updateAvailable)
        let failed = item("failed", status: .checkFailed)
        let inventory = [owner, game, mod, other, failed]
        let query = try CLIInventoryQuery(arguments: ["check", "--manager", CLIInventoryQuery.opaqueID(owner.id),
                                                     "--updates-only", "--kind", "game"])
        let selected = try query.selectedItems(in: inventory)
        XCTAssertEqual(selected.map(\.id), [game.id])
        XCTAssertEqual(inventory.count, 5)
        let summary = CLIInventorySummary(inventory: inventory, returned: selected)
        XCTAssertEqual(summary.inventoryItemCount, 5)
        XCTAssertEqual(summary.returnedItemCount, 1)
        XCTAssertEqual(summary.availableUpdateCount, 2)
        XCTAssertEqual(summary.returnedUpdateCount, 1)
        XCTAssertEqual(summary.sourcePendingCount, 1)
        XCTAssertEqual(summary.checkFailedCount, 1)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as! [String: Int]
        XCTAssertEqual(encoded, ["inventoryItemCount": 5, "returnedItemCount": 1, "availableUpdateCount": 2,
                                 "returnedUpdateCount": 1, "sourcePendingCount": 1, "checkFailedCount": 1])
    }

    func testChildrenOnlyTraversesGrandchildrenAndLegacyBundleOwnership() throws {
        let owner = item("owner")
        let child = item("child", parentBundle: owner.bundleIdentifier)
        let grandchild = item("grandchild", parentID: child.id)
        let other = item("other")
        let query = try CLIInventoryQuery(arguments: ["scan", "--children-of", CLIInventoryQuery.opaqueID(owner.id)])
        XCTAssertEqual(try query.selectedItems(in: [owner, child, grandchild, other]).map(\.id), [child.id, grandchild.id])
    }

    func testOwnerSelectionIncludesOwnerAndTerminatesOnCycle() throws {
        let owner = item("owner", parentID: "child")
        let child = item("child", parentID: owner.id)
        let query = try CLIInventoryQuery(arguments: ["scan", "--manager", CLIInventoryQuery.opaqueID(owner.id)])
        XCTAssertEqual(try query.selectedItems(in: [owner, child]).map(\.id), [child.id, owner.id])
    }

    func testExplicitParentIdentityWinsOverOtherMatchingBundle() throws {
        let first = item("first")
        let second = item("second")
        let child = item("child", parentID: first.id, parentBundle: second.bundleIdentifier)
        let query = try CLIInventoryQuery(arguments: ["scan", "--children-of", CLIInventoryQuery.opaqueID(second.id)])
        XCTAssertTrue(try query.selectedItems(in: [first, second, child]).isEmpty)
    }

    func testUnknownOwnerFailsInsteadOfReturningAnApparentlyEmptyInventory() throws {
        let query = try CLIInventoryQuery(arguments: ["scan", "--manager", CLIInventoryQuery.opaqueID("missing")])
        XCTAssertThrowsError(try query.selectedItems(in: [item("real")])) {
            XCTAssertEqual($0 as? CLIInventoryQuery.QueryError, .unknownOwner)
        }
    }

    func testRejectsUnknownDuplicateMissingAndAmbiguousArguments() {
        let id = CLIInventoryQuery.opaqueID("owner")
        let invalid = [[], ["unknown"], ["scan", "--unknown"], ["scan", "--kind"],
                       ["scan", "--kind", "not-a-kind"], ["scan", "--include-system", "--include-system"],
                       ["scan", "--updates-only", "--updates-only"], ["scan", "--manager", "/private/path"],
                       ["scan", "--manager", id, "--children-of", id], ["scan", "--manager", id.uppercased()],
                       ["scan", "--kind", "game", "--kind", "package"]]
        for arguments in invalid {
            XCTAssertThrowsError(try CLIInventoryQuery(arguments: arguments), arguments.joined(separator: " "))
        }
    }

    func testUnfilteredOutputKeepsDeterministicOrderAndExistingFlags() throws {
        let query = try CLIInventoryQuery(arguments: ["scan", "--include-paths", "--include-system"])
        XCTAssertEqual(query.command, .scan)
        XCTAssertTrue(query.includeSystem)
        XCTAssertTrue(query.includePaths)
        XCTAssertEqual(try query.selectedItems(in: [item("z"), item("a")]).map(\.id), ["a", "z"])
    }

    func testCheckProgressCountsEveryCompletedItemWithoutInventingVerifiedResults() async throws {
        let pipe = Pipe()
        let inventory = [item("pending-a"), item("pending-b"), item("pending-c")]
        let checked = await UpdateCheckService().check(inventory, progress: { done, total in
            pipe.fileHandleForWriting.write(Data("\(done)/\(total)\n".utf8))
        })
        try pipe.fileHandleForWriting.close()
        let updates = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(updates, "0/3\n1/3\n2/3\n3/3\n")
        XCTAssertEqual(checked.map(\.id), inventory.map(\.id))
        XCTAssertTrue(checked.allSatisfy { $0.updateCheck.availability == .sourcePending })
    }

    private func item(_ id: String, parentID: String? = nil, parentBundle: String? = nil,
                      kind: InventoryItemKind = .application, status: UpdateAvailability = .notChecked) -> InstalledApplication {
        InstalledApplication(
            inventoryID: id, path: "/private/software/" + id, name: id, bundleIdentifier: "test." + id,
            displayVersion: "1.0", buildVersion: "1", teamIdentifier: nil, status: .needsCatalog,
            mechanism: .unknown, mechanismName: "Unknown", confidence: .low, evidence: [],
            parentInventoryID: parentID, parentManagerBundleIdentifier: parentBundle,
            parentManagerName: nil, vendorURL: nil, catalogEntryID: nil, notes: "", kind: kind,
            packageProvenance: nil, updateCheck: UpdateCheckResult(
                availability: status, installedVersion: "1.0", latestVersion: nil, checkedAt: nil,
                source: nil, detail: ""
            )
        )
    }
}
