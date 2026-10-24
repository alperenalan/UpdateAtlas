import SwiftUI

struct InventoryTableCell: View {
    let row: NativeInventoryRow
    let column: InventoryColumn
    let isSpacious: Bool
    @ObservedObject private var directUpdater = DirectUpdateService.shared
    @ObservedObject var viewModel: AppInventoryViewModel
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentColorRawValue = AppearanceSettings.defaultAccentColor

    var body: some View {
        Group {
            switch row {
            case .application(let app, let depth, let hasChildren, let managedUpdates, let expanded):
                applicationCell(app, depth: depth, hasChildren: hasChildren,
                                managedUpdates: managedUpdates, expanded: expanded)
            }
        }
        .tint((AppAccentColor(rawValue: accentColorRawValue) ?? .system).effectiveColor)
        .font(isSpacious ? .body : .callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, isSpacious ? 9 : 5)
    }

    @ViewBuilder
    private func applicationCell(_ app: InstalledApplication, depth: Int, hasChildren: Bool,
                                 managedUpdates: Int, expanded: Bool) -> some View {
        switch column {
        case .name:
            HStack(spacing: 6) {
                Color.clear.frame(width: CGFloat(depth) * 15)
                if hasChildren {
                    Button {
                        viewModel.toggleExpanded(app)
                        viewModel.clearSelectionIfHidden()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Managed items:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " " + app.name)
                    .accessibilityValue(expanded ? String(localized: "Expanded", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "Collapsed", bundle: AppL10n.bundle, locale: AppL10n.locale))
                } else { Color.clear.frame(width: 12) }
                ApplicationIcon(application: app, size: isSpacious ? 30 : 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name).fontWeight(.medium).lineLimit(1)
                        if app.inventoryReleaseChannel != "notApplicable" {
                            ChannelBadge(channel: app.releaseChannel, compact: true)
                        }
                    }
                    Text(subtitle(app)).font(isSpacious ? .caption : .caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if ManagerUpdatePolicy.offersInlineUpdate(for: app) {
                    Button { viewModel.requestUpdate(app) } label: {
                        if directUpdater.activeApplicationID == app.id {
                            ProgressView().controlSize(.small).frame(width: 58)
                        } else { Text("Update").fontWeight(.semibold) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(viewModel.isScanning || directUpdater.activeApplicationID != nil)
                    .accessibilityLabel(String(format: String(localized: "Update %@", bundle: AppL10n.bundle, locale: AppL10n.locale), app.name))
                    .help(app.mechanismName)
                } else if ManagerUpdatePolicy.offersInlineAppStore(for: app) {
                    Button { viewModel.openAppStore(for: app) } label: {
                        Label("App Store", systemImage: "bag")
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(viewModel.isScanning)
                    .accessibilityLabel(String(localized: "Open in App Store:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " " + app.name)
                    .help(String(localized: "Open this application's page in the Mac App Store", bundle: AppL10n.bundle, locale: AppL10n.locale))
                } else if let openAction = viewModel.inlineOpenAction(for: app) {
                    Button {
                        switch openAction {
                        case .openManager: viewModel.openManager(for: app)
                        case .openApplication: viewModel.openApplication(app)
                        case .openReleasePage:
                            if let url = MenuBarUpdateAction.releasePageURL(for: app) {
                                viewModel.openURL(url)
                            }
                        case .openWebsite:
                            if let url = MenuBarUpdateAction.safeWebURL(app.vendorURL) { viewModel.openURL(url) }
                        default: break
                        }
                    } label: {
                        if openAction == .openReleasePage {
                            Label("View Version Changelog", systemImage: "doc.text").fontWeight(.medium)
                        } else if openAction == .openWebsite {
                            Label("Open Website", systemImage: "safari").fontWeight(.medium)
                        } else {
                            Label("Open Application", systemImage: "arrow.up.forward.app").fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(viewModel.isScanning || directUpdater.activeApplicationID != nil)
                    .accessibilityLabel(inlineActionAccessibilityLabel(openAction, app: app))
                }
            }
        case .installedVersion: Text(app.versionLabel).lineLimit(1)
        case .type: Text(app.kind.title).lineLimit(1)
        case .parent: Text(app.parentManagerName ?? "—").lineLimit(1)
        case .updateMechanism:
            if app.mechanism == .appStore {
                Label(app.mechanismName, systemImage: "apple.logo").lineLimit(2)
            } else { Text(app.mechanismName).lineLimit(2) }
        case .mechanismStatus: StatusLabel(status: app.status)
        case .openSource:
            Text(app.isOpenSource.map { $0 ? String(localized: "Yes", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "No", bundle: AppL10n.bundle, locale: AppL10n.locale) }
                 ?? String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale))
        case .updateStatus:
            if managedUpdates > 0 && app.updateCheck.availability != .updateAvailable {
                VStack(alignment: .leading, spacing: 2) {
                    Label(AppL10n.plural("%lld managed updates", singular: "%lld managed update", count: managedUpdates), systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.tint).lineLimit(1)
                    Text(app.updateCheck.availability.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else { UpdateAvailabilityLabel(result: app.updateCheck) }
        }
    }

    private func subtitle(_ app: InstalledApplication) -> String {
        var parts = [app.kind.title]
        if let manager = app.parentManagerName { parts.append(String(localized: "Managed by", bundle: AppL10n.bundle, locale: AppL10n.locale) + " " + manager) }
        if let environment = app.packageProvenance?.environmentLabel { parts.append(environment) }
        return parts.joined(separator: " · ")
    }

    private func inlineActionAccessibilityLabel(_ action: MenuBarUpdateAction, app: InstalledApplication) -> String {
        let title: String
        switch action {
        case .openReleasePage: title = String(localized: "View Version Changelog", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .openWebsite: title = String(localized: "Open Website", bundle: AppL10n.bundle, locale: AppL10n.locale)
        default: title = String(localized: "Open Application", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
        let name = action == .openManager ? app.parentManagerName ?? app.name : app.name
        return String(format: String(localized: "%@: %@", bundle: AppL10n.bundle, locale: AppL10n.locale), title, name)
    }
}
