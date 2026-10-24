import SwiftUI

struct InspectorView: View {
    @ObservedObject private var directUpdater = DirectUpdateService.shared
    @ObservedObject var viewModel: AppInventoryViewModel
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentColorRawValue = AppearanceSettings.defaultAccentColor
    @Environment(\.locale) private var locale
    @AppStorage("inspectorTechnicalDetailsExpanded") private var isTechnicalDetailsExpanded = false

    var body: some View {
        Group {
            if let application = viewModel.selectedApplication {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        identity(application)
                        Divider()
                        updateStatus(application)
                        actions(application)
                        Divider()
                        metadata(application)
                        Divider()
                        history(application)
                        Divider()
                        notes(application)
                        Divider()
                        DisclosureGroup(isExpanded: $isTechnicalDetailsExpanded) {
                            VStack(alignment: .leading, spacing: 13) {
                                coverage(application)
                                technicalFields(application)
                                Divider()
                                confidence(application)
                                Divider()
                                evidence(application)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Technical Details")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(14)
                }
                .id(application.id)
            } else {
                ContentUnavailableView(
                    "Select Software",
                    systemImage: "shippingbox",
                    description: Text("Details and detection evidence will appear here.")
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func identity(_ application: InstalledApplication) -> some View {
        HStack(spacing: 12) {
            ApplicationIcon(application: application, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .font(.headline.bold())
                    .lineLimit(2)
                if application.inventoryReleaseChannel != "notApplicable" { ChannelBadge(channel: application.releaseChannel) }
                Text(application.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .adaptiveGlassPanel(cornerRadius: 14)
    }

    private func updateStatus(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update Status")
                .font(.caption)
                .foregroundStyle(.secondary)
            UpdateAvailabilityLabel(result: application.updateCheck)
                .font(.headline)
            let managedUpdateCount = viewModel.managedUpdateCount(for: application)
            if managedUpdateCount > 0 {
                Label(
                    AppL10n.plural("%lld managed updates", singular: "%lld managed update", count: managedUpdateCount),
                    systemImage: "arrow.down.circle.fill"
                )
                .foregroundStyle(effectiveAccentColor)
                .font(.callout.weight(.medium))
            }
            Text(application.updateCheck.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let latestVersion = application.updateCheck.latestVersion {
                InspectorField(
                    label: application.updateCheck.source == .steamManifest
                        ? "Target Steam Build" : "Latest Version",
                    value: latestVersion
                )
            }
            if let source = application.updateCheck.source {
                InspectorField(label: "Checked With", value: source.title)
            }
            if let checkedAt = application.updateCheck.checkedAt {
                InspectorField(
                    label: "Checked",
                    value: checkedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
                )
            }
            if let summary = application.updateCheck.releaseNotesSummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("What’s New")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Text(summary)
                    .font(.callout)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var effectiveAccentColor: Color {
        (AppAccentColor(rawValue: accentColorRawValue) ?? .system).effectiveColor
    }

    private func coverage(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mechanism Status")
                .font(.caption)
                .foregroundStyle(.secondary)
            StatusLabel(status: application.status)
                .font(.headline)
            Text(statusExplanation(application.status))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadata(_ application: InstalledApplication) -> some View {
        VStack(spacing: 8) {
            InspectorField(label: "Type", value: application.kind.title)
            if let facts = application.discovery {
                InspectorField(label: "Discovery Source", value: facts.sourceTitle)
                if let platform = facts.platform { InspectorField(label: "Platform", value: platform) }
                if let state = facts.stateTitle { InspectorField(label: "Container State", value: state) }
                if let version = facts.manifestVersion { InspectorField(label: "Manifest Version", value: version) }
            }
            if let gamePlatform = application.gamePlatform {
                InspectorField(label: "Game Platform", value: gamePlatform.title)
            }
            InspectorField(label: "Installed Version", value: application.versionLabel)
            if application.inventoryReleaseChannel != "notApplicable" {
                InspectorField(label: "Release Channel", value: application.releaseChannel.title)
            }
            if let managerName = application.parentManagerName {
                InspectorField(label: "Parent Manager", value: managerName)
            }
            InspectorField(
                label: "Open Source",
                value: application.isOpenSource.map {
                    $0 ? String(localized: "Yes", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "No", bundle: AppL10n.bundle, locale: AppL10n.locale)
                } ?? String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
            InspectorField(label: "Update Mechanism", value: application.mechanismName)
            InspectorField(
                label: application.kind == .application || application.kind == .game
                    ? "Bundle Identifier"
                    : "Package Identifier",
                value: application.bundleIdentifier
            )
            if !application.path.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text("Install Location")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 104, alignment: .leading)
                    Button { viewModel.showInFinder(application) } label: {
                        Text(application.packageProvenance?.installLocation ?? application.path)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                    .disabled(!application.existsOnDisk)
                }
            }
            if let provenance = application.packageProvenance {
                InspectorField(label: "Package Manager", value: provenance.manager.title)
                if let environment = provenance.environmentLabel {
                    InspectorField(label: "Environment", value: environment)
                }
            }
        }
    }

    @ViewBuilder
    private func technicalFields(_ application: InstalledApplication) -> some View {
        let facts = application.discovery
        if facts?.service != nil || facts?.imageID != nil
            || application.packageProvenance != nil || application.catalogEntryID != nil {
            VStack(spacing: 8) {
                if let service = facts?.service { InspectorField(label: "Compose Service", value: service) }
                if let image = facts?.imageID { InspectorField(label: "Image Identity", value: image) }
                if let provenance = application.packageProvenance {
                    InspectorField(label: "Manager Path", value: provenance.managerExecutablePath)
                }
                if let catalogEntryID = application.catalogEntryID {
                    InspectorField(label: "Catalog Rule", value: catalogEntryID)
                }
            }
        }
    }

    private func confidence(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(application.confidence.title)
                    .fontWeight(.medium)
            }
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { index in
                    Capsule()
                        .fill(index <= application.confidence.rawValue ? Color.green : Color.secondary.opacity(0.18))
                        .frame(height: 6)
                }
            }
            Text("Based on bundle metadata, signing identity, path, and catalog evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func history(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installation & Update History")
                .font(.subheadline.weight(.semibold))
            let events = viewModel.historyEvents(for: application.id)
            if events.isEmpty {
                Text("No observed changes yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind == .newlyDetected
                            ? String(localized: "New software detected", bundle: AppL10n.bundle, locale: locale)
                            : event.kind == .reappeared
                                ? String(localized: "Software detected again", bundle: AppL10n.bundle, locale: locale)
                                : String(localized: "Installed version changed", bundle: AppL10n.bundle, locale: locale))
                            .font(.callout.weight(.medium))
                        if event.kind == .versionChanged {
                            Text(verbatim: "\(event.previousVersion ?? "?") → \(event.version ?? "?")")
                                .font(.caption)
                        } else if let version = event.version {
                            Text(version).font(.caption)
                        }
                        Text(event.observedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func evidence(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detection Evidence")
                .font(.subheadline.weight(.semibold))
            ForEach(application.evidence) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.level == .warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(item.level.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func notes(_ application: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(application.notes)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actions(_ application: InstalledApplication) -> some View {
        VStack(spacing: 7) {
            if let action = ManagerUpdatePolicy.action(for: application) {
                Button {
                    viewModel.requestUpdate(application)
                } label: {
                    Label(action == .appStorePage ? String(localized: "Open App Store Page", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        : action == .microsoftAutoUpdateConfirmation ? String(localized: "Check and Update with Microsoft AutoUpdate…", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        : action == .homebrewConfirmation ? String(localized: "Update with Homebrew…", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        : String(localized: "Update Application…", bundle: AppL10n.bundle, locale: AppL10n.locale), systemImage: action == .appStorePage ? "storefront" : "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassProminentButtonStyle()
                .controlSize(.regular)
                .disabled(viewModel.isScanning || directUpdater.activeApplicationID != nil)
                if action == .sparkleConfirmation {
                    Text("The app’s signed Sparkle updater will ask before downloading and installing. Quit the app first.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if action == .microsoftAutoUpdateConfirmation {
                    Text("Microsoft AutoUpdate checks availability itself. You will confirm before an update is requested.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if application.mechanism == .appStore {
                Button {
                    viewModel.openAppStore(for: application)
                } label: {
                    Label("Open App Store Page", systemImage: "storefront")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            if directUpdater.activeApplicationID == application.id, let status = directUpdater.managerStatus {
                HStack { ProgressView().controlSize(.small); Text(status).font(.callout) }
                Text("Keep Update Atlas open until the manager finishes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !directUpdater.managerOutput.isEmpty, directUpdater.managerApplicationID == application.id {
                ScrollView {
                    Text(directUpdater.managerOutput).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            if application.path.hasSuffix(".app") {
                Button {
                    viewModel.openApplication(application)
                } label: {
                    Label("Open Application", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassProminentButtonStyle()
                .controlSize(.regular)
                .disabled(!application.existsOnDisk || directUpdater.activeApplicationID == application.id)
            }

            if application.parentManagerBundleIdentifier != nil || application.mechanism == .externalManager {
                Button {
                    viewModel.openManager(for: application)
                } label: {
                    Label(
                        String(format: String(localized: "Open %@", bundle: AppL10n.bundle, locale: AppL10n.locale), application.parentManagerName ?? application.name),
                        systemImage: "arrow.up.forward.app"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(directUpdater.activeApplicationID == application.id)
            }

            if application.vendorURL != nil {
                Button {
                    viewModel.openVendorWebsite(application)
                } label: {
                    Label("Open Website", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if let releaseURL = application.updateCheck.releaseNotesURL ?? application.releaseNotesURL {
                Button { viewModel.openURL(releaseURL) } label: {
                    Label("View Version Changelog", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if let sourceURL = application.sourceCodeURL {
                Button { viewModel.openURL(sourceURL) } label: {
                    Label("Open Source Repository", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button {
                viewModel.showInFinder(application)
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!application.existsOnDisk)
        }
    }

    private func statusExplanation(_ status: UpdateSupportStatus) -> String {
        switch status {
        case .supported: String(localized: "A known update mechanism can be monitored.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .managedExternally: String(localized: "Updates are owned by another application or by macOS.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .needsCatalog: String(localized: "The mechanism is visible, but its public update source still needs a catalog rule.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .unsupported: String(localized: "No supported update source was found. No freshness claim is made.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .checkFailed: String(localized: "The last update-source check failed and should be retried.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

private struct InspectorField: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
