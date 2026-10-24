import SwiftUI

@main
struct UpdateAtlasApp: App {
    @NSApplicationDelegateAdaptor(AppearanceApplicationDelegate.self) private var appearanceDelegate
    @ObservedObject private var directUpdater = DirectUpdateService.shared
    @StateObject private var viewModel = AppInventoryViewModel()
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentColorRawValue = AppearanceSettings.defaultAccentColor
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @AppStorage(OnboardingSettings.completedKey) private var hasCompletedOnboarding = false
    private let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        Window("Update Atlas", id: "main") {
            if isRunningTests {
                // Hosted unit tests need the application process, but not the production
                // split-view hierarchy. Keeping the test host minimal also prevents AppKit
                // layout assertions from obscuring actual model/service test failures.
                EmptyView()
            } else {
                ContentView(viewModel: viewModel)
                    .frame(minWidth: 1_060, minHeight: 620)
                    .tint(selectedAccentColor.effectiveColor)
            }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1_360, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    SupportAboutPanel.show()
                } label: {
                    Label(String(localized: "About Update Atlas", bundle: AppL10n.bundle, locale: appLocale), systemImage: "info.circle")
                        .labelStyle(.titleAndIcon)
                }
                    .disabled(isRunningTests)
            }

            CommandGroup(after: .appInfo) {
                Button {
                    SelfUpdateService.shared.checkForUpdates()
                } label: {
                    Label(String(localized: "Check for Update Atlas Updates…", bundle: AppL10n.bundle, locale: appLocale), systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!SelfUpdateService.shared.isAvailable || isRunningTests || directUpdater.activeApplicationID != nil)

                CLIInstallationMenuButton()
                .disabled(isRunningTests)

                Divider()

                Button {
                    SelfUninstallService.shared.requestUninstall()
                } label: {
                    Label(String(localized: "Uninstall Update Atlas…", bundle: AppL10n.bundle, locale: appLocale), systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(isRunningTests || directUpdater.activeApplicationID != nil)
            }

            CommandGroup(after: .newItem) {
                Button {
                    Task { await viewModel.scan() }
                } label: {
                    Label(String(localized: "Scan Now", bundle: AppL10n.bundle, locale: appLocale), systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("r")
                .disabled(isRunningTests || viewModel.isScanning || !hasCompletedOnboarding)
            }

            CommandGroup(replacing: .help) {
                Button(String(localized: "Update Atlas Help", bundle: AppL10n.bundle, locale: appLocale)) {
                    NSWorkspace.shared.open(AboutLinks.repositoryURL)
                }
                Button(String(localized: "Report an Issue…", bundle: AppL10n.bundle, locale: appLocale)) {
                    NSWorkspace.shared.open(AboutLinks.newIssueURL)
                }
            }

            CommandMenu(String(localized: "Navigate", bundle: AppL10n.bundle, locale: appLocale)) {
                Button {
                    viewModel.selectAdjacent(offset: -1)
                } label: {
                    Label(String(localized: "Previous Software", bundle: AppL10n.bundle, locale: appLocale), systemImage: "chevron.up")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(viewModel.isSearchFieldFocused || viewModel.visibleApplications.isEmpty)

                Button {
                    viewModel.selectAdjacent(offset: 1)
                } label: {
                    Label(String(localized: "Next Software", bundle: AppL10n.bundle, locale: appLocale), systemImage: "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(viewModel.isSearchFieldFocused || viewModel.visibleApplications.isEmpty)
            }
        }

        Window(String(localized: "Install Command Line Tool", bundle: AppL10n.bundle, locale: appLocale), id: "cli-installation") {
            if isRunningTests {
                EmptyView()
            } else {
                CLIInstallationView()
                    .tint(selectedAccentColor.effectiveColor)
                    .environment(\.locale, appLocale)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            if isRunningTests {
                EmptyView()
            } else {
                SettingsView(viewModel: viewModel)
                    .tint(selectedAccentColor.effectiveColor)
            }
        }
    }

    private var selectedAccentColor: AppAccentColor {
        AppAccentColor(rawValue: accentColorRawValue) ?? .system
    }

    private var appLocale: Locale {
        languageSettings.effectiveLocale
    }
}
