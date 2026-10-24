import SwiftUI
import AppKit

struct BackgroundCheckSettingsSections: View {
    @ObservedObject var service: BackgroundCheckService
    @ObservedObject private var notifications = UpdateNotificationService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale

    var body: some View {
        Section("Automatic Checks") {
            Toggle("Check for updates periodically", isOn: Binding(
                get: { service.isEnabled }, set: { service.setEnabled($0) }
            ))
            Picker("Check interval", selection: Binding(
                get: { service.interval }, set: { service.setInterval($0) }
            )) {
                ForEach(CheckInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .disabled(!service.isEnabled)
            if let date = service.nextCheckDate {
                LabeledContent("Next check") {
                    if service.isRunningScheduledScan {
                        Text("Checking now…")
                    } else if date <= Date() {
                        Text("Waiting for the current task")
                    } else {
                        Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)))
                    }
                }
            }
            Text("Checks run while Update Atlas is open, including in the menu bar. They pause during sleep and never install updates. Quit stops the schedule.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Update Notifications") {
            Toggle("Notify me about new updates", isOn: Binding(
                get: { notifications.isEnabled },
                set: { value in Task { await notifications.setEnabled(value) } }
            ))
            Toggle("Play notification sound", isOn: Binding(
                get: { notifications.soundEnabled }, set: { notifications.soundEnabled = $0 }
            ))
            .disabled(!notifications.isEnabled)
            Toggle("Notify for applications", isOn: Binding(
                get: { notifications.notifyApplications }, set: { notifications.notifyApplications = $0 }
            ))
            .disabled(!notifications.isEnabled)
            Toggle("Notify for games", isOn: Binding(
                get: { notifications.notifyGames }, set: { notifications.notifyGames = $0 }
            ))
            .disabled(!notifications.isEnabled)
            Toggle("Notify for packages & CLI tools", isOn: Binding(
                get: { notifications.notifyPackages }, set: { notifications.notifyPackages = $0 }
            ))
            .disabled(!notifications.isEnabled)

            if notifications.isRequestingPermission {
                ProgressView().controlSize(.small)
            }
            if notifications.isEnabled {
                HStack {
                    Text(notifications.permission.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send Test Notification") {
                        Task { await notifications.sendTestNotification() }
                    }
                    .controlSize(.small)
                }
                if notifications.permission == .notRequested {
                    // Before macOS has asked, System Settings has nothing to change yet.
                    Button("Allow Notifications…") {
                        Task { await notifications.setEnabled(true) }
                    }
                    .disabled(notifications.isRequestingPermission)
                } else if notifications.permission != .allowed {
                    Button("Open macOS Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
            if let error = notifications.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Only newly confirmed update versions are announced, in one notification per scan. Repeated scans and relaunches do not repeat the same version. Notifications work with manual checks too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await notifications.refreshPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refreshPermission() } }
        }
    }
}
