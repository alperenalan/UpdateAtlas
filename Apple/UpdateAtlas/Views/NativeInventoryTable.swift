import AppKit
import SwiftUI

// AppKit owns header tracking, resizing cursors, scrolling, sort indicators and selection.
// SwiftUI only supplies the cell content and shares the existing inventory model.
struct NativeInventoryTable: NSViewRepresentable {
    @ObservedObject var viewModel: AppInventoryViewModel
    let availableWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel, availableWidth: availableWidth) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: viewModel, availableWidth: availableWidth)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, @preconcurrency NSTableViewDelegate {
        private(set) var viewModel: AppInventoryViewModel
        private(set) var rows: [NativeInventoryRow] = []
        private(set) weak var tableView: NSTableView?
        private var isUpdating = false
        private var lastSelection: String?
        private var appliedPreferenceWidths: [InventoryColumn: CGFloat] = [:]
        private var layout: InventoryTableLayout

        init(viewModel: AppInventoryViewModel, availableWidth: CGFloat = 900) {
            self.viewModel = viewModel
            layout = InventoryTableLayout(availableWidth: availableWidth)
        }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder

            let table = NSTableView()
            table.style = .inset
            // Keep AppKit's default header, including its system-defined height.
            table.allowsColumnResizing = true
            table.allowsColumnReordering = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = true
            // AppKit continues alternating stripes below the last real row in a tall window.
            table.usesAlternatingRowBackgroundColors = false
            table.floatsGroupRows = false
            table.rowSizeStyle = .custom
            table.rowHeight = layout.rowHeight
            table.intercellSpacing = NSSize(width: 6, height: 0)
            table.autoresizingMask = [.width]
            table.setAccessibilityLabel(String(localized: "Software inventory", bundle: AppL10n.bundle, locale: AppL10n.locale))

            // Keep all columns alive so hidden columns retain their width. AppKit's native
            // header context menu is available from macOS 14; required columns stay visible.
            for column in InventoryColumn.allCases {
                let native = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
                native.title = column.title
                native.minWidth = column.minimumWidth
                native.width = viewModel.width(for: column)
                native.resizingMask = [.userResizingMask, .autoresizingMask]
                appliedPreferenceWidths[column] = native.width
                native.isEditable = false
                native.isHidden = !viewModel.visibleColumns.contains(column)
                native.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
                table.addTableColumn(native)
            }
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.action = #selector(rowClicked(_:))
            scroll.documentView = table
            tableView = table
            update(from: viewModel, availableWidth: layout.availableWidth)
            return scroll
        }

        func update(from model: AppInventoryViewModel, availableWidth: CGFloat? = nil) {
            guard let table = tableView else { return }
            viewModel = model
            isUpdating = true
            defer { isUpdating = false }
            let nextLayout = InventoryTableLayout(availableWidth: availableWidth ?? layout.availableWidth)
            let densityChanged = nextLayout.isSpacious != layout.isSpacious
            let heightChanged = nextLayout.rowHeight != layout.rowHeight
            layout = nextLayout
            if heightChanged { table.rowHeight = layout.rowHeight }

            for column in table.tableColumns {
                guard let kind = InventoryColumn(rawValue: column.identifier.rawValue) else { continue }
                if column.title != kind.title { column.title = kind.title }
                let hidden = !model.visibleColumns.contains(kind)
                if column.isHidden != hidden { column.isHidden = hidden }
                // Window autoresizing changes displayed widths, not the saved user preference.
                // Only apply an externally changed preference; never undo a live drag.
                let width = model.width(for: kind)
                if appliedPreferenceWidths[kind] != width {
                    if table.headerView?.resizedColumn == -1 || table.headerView == nil {
                        column.width = width
                        appliedPreferenceWidths[kind] = width
                    }
                }
            }
            if table.sortDescriptors.first?.key != model.sortColumn.rawValue
                || table.sortDescriptors.first?.ascending != model.sortAscending {
                table.sortDescriptors = [NSSortDescriptor(key: model.sortColumn.rawValue, ascending: model.sortAscending)]
            }

            let nextRows = NativeInventoryRow.snapshot(from: model)
            let dataChanged = nextRows != rows
            if dataChanged || densityChanged {
                rows = nextRows
                table.reloadData()
            } else if heightChanged, !rows.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
            }
            let selectedRow = model.selectedApplicationID.flatMap { id in
                rows.firstIndex { $0.application?.id == id }
            }
            let selection = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            if table.selectedRowIndexes != selection {
                table.selectRowIndexes(selection, byExtendingSelection: false)
            }
            if let selectedRow, lastSelection != model.selectedApplicationID {
                table.scrollRowToVisible(selectedRow)
            }
            lastSelection = model.selectedApplicationID
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row), let app = rows[row].application else { return layout.rowHeight }
            return app.updateCheck.availability == .updateAvailable ? layout.rowHeight + 4 : layout.rowHeight
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let kind = tableColumn.flatMap { InventoryColumn(rawValue: $0.identifier.rawValue) } ?? .name
            let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("inventory-section")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? InventoryHostingCell
                ?? InventoryHostingCell()
            cell.identifier = identifier
            cell.configure(AnyView(InventoryTableCell(row: rows[row], column: kind,
                                                       isSpacious: layout.isSpacious, viewModel: viewModel)))
            return cell
        }

        // Clicking the already selected row brings back an inspector the user had hidden.
        @objc func rowClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row), rows[row].application?.id == viewModel.selectedApplicationID,
                  viewModel.selectedApplicationID != nil else { return }
            viewModel.isInspectorPresented = true
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table = tableView else { return }
            let row = table.selectedRow
            viewModel.selectedApplicationID = rows.indices.contains(row) ? rows[row].application?.id : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let column = InventoryColumn(rawValue: key) else { return }
            viewModel.sortColumn = column
            viewModel.sortAscending = descriptor.ascending
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard !isUpdating,
                  let native = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let column = InventoryColumn(rawValue: native.identifier.rawValue),
                  let table = tableView, let header = table.headerView else { return }
            // AppKit also sends resize notifications when the window resizes. Persist only
            // a header drag, so a temporary full-screen size does not become a preference.
            guard header.resizedColumn >= 0,
                  header.resizedColumn == table.column(withIdentifier: native.identifier) else { return }
            recordUserColumnWidth(native, kind: column)
        }

        func recordUserColumnWidth(_ native: NSTableColumn, kind: InventoryColumn) {
            appliedPreferenceWidths[kind] = native.width
            viewModel.setColumnWidth(native.width, for: kind)
        }

        func tableView(_ tableView: NSTableView, userCanChangeVisibilityOf column: NSTableColumn) -> Bool {
            guard let kind = InventoryColumn(rawValue: column.identifier.rawValue) else { return false }
            return !kind.isRequired
        }

        func tableView(_ tableView: NSTableView, userDidChangeVisibilityOf columns: [NSTableColumn]) {
            guard !isUpdating else { return }
            for column in columns {
                guard let kind = InventoryColumn(rawValue: column.identifier.rawValue) else { continue }
                if viewModel.visibleColumns.contains(kind) == column.isHidden { viewModel.toggleColumn(kind) }
            }
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column),
                  let kind = InventoryColumn(rawValue: tableView.tableColumns[column].identifier.rawValue) else { return 120 }
            // Bounded native double-click fitting, without executing software or measuring
            // every hosted cell. Keep enough room for icons and ownership indentation.
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            var width = (kind.title as NSString).size(withAttributes: [.font: font]).width + 30
            for row in rows.prefix(500) {
                guard let app = row.application else { continue }
                let value: String
                switch kind {
                case .name: value = app.name
                case .installedVersion: value = app.versionLabel
                case .type: value = app.kind.title
                case .parent: value = app.parentManagerName ?? "—"
                case .updateMechanism: value = app.mechanismName
                case .mechanismStatus: value = app.status.title
                case .openSource:
                    value = app.isOpenSource.map { $0 ? String(localized: "Yes", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "No", bundle: AppL10n.bundle, locale: AppL10n.locale) }
                        ?? String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale)
                case .updateStatus: value = app.updateCheck.availability.title
                }
                let inlineButtonWidth: CGFloat
                if ManagerUpdatePolicy.offersInlineUpdate(for: app)
                    || ManagerUpdatePolicy.offersInlineAppStore(for: app) {
                    inlineButtonWidth = 105
                } else if let action = viewModel.inlineOpenAction(for: app) {
                    inlineButtonWidth = action == .openReleasePage ? 210 : 150
                } else {
                    inlineButtonWidth = 0
                }
                let padding: CGFloat = kind == .name
                    ? 80 + inlineButtonWidth + CGFloat(viewModel.hierarchyDepth(of: app)) * 15 : 32
                width = max(width, (value as NSString).size(withAttributes: [.font: font]).width + padding)
            }
            return min(600, max(kind.minimumWidth, width))
        }
    }
}

struct InventoryTableLayout {
    let availableWidth: CGFloat

    init(availableWidth: CGFloat) { self.availableWidth = max(0, availableWidth) }

    var isSpacious: Bool { availableWidth >= 1_200 }
    var rowHeight: CGFloat { min(64, max(46, 46 + (availableWidth - 900) / 35)) }
}

@MainActor
private final class InventoryHostingCell: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?
    private var content: AnyView = AnyView(EmptyView())

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateContent() }
    }

    func configure(_ content: AnyView) {
        self.content = content
        if hostingView == nil {
            let host = NSHostingView(rootView: content)
            host.translatesAutoresizingMaskIntoConstraints = false
            // AppKit owns cell/row dimensions, not the SwiftUI content's ideal width.
            host.sizingOptions = []
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            hostingView = host
        }
        updateContent()
    }

    private func updateContent() {
        let color = backgroundStyle == .emphasized
            ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary
        hostingView?.rootView = AnyView(content.foregroundStyle(color))
    }
}
