import AppKit
import Combine
import SwiftUI

struct CLIInstallationView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var installationState: CLIInstallationService.InstallationState = .notInstalled
    @State private var isInPATH = false
    @State private var copiedTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Label("Update Atlas CLI & AI Integration", systemImage: "terminal")
                    .font(.title2.bold())
                Spacer(minLength: 12)
                Button("Close", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(6)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }

            Text("The CLI runs read-only scans and update checks, outputs schema-versioned JSON, and never installs updates or modifies third-party software.")
                .fixedSize(horizontal: false, vertical: true)

            CLIAIStatusCard(
                installationState: installationState,
                isInPATH: isInPATH,
                onRefresh: refreshState
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick CLI & AI Commands")
                    .font(.subheadline.weight(.semibold))
                ForEach(AIIntegrationGuide.cliQuickReference.prefix(4), id: \.command) { item in
                    HStack {
                        Text(verbatim: item.command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Text(item.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Copy AI Skill (SKILL.md)") {
                    copyToPasteboard(AIIntegrationGuide.skillMarkdown, tag: "skill")
                }
                if copiedTarget != nil {
                    Text("Copied SKILL.md")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // The status card already offers Install and Repair; only add what it lacks.
                if !statusCardOffersInstall {
                    Button(installationState.isInstalled ? String(localized: "Re-verify Link", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "Install CLI", bundle: AppL10n.bundle, locale: AppL10n.locale)) {
                        CLIInstallationService.shared.installConfirmed()
                        refreshState()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear(perform: refreshState)
    }

    private var statusCardOffersInstall: Bool {
        switch installationState {
        case .notInstalled, .installedNeedsRepair: true
        case .installedAndCurrent, .conflictWithOtherFile: false
        }
    }

    private func refreshState() {
        installationState = CLIInstallationService.shared.currentState()
        isInPATH = CLIInstallationService.shared.isLocalBinInPATH
    }

    private func copyToPasteboard(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedTarget = tag
    }

    private func close() { dismissWindow(id: "cli-installation") }
}

struct CLIAIStatusCard: View {
    let installationState: CLIInstallationService.InstallationState
    let isInPATH: Bool
    let onRefresh: () -> Void
    let onInstallRequested: (() -> Void)?

    init(installationState: CLIInstallationService.InstallationState,
         isInPATH: Bool,
         onRefresh: @escaping () -> Void,
         onInstallRequested: (() -> Void)? = nil) {
        self.installationState = installationState
        self.isInPATH = isInPATH
        self.onRefresh = onRefresh
        self.onInstallRequested = onInstallRequested
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: installationState.isInstalled ? "checkmark.circle.fill" : "terminal")
                    .foregroundStyle(installationState.isInstalled ? .green : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installationState.title)
                        .font(.headline)
                    Text(verbatim: "~/.local/bin/update-atlas")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                HStack(spacing: 8) {
                    switch installationState {
                    case .notInstalled:
                        Button("Install CLI") {
                            if let onInstallRequested {
                                onInstallRequested()
                            } else {
                                CLIInstallationService.shared.installConfirmed()
                                onRefresh()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    case .installedAndCurrent:
                        Button("Remove Link") {
                            CLIInstallationService.shared.uninstallConfirmed()
                            onRefresh()
                        }
                    case .installedNeedsRepair:
                        Button("Repair Link") {
                            CLIInstallationService.shared.repairLinkConfirmed()
                            onRefresh()
                        }
                        .buttonStyle(.borderedProminent)
                    case .conflictWithOtherFile:
                        Button("Refresh", action: onRefresh)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: isInPATH ? "checkmark.seal.fill" : "info.circle")
                    .foregroundStyle(isInPATH ? .green : .orange)
                Text(
                    isInPATH
                        ? String(localized: "~/.local/bin is present in your environment PATH.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        : String(localized: "Add ~/.local/bin to your shell PATH if update-atlas is not found in Terminal.", bundle: AppL10n.bundle, locale: AppL10n.locale)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                if !isInPATH {
                    Button("Copy PATH Export") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(#"export PATH="$HOME/.local/bin:$PATH""#, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CLIAITabView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var installationState: CLIInstallationService.InstallationState = .notInstalled
    @State private var isInPATH = false
    @State private var copiedItem: String?
    @State private var showSkillPreview = false

    var body: some View {
        Form {
            Section("Command Line Tool (update-atlas)") {
                CLIAIStatusCard(
                    installationState: installationState,
                    isInPATH: isInPATH,
                    onRefresh: refreshState,
                    onInstallRequested: { openWindow(id: "cli-installation") }
                )
                Text("The CLI runs read-only scans and update checks, outputs schema-versioned JSON, and never installs updates or modifies third-party software.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI Agent Skill (SKILL.md)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        Button(
                            showSkillPreview
                                ? String(localized: "Hide Preview", bundle: AppL10n.bundle, locale: AppL10n.locale)
                                : String(localized: "Preview SKILL.md", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        ) {
                            showSkillPreview.toggle()
                        }
                        .controlSize(.small)
                        Button("Copy SKILL.md") {
                            copy(AIIntegrationGuide.skillMarkdown, label: "SKILL.md")
                        }
                        .controlSize(.small)
                    }
                    if showSkillPreview {
                        ScrollView {
                            Text(verbatim: AIIntegrationGuide.skillMarkdown)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 140)
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            Section("CLI Command Reference") {
                ForEach(AIIntegrationGuide.cliQuickReference, id: \.command) { entry in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text(entry.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy") {
                            copy(entry.command, label: entry.command)
                        }
                        .controlSize(.mini)
                        .accessibilityLabel(String(format: String(localized: "Copy %@", bundle: AppL10n.bundle, locale: AppL10n.locale), entry.command))
                    }
                }
                if let copiedItem {
                    Text(String(localized: "Copied to clipboard:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(copiedItem)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshState)
        .onReceive(NotificationCenter.default.publisher(for: CLIInstallationService.stateDidChange)) { _ in
            refreshState()
        }
    }

    private func refreshState() {
        installationState = CLIInstallationService.shared.currentState()
        isInPATH = CLIInstallationService.shared.isLocalBinInPATH
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedItem = label
    }
}
