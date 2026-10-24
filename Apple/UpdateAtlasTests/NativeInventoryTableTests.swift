import AppKit
import SwiftUI
import XCTest
@testable import UpdateAtlas

final class NativeInventoryTableTests: XCTestCase {
    @MainActor
    private func preservingPreferences(_ body: () -> Void) {
        let keys = [InventoryColumn.defaultsKey, InventoryColumn.widthDefaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        body()
    }

    @MainActor
    private func model(_ applications: [InstalledApplication] = []) -> AppInventoryViewModel {
        let model = AppInventoryViewModel(initialApplications: applications)
        model.selectedFilterID = InventoryScope.allInOne.id
        model.visibleColumns = InventoryColumn.defaults
        model.columnWidths = Dictionary(uniqueKeysWithValues: InventoryColumn.allCases.map { ($0, $0.defaultWidth) })
        return model
    }

    @MainActor
    func testHeaderAndColumnsUseNativeResizeAndVisibilityAffordances() {
        preservingPreferences {
            let coordinator = NativeInventoryTable.Coordinator(viewModel: model())
            let scroll = coordinator.makeScrollView()
            let table = scroll.documentView as! NSTableView
            XCTAssertNotNil(table.headerView)
            XCTAssertGreaterThan(table.headerView!.frame.height, 0)
            XCTAssertTrue(table.allowsColumnResizing)
            XCTAssertEqual(table.columnAutoresizingStyle, .uniformColumnAutoresizingStyle)
            XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
            XCTAssertTrue(scroll.hasHorizontalScroller)
            for column in table.tableColumns {
                let kind = InventoryColumn(rawValue: column.identifier.rawValue)!
                XCTAssertTrue(column.resizingMask.contains(.userResizingMask))
                XCTAssertTrue(column.resizingMask.contains(.autoresizingMask))
                XCTAssertEqual(column.minWidth, kind.minimumWidth)
                XCTAssertEqual(coordinator.tableView(table, userCanChangeVisibilityOf: column), !kind.isRequired)
            }
        }
    }

    @MainActor
    func testUserWidthPersistsButAutomaticResizeDoesNotReplaceItsPreference() {
        preservingPreferences {
            let model = model()
            let coordinator = NativeInventoryTable.Coordinator(viewModel: model)
            let scroll = coordinator.makeScrollView()
            let table = scroll.documentView as! NSTableView
            let column = table.tableColumns.first { $0.identifier.rawValue == InventoryColumn.installedVersion.rawValue }!
            let savedWidth = model.width(for: .installedVersion)
            column.width = 235
            coordinator.tableViewColumnDidResize(Notification(name: NSTableView.columnDidResizeNotification,
                                                              object: table, userInfo: ["NSTableColumn": column]))
            XCTAssertEqual(model.width(for: .installedVersion), savedWidth)
            coordinator.recordUserColumnWidth(column, kind: .installedVersion)
            coordinator.update(from: model)
            XCTAssertEqual(column.width, 235, accuracy: 0.1)
            XCTAssertEqual(model.width(for: .installedVersion), 235, accuracy: 0.1)
            let restored = AppInventoryViewModel()
            XCTAssertEqual(restored.width(for: .installedVersion), 235, accuracy: 0.1)
        }
    }

    @MainActor
    func testRowDensityFollowsAvailableDetailWidth() {
        preservingPreferences {
            let model = model([application("one")])
            let coordinator = NativeInventoryTable.Coordinator(viewModel: model, availableWidth: 900)
            let scroll = coordinator.makeScrollView()
            let table = scroll.documentView as! NSTableView
            XCTAssertEqual(InventoryTableLayout(availableWidth: 900).rowHeight, 46)
            XCTAssertFalse(InventoryTableLayout(availableWidth: 900).isSpacious)
            coordinator.update(from: model, availableWidth: 1_600)
            XCTAssertEqual(table.rowHeight, 64)
            XCTAssertTrue(InventoryTableLayout(availableWidth: 1_600).isSpacious)
            coordinator.update(from: model, availableWidth: 900)
            XCTAssertEqual(table.rowHeight, 46)
        }
    }

    @MainActor
    func testInspectorOverlayKeepsInventoryTableWidth() {
        preservingPreferences {
            let app = application("one")
            let model = model([app])
            model.selectedApplicationID = app.id

            @MainActor func tableWidth(inspectorPresented: Bool) -> CGFloat? {
                model.isInspectorPresented = inspectorPresented
                let host = NSHostingView(rootView: ApplicationListView(viewModel: model))
                host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
                host.layoutSubtreeIfNeeded()

                func inventoryScroll(in view: NSView) -> NSScrollView? {
                    if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
                        return scroll
                    }
                    return view.subviews.lazy.compactMap(inventoryScroll).first
                }
                return inventoryScroll(in: host)?.frame.width
            }

            let withoutInspector = tableWidth(inspectorPresented: false)
            let withInspector = tableWidth(inspectorPresented: true)
            XCTAssertNotNil(withoutInspector)
            XCTAssertNotNil(withInspector)
            XCTAssertGreaterThan(withoutInspector ?? 0, 900)
            XCTAssertEqual(withInspector ?? 0, withoutInspector ?? -1, accuracy: 1)
        }
    }

    @MainActor
    func testNativeSortDescriptorsUseNumericInventoryOrdering() {
        preservingPreferences {
            let nine = application("nine", version: "2.0.9")
            let ten = application("ten", version: "2.0.10")
            let model = model([ten, nine])
            let coordinator = NativeInventoryTable.Coordinator(viewModel: model)
            let scroll = coordinator.makeScrollView()
            let table = scroll.documentView as! NSTableView
            table.sortDescriptors = [NSSortDescriptor(key: InventoryColumn.installedVersion.rawValue, ascending: true)]
            coordinator.tableView(table, sortDescriptorsDidChange: [])
            coordinator.update(from: model)
            XCTAssertEqual(coordinator.rows.compactMap { $0.application?.id }, [nine.id, ten.id])
            table.sortDescriptors = [NSSortDescriptor(key: InventoryColumn.installedVersion.rawValue, ascending: false)]
            coordinator.tableView(table, sortDescriptorsDidChange: [])
            coordinator.update(from: model)
            XCTAssertEqual(coordinator.rows.compactMap { $0.application?.id }, [ten.id, nine.id])
        }
    }

    @MainActor
    func testFlatInventoryRowsRemainSelectableAndNilSelectionStaysEmpty() {
        preservingPreferences {
            let app = application("app")
            let model = model([app])
            let coordinator = NativeInventoryTable.Coordinator(viewModel: model)
            let scroll = coordinator.makeScrollView()
            let table = scroll.documentView as! NSTableView
            XCTAssertEqual(coordinator.rows.count, 1)
            XCTAssertTrue(coordinator.tableView(table, shouldSelectRow: 0))
            XCTAssertEqual(table.selectedRow, -1)
            model.selectedApplicationID = app.id
            coordinator.update(from: model)
            XCTAssertEqual(table.selectedRow, 0)
            model.clearSelection()
            coordinator.update(from: model)
            XCTAssertEqual(table.selectedRow, -1)
        }
    }

    @MainActor
    func testFilteringFlatRowsKeepsKeyboardNavigationInSync() {
        preservingPreferences {
            let app = application("app")
            let model = model([app])
            XCTAssertEqual(model.visibleTableApplicationIDs, [app.id])
            model.selectedApplicationID = app.id
            model.selectedFilterID = "update.updateAvailable"
            model.clearSelectionIfHidden()
            XCTAssertNil(model.selectedApplicationID)
            XCTAssertTrue(model.visibleTableApplicationIDs.isEmpty)
            XCTAssertTrue(NativeInventoryRow.snapshot(from: model).isEmpty)
            XCTAssertEqual(model.applications.count, 1)
            model.selectAdjacent(offset: 1)
            XCTAssertNil(model.selectedApplicationID)
            model.selectedFilterID = InventoryScope.allInOne.id
            model.selectAdjacent(offset: 1)
            XCTAssertEqual(model.selectedApplicationID, app.id)
        }
    }

    @MainActor
    func testNativeSelectionAndColumnVisibilityStayInSyncWithModel() {
        preservingPreferences {
            let app = application("app")
            let model = model([app])
            let coordinator = NativeInventoryTable.Coordinator(viewModel: model)
            let scroll = coordinator.makeScrollView()
            let table = scroll.documentView as! NSTableView
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            XCTAssertEqual(model.selectedApplicationID, app.id)
            let column = table.tableColumns.first { $0.identifier.rawValue == InventoryColumn.updateMechanism.rawValue }!
            column.isHidden = true
            coordinator.tableView(table, userDidChangeVisibilityOf: [column])
            coordinator.update(from: model)
            XCTAssertFalse(model.visibleColumns.contains(.updateMechanism))
            XCTAssertTrue(column.isHidden)
            XCTAssertFalse(AppInventoryViewModel().visibleColumns.contains(.updateMechanism))
            model.toggleColumn(.updateMechanism)
            coordinator.update(from: model)
            XCTAssertFalse(column.isHidden)
        }
    }

    @MainActor
    func testColumnWidthCannotBeBelowMinimumOrNonfinite() {
        preservingPreferences {
            let model = model()
            model.setColumnWidth(10, for: .name)
            XCTAssertEqual(model.width(for: .name), InventoryColumn.name.minimumWidth)
            model.setColumnWidth(.nan, for: .name)
            model.setColumnWidth(.infinity, for: .name)
            XCTAssertEqual(model.width(for: .name), InventoryColumn.name.minimumWidth)
        }
    }

    private func application(_ id: String, version: String = "1.0") -> InstalledApplication {
        InstalledApplication(
            inventoryID: id, path: "/Applications/" + id + ".app", name: id,
            bundleIdentifier: "test." + id, displayVersion: version, buildVersion: "1",
            teamIdentifier: nil, status: .needsCatalog, mechanism: .unknown,
            mechanismName: "Unknown", confidence: .low, evidence: [],
            parentManagerBundleIdentifier: nil, parentManagerName: nil, vendorURL: nil,
            catalogEntryID: nil, notes: "", kind: .application, packageProvenance: nil
        )
    }
}
