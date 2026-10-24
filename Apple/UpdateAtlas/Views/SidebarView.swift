import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentColorRawValue = AppearanceSettings.defaultAccentColor
    @State private var isMoreFiltersExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedFilterID) {
                Section("Update Status") {
                    ForEach(viewModel.primaryStatusFilters) { filter in
                        filterRow(filter)
                    }
                }

                Section("Software") {
                    ForEach(viewModel.primaryLibraryFilters) { filter in
                        filterRow(filter)
                    }
                }

                Section("Activity") {
                    Label {
                        HStack {
                            Text("Installation & Update History")
                                .font(.callout)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(viewModel.historyEvents.count, format: .number)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(effectiveAccentColor)
                    }
                    .tag("history")
                }

                Section(isExpanded: $isMoreFiltersExpanded) {
                    ForEach(viewModel.additionalFilters) { filter in
                        filterRow(filter)
                    }
                } header: {
                    Text("More Filters")
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                isMoreFiltersExpanded = viewModel.additionalFilters.contains {
                    $0.id == viewModel.selectedFilterID
                }
            }
            .onChange(of: viewModel.selectedFilterID) { _, selectedID in
                viewModel.clearSelection()
                if viewModel.additionalFilters.contains(where: { $0.id == selectedID }) {
                    isMoreFiltersExpanded = true
                }
            }

            Divider()

            VStack(spacing: 6) {
                SettingsLink {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Settings")
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Text("General, appearance, discovery, catalog & CLI")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
            SupportDevelopmentLink()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func iconColor(for filter: InventoryFilter) -> Color {
        switch filter.kind {
        case .scope(let scope):
            switch scope {
            case .games: .orange
            case .packageManagers: .purple
            case .directUpdateCapable: .green
            case .virtualMachinesAndBottles: .teal
            case .allInOne, .applications, .commandLineTools, .containers: effectiveAccentColor
            }
        case .status(let status): status.color
        case .updateAvailability(let availability): availability.color
        case .gamePlatform: .orange
        case .packageManager: .purple
        case .mechanism(let mechanism): mechanism == .unknown ? .orange : effectiveAccentColor
        case .updateStat(let stat):
            switch stat {
            case .applications: effectiveAccentColor
            case .packageManagers: .purple
            case .autoUpdateReady: .green
            }
        }
    }

    private var effectiveAccentColor: Color {
        (AppAccentColor(rawValue: accentColorRawValue) ?? .system).effectiveColor
    }

    private func filterHelp(for filter: InventoryFilter) -> String {
        switch filter.kind {
        case .mechanism(let mechanism): mechanism.explanation
        case .status(let status):
            String(format: String(localized: "Software grouped by whether Update Atlas knows where its updates come from: %@.", bundle: AppL10n.bundle, locale: AppL10n.locale), status.title)
        default: filter.title
        }
    }

    private func filterRow(_ filter: InventoryFilter) -> some View {
        Label {
            HStack {
                Text(filter.title)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .help(filterHelp(for: filter))
                if filter.kind == .scope(.virtualMachinesAndBottles) {
                    BetaFeatureBadge()
                }
                Spacer()
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                        .accessibilityLabel(String(format: String(localized: "Loading %@…", bundle: AppL10n.bundle, locale: AppL10n.locale), filter.title))
                } else {
                    Text(filter.count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: filter.symbolName)
                .foregroundStyle(iconColor(for: filter))
        }
        .tag(filter.id)
    }
}
