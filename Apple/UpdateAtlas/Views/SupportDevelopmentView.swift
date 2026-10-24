import SwiftUI

struct SupportDevelopmentLink: View {
    var body: some View {
        if let url = SupportSettings.configuredURL {
            Link(destination: url) {
                Label("Support Development", systemImage: "heart")
            }
        } else {
            Label("Support Development", systemImage: "heart")
                .foregroundStyle(.secondary)
                .accessibilityHint("Support link is not available yet.")
                .help("Support link is not available yet.")
        }
    }
}

struct SupportReminderView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "heart")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Enjoying Update Atlas?").font(.title2.bold())
            Text("Update Atlas is free. If it helps you, you can leave a tip to support development. Nothing changes if you skip it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("No Thanks") { viewModel.dismissSupportReminder() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Support Development") {
                    guard let url = SupportSettings.configuredURL else { return }
                    openURL(url)
                    viewModel.dismissSupportReminder()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(SupportSettings.configuredURL == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { viewModel.markSupportReminderShown() }
        .onDisappear { viewModel.dismissSupportReminder() }
    }
}
