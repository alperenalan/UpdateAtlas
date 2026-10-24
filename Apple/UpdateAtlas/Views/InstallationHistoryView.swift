import SwiftUI

struct InstallationHistoryView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Installation & Update History")
                    .font(.title2.bold())
                Text("Dates show when Update Atlas observed a new item or installed version. Earlier installations cannot be reconstructed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let historyError = viewModel.historyError {
                    Label(historyError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
            Divider()
            if viewModel.historyEvents.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("The first complete scan creates a baseline. Later scans record newly detected software and installed version changes.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.historyEvents) { event in
                            HistoryEventRow(event: event, locale: locale) {
                                viewModel.revealApplication(id: event.itemID)
                            }
                            .disabled(!viewModel.applications.contains { $0.id == event.itemID })
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct HistoryEventRow: View {
    let event: InstallationHistoryEvent
    let locale: Locale
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.kind == .versionChanged ? "arrow.up.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(event.kind == .versionChanged ? Color.blue : Color.green)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.name).font(.callout.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(event.observedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        switch event.kind {
        case .newlyDetected:
            return String(localized: "New software detected", bundle: AppL10n.bundle, locale: locale)
                + (event.version.map { " · \($0)" } ?? "")
        case .reappeared:
            return String(localized: "Software detected again", bundle: AppL10n.bundle, locale: locale)
                + (event.version.map { " · \($0)" } ?? "")
        case .versionChanged:
            return String(localized: "Installed version changed", bundle: AppL10n.bundle, locale: locale)
                + " · \(event.previousVersion ?? "?") → \(event.version ?? "?")"
        }
    }
}
