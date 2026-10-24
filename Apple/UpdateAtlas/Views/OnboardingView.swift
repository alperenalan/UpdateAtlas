import SwiftUI
import AppKit
import Combine

struct OnboardingView: View {
    let onStart: (OnboardingPreferences) throws -> Void

    @State private var step = 0
    @State private var preferences = OnboardingPreferences.current()
    @State private var copiedFeedback: String?
    @State private var startError: String?
    @State private var loginItemMessage: String?
    @State private var loginItemHasError = false
    @State private var cliInstallationState: CLIInstallationService.InstallationState = CLIInstallationService.shared.currentState()
    @State private var cliIsInPATH = CLIInstallationService.shared.isLocalBinInPATH

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Update Atlas")
                        .font(.title3.bold())
                    Text(stepSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Text("\(step + 1) / 3")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(format: String(localized: "Step %d of 3", bundle: AppL10n.bundle, locale: AppL10n.locale), step + 1))
            }

            Divider()

            ScrollView {
                Group {
                    switch step {
                    case 0:
                        introductionStep
                    case 1:
                        preferencesStep
                    default:
                        cliAndAIStep
                    }
                }
                .padding(.vertical, 2)
            }

            Divider()

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                } else {
                    Text("No updates are installed automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if step < 2 {
                    Button("Continue") {
                        step += 1
                    }
                    .adaptiveGlassProminentButtonStyle()
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Scanning") {
                        do {
                            try onStart(preferences)
                            startError = nil
                        } catch {
                            startError = error.localizedDescription
                        }
                    }
                    .adaptiveGlassProminentButtonStyle()
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: 590)
        .environment(\.locale, LanguageSettings.effectiveLocale(for: preferences.languageCode))
        .onChange(of: preferences.languageCode) { _, newValue in
            LanguageSettings.setLanguageCode(newValue)
            UpdateAtlasMenuBarController.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: CLIInstallationService.stateDidChange)) { _ in
            cliInstallationState = CLIInstallationService.shared.currentState()
            cliIsInPATH = CLIInstallationService.shared.isLocalBinInPATH
        }
    }

    private var stepSubtitle: LocalizedStringKey {
        switch step {
        case 0: "Choose your language and see how Update Atlas works"
        case 1: "Configure startup, menu bar, and inventory defaults"
        default: "Update Atlas CLI & AI Integration"
        }
    }

    private var introductionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Language", systemImage: "globe")
                    .fontWeight(.medium)
                Spacer()
                Picker("Language", selection: $preferences.languageCode) {
                    ForEach(LanguageSettings.primaryLanguages) { option in
                        Text(option.displayTitle).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 280)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            Text("Update Atlas checks installed macOS apps, games, CLI tools, Windows bottles, and virtual machines to show who manages each update.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                featureRow(
                    symbol: "checkmark.shield",
                    title: "Read-only scans & updates you approve",
                    detail: "Scans only report updates. Supported apps can be updated with Sparkle, Homebrew, or Microsoft AutoUpdate after you confirm, or opened directly in the App Store."
                )
                Divider()
                featureRow(
                    symbol: "network",
                    title: "360+ built-in catalog rules & online checks",
                    detail: "Checks contact publisher feeds, GitHub releases and package registries."
                )
                Divider()
                featureRow(
                    symbol: "square.stack.3d.up",
                    title: "Game clients, Wine bottles & virtual machines",
                    detail: "Tracks Steam, Epic, GOG, Battle.net, CrossOver/Whisky Windows bottles, and UTM/VMware/Parallels virtual machines under their parent managers."
                )
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var preferencesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Open with")
                    Spacer()
                    Picker("Open with", selection: $preferences.defaultView) {
                        ForEach(DefaultInventoryView.allCases) { view in
                            Text(view.title).tag(view)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 205)
                }
                .padding(.top, 10)
                Text("This is the page shown after launch; every scan still checks all enabled sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                Divider()
                preferenceToggle(
                    "Launch Update Atlas at login",
                    detail: "Start Update Atlas automatically when you sign in to macOS.",
                    isOn: Binding(
                        get: { preferences.launchAtLogin },
                        set: { enabled in
                            do {
                                try preferences.setLaunchAtLogin(enabled) {
                                    try LaunchAtLoginService.shared.setEnabled($0)
                                }
                                loginItemMessage = LaunchAtLoginService.shared.statusMessage
                                loginItemHasError = false
                            } catch {
                                loginItemMessage = LaunchAtLoginService.shared.statusMessage ?? error.localizedDescription
                                loginItemHasError = true
                            }
                        }
                    )
                )
                if let loginItemMessage {
                    Text(loginItemMessage)
                        .font(.caption)
                        .foregroundStyle(loginItemHasError ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                preferenceToggle(
                    "Start in the menu bar at login",
                    detail: "Default on. Starts quietly in the macOS menu bar without opening the main window on login.",
                    isOn: $preferences.openInMenuBarOnly
                )
                .disabled(!preferences.launchAtLogin)
                Divider()
                preferenceToggle(
                    "Show app icons beside updates in the menu",
                    detail: "Shows each application's icon beside its update in the menu. The menu bar keeps the Update Atlas icon and update count.",
                    isOn: $preferences.showMenuBarIcons
                )
                Divider()
                preferenceToggle(
                    "Hide system Python packages from main Update Available list",
                    detail: "Recommended. Keeps system Python pip libraries out of the top-level Update Available view unless inspected under Packages.",
                    isOn: $preferences.hideSystemPythonPackages
                )
                Divider()
                preferenceToggle(
                    "Exclude apps managed by macOS",
                    detail: "On by default. Keeps macOS-managed system apps out of the inventory. Turn it off to include them; macOS still handles their updates.",
                    isOn: $preferences.excludeSystemApplications
                )
                Divider()
                preferenceToggle(
                    "Enable catalog matching",
                    detail: "Use bundled rules to recognize apps and their trusted update sources.",
                    isOn: $preferences.catalogMatchingEnabled
                )
                Divider()
                preferenceToggle(
                    "Allow pre-release updates for Stable installations",
                    detail: "Off by default. When enabled, a Stable install may be offered RC, Beta, Alpha, Canary, or Nightly builds.",
                    isOn: $preferences.allowPrereleaseForStable
                )
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var cliAndAIStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The CLI runs read-only scans and update checks, outputs schema-versioned JSON, and never installs updates or modifies third-party software.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CLIAIStatusCard(
                installationState: cliInstallationState,
                isInPATH: cliIsInPATH,
                onRefresh: {
                    cliInstallationState = CLIInstallationService.shared.currentState()
                    cliIsInPATH = CLIInstallationService.shared.isLocalBinInPATH
                },
                onInstallRequested: {
                    CLIInstallationService.shared.installConfirmed(showsSuccessAlert: false)
                    cliInstallationState = CLIInstallationService.shared.currentState()
                    cliIsInPATH = CLIInstallationService.shared.isLocalBinInPATH
                }
            )

            if let startError {
                Text(startError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("AI Agent Skill (SKILL.md)", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let copiedFeedback {
                        Text(copiedFeedback)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AIIntegrationGuide.skillMarkdown, forType: .string)
                        copiedFeedback = String(localized: "Copied SKILL.md", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    } label: {
                        Label("Copy Agent SKILL.md", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func preferenceToggle(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
    }

    private func featureRow(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
