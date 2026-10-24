import SwiftUI

struct ApplicationListView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @FocusState private var isSearchFocused: Bool
    @Environment(\.locale) private var locale
    @State private var isRemnantsPresented = false

    var body: some View {
        GeometryReader { geometry in
            let isSpacious = geometry.size.width >= 1_200
            VStack(spacing: 0) {
                header(isSpacious: isSpacious)
                Divider()
                ZStack {
                    NativeInventoryTable(viewModel: viewModel, availableWidth: geometry.size.width)
                    if viewModel.visibleApplications.isEmpty && !viewModel.isScanning {
                        if viewModel.lastScanDate == nil {
                            notScannedState
                        } else {
                            emptyState.allowsHitTesting(false)
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if viewModel.isInspectorPresented, viewModel.selectedApplication != nil {
                        InspectorView(viewModel: viewModel)
                            .frame(width: min(380, max(280, geometry.size.width * 0.26)))
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor))
                                    .frame(width: 1)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 12, x: -4)
                    }
                }

                if let warning = viewModel.scanError {
                    Divider()
                    Label(warning, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.quaternary.opacity(0.35))
                } else if let source = viewModel.catalogSnapshot?.source {
                    Divider()
                    Label(
                        String(localized: "Catalog source:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " " + source.title,
                        systemImage: "books.vertical"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
                if !viewModel.scanDiagnostics.isEmpty {
                    DisclosureGroup("Scan issues") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(viewModel.scanDiagnostics.enumerated()), id: \.offset) { _, issue in
                                    Text(issue.message).font(.caption).textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: isSearchFocused) { _, focused in
                viewModel.isSearchFieldFocused = focused
            }
        }
    }

    private func header(isSpacious: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                headerCopy(isSpacious: isSpacious).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 10)
                headerActions(isSpacious: isSpacious)
            }
            VStack(alignment: .leading, spacing: 8) {
                headerCopy(isSpacious: isSpacious)
                headerActions(isSpacious: isSpacious).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isSpacious ? 22 : 14)
        .padding(.vertical, isSpacious ? 15 : 9)
    }

    private func headerCopy(isSpacious: Bool) -> some View {
        VStack(alignment: .leading, spacing: isSpacious ? 4 : 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(viewModel.selectedFilterTitle)
                    .font(.system(size: isSpacious ? 23 : 19, weight: .bold))
                #if DEBUG
                DebugBuildBadge()
                #endif
            }
            Text(viewModel.selectedFilterDescription)
                .font(isSpacious ? .body : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(String(format: String(localized: "%d inventoried · %d verified · %d unverified", bundle: AppL10n.bundle, locale: AppL10n.locale),
                            viewModel.coverageSummary.inventoryItemCount,
                            viewModel.coverageSummary.verifiedItemCount,
                            viewModel.coverageSummary.unverifiedItemCount))
                    .help("Verified means the latest version was confirmed. Unverified includes checks that are pending, failed, or handled by another app.")
                Text("·")
                Text(lastScanText)
            }
            .font(isSpacious ? .subheadline : .caption)
            .foregroundStyle(.secondary)
            if viewModel.selectedFilterID == InventoryScope.commandLineTools.id,
               !viewModel.directInstallRemnants.isEmpty {
                Button {
                    isRemnantsPresented.toggle()
                } label: {
                    let title = String(localized: "Installation remnants", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    let count = viewModel.directInstallRemnants.count.formatted(.number.locale(AppL10n.locale))
                    Label(
                        String(format: String(localized: "%@: %@", bundle: AppL10n.bundle, locale: AppL10n.locale), title, count),
                        systemImage: "link.badge.plus"
                    )
                    .font(.caption)
                }
                .buttonStyle(.link)
                .popover(isPresented: $isRemnantsPresented) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Installation remnants").font(.headline)
                        Text("These launchers point to missing files and are not counted as installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(viewModel.directInstallRemnants, id: \.path) { remnant in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(remnant.name)
                                Text(remnant.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(16)
                    .frame(width: 360, alignment: .leading)
                }
            }
        }
    }

    private func headerActions(isSpacious: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(InventoryColumn.allCases) { column in
                    Toggle(column.title, isOn: Binding(
                        get: { viewModel.visibleColumns.contains(column) },
                        set: { _ in viewModel.toggleColumn(column) }
                    ))
                    .disabled(column.isRequired)
                }
            } label: {
                Label("Visible Columns", systemImage: "tablecells")
            }
            .controlSize(isSpacious ? .regular : .small)
            .help("Choose visible columns")
            TextField("Search software", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(isSpacious ? .regular : .small)
                .focused($isSearchFocused)
                .frame(width: isSpacious ? 240 : 190)
            Button { Task { await viewModel.scan() } } label: {
                Label(
                    viewModel.isScanning
                        ? String(localized: "Scanning…", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        : String(localized: "Scan Now", bundle: AppL10n.bundle, locale: AppL10n.locale),
                    systemImage: "arrow.clockwise"
                )
                    .frame(minWidth: 68)
            }
            .adaptiveGlassProminentButtonStyle()
            .controlSize(.regular)
            .disabled(viewModel.isScanning)
        }
    }

    private var notScannedState: some View {
        ContentUnavailableView {
            Label("Not Scanned Yet", systemImage: "magnifyingglass")
        } description: {
            Text("Scan this Mac to see installed software and where its updates come from.")
        } actions: {
            Button("Scan Now") { Task { await viewModel.scan() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyStateTitle,
            systemImage: viewModel.selectedFilterID == DefaultInventoryView.updateAvailable.filterID
                ? "checkmark.circle" : "magnifyingglass",
            description: Text(emptyStateDescription)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !viewModel.searchText.isEmpty { return String(localized: "No Search Results", bundle: AppL10n.bundle, locale: AppL10n.locale) }
        if viewModel.selectedFilterID == DefaultInventoryView.updateAvailable.filterID { return String(localized: "No Confirmed Updates", bundle: AppL10n.bundle, locale: AppL10n.locale) }
        if viewModel.selectedFilterID == DefaultInventoryView.upToDate.filterID { return String(localized: "No Up-to-Date Software", bundle: AppL10n.bundle, locale: AppL10n.locale) }
        return String(localized: "No Software", bundle: AppL10n.bundle, locale: AppL10n.locale)
    }

    private var emptyStateDescription: String {
        if !viewModel.searchText.isEmpty { return String(localized: "Try another search or clear the search field.", bundle: AppL10n.bundle, locale: AppL10n.locale) }
        if viewModel.selectedFilterID == DefaultInventoryView.updateAvailable.filterID {
            let unresolved = viewModel.applications.contains {
                [.checkFailed, .sourcePending].contains($0.updateCheck.availability)
            }
            if unresolved {
                return String(localized: "No confirmed updates. Some software could not be checked; review Check Failed and Source Pending.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
            return String(localized: "No checked software currently has a newer version available.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
        return String(localized: "Try another category or clear the search field.", bundle: AppL10n.bundle, locale: AppL10n.locale)
    }

    private var lastScanText: String {
        guard let date = viewModel.lastScanDate else { return String(localized: "Not scanned yet", bundle: AppL10n.bundle, locale: AppL10n.locale) }
        return String(localized: "Last scanned:", bundle: AppL10n.bundle, locale: AppL10n.locale)
            + " \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))"
    }
}
