import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @AppStorage(InventorySettings.includeSystemApplicationsKey)
    private var includeSystemApplications = InventorySettings.defaultIncludeSystemApplications
    @AppStorage(InventorySettings.hideSystemPythonPackagesKey)
    private var hideSystemPythonPackages = InventorySettings.defaultHideSystemPythonPackages
    @AppStorage(InventorySettings.defaultViewKey)
    private var defaultView = InventorySettings.defaultView
    @AppStorage(AppearanceSettings.appearanceKey)
    private var appearanceRawValue = AppearanceSettings.defaultAppearance
    @AppStorage(AppearanceSettings.accentColorKey)
    private var accentColorRawValue = AppearanceSettings.defaultAccentColor
    @AppStorage(ReleaseChannelSettings.allowPrereleaseForStableKey)
    private var allowPrereleaseForStable = ReleaseChannelSettings.defaultAllowPrereleaseForStable
    @AppStorage(MenuBarSettings.enabledKey)
    private var isMenuBarEnabled = MenuBarSettings.defaultEnabled
    @AppStorage(MenuBarSettings.showCountKey)
    private var showMenuBarCount = MenuBarSettings.defaultShowCount
    @AppStorage(MenuBarSettings.showAppIconsKey)
    private var showMenuBarAppIcons = MenuBarSettings.defaultShowAppIcons
    @AppStorage(LanguageSettings.languageCodeKey)
    private var languageCode = LanguageSettings.defaultLanguageCode
    @State private var launchAtLoginEnabled = false
    @AppStorage(LaunchAtLoginService.openInMenuBarOnlyKey)
    private var openInMenuBarOnly = LaunchAtLoginService.defaultOpenInMenuBarOnly
    @State private var launchAtLoginError: String?

    var body: some View {
        TabView {
            generalPane
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            appearancePane
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            DiscoverySettingsView(viewModel: viewModel)
                .tabItem { Label("Discovery", systemImage: "magnifyingglass") }

            CatalogSettingsView(viewModel: viewModel)
                .tabItem {
                    Label("Catalog", systemImage: "books.vertical")
                }

            CLIAITabView()
                .tabItem {
                    Label("CLI & AI", systemImage: "terminal")
                }

            aboutPane
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding(10)
        .frame(width: 630, height: 550)
        .environment(\.locale, LanguageSettings.effectiveLocale(for: languageCode))
        .onChange(of: appearanceRawValue) { _, newValue in
            AppearanceSettings.apply(newValue)
        }
        .onChange(of: isMenuBarEnabled) { _, _ in
            UpdateAtlasMenuBarController.shared.refresh()
        }
        .onChange(of: showMenuBarCount) { _, _ in
            UpdateAtlasMenuBarController.shared.refresh()
        }
        .onChange(of: showMenuBarAppIcons) { _, _ in
            UpdateAtlasMenuBarController.shared.refresh()
        }
        .onChange(of: hideSystemPythonPackages) { _, _ in
            UpdateAtlasMenuBarController.shared.refresh()
        }
    }

    private var generalPane: some View {
        Form {
            Section("Language & Onboarding") {
                Picker("Language", selection: $languageCode) {
                    ForEach(LanguageSettings.primaryLanguages) { option in
                        Text(option.displayTitle).tag(option.id)
                    }
                }
                .onChange(of: languageCode) { _, newValue in
                    LanguageSettings.setLanguageCode(newValue)
                    UpdateAtlasMenuBarController.shared.refresh()
                }

                Text("Restart Update Atlas to apply the selected language throughout the app, including macOS menus and dialogs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Re-open the welcome setup flow to review language, defaults, and CLI/AI tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Onboarding…") {
                        OnboardingSettings.reset()
                    }
                }
            }

            Section("Startup & Menu Bar") {
                Toggle("Launch Update Atlas at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        do {
                            try LaunchAtLoginService.setEnabled(newValue)
                            launchAtLoginEnabled = LaunchAtLoginService.isEnabled()
                            launchAtLoginError = LaunchAtLoginService.shared.statusMessage
                        } catch {
                            launchAtLoginEnabled = LaunchAtLoginService.isEnabled()
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                ))
                Toggle("Start in the menu bar at login", isOn: $openInMenuBarOnly)
                    .disabled(!launchAtLoginEnabled)
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.orange)
                }

                Toggle("Show Update Atlas in the menu bar", isOn: $isMenuBarEnabled)
                Toggle("Show update count badge", isOn: $showMenuBarCount)
                    .disabled(!isMenuBarEnabled)
                Toggle("Show app icons beside updates in the menu", isOn: $showMenuBarAppIcons)
                    .disabled(!isMenuBarEnabled)

                Text("Closing the main window keeps Update Atlas in the menu bar. When 'Start in the menu bar at login' is enabled, Update Atlas starts in the menu bar without opening the main window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Software List") {
                Picker("Default view", selection: $defaultView) {
                    ForEach(DefaultInventoryView.allCases) { view in
                        Text(view.title).tag(view)
                    }
                }

                Picker("More Filters", selection: $viewModel.groupingMode) {
                    ForEach(GroupingMode.allCases) { mode in
                        Text(mode.title).tag(mode).help(mode.explanation)
                    }
                }

                Text(viewModel.groupingMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hide system Python packages from main Update Available list", isOn: $hideSystemPythonPackages)

                Text("System Python pip packages stay categorized under Packages and Python Managers, without cluttering the primary Update Available list or menu bar badge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Exclude apps managed by macOS", isOn: Binding(
                    get: { !includeSystemApplications },
                    set: { includeSystemApplications = !$0 }
                ))
                    .disabled(viewModel.isScanning)
                    .onChange(of: includeSystemApplications) { _, _ in
                        Task { await viewModel.scan() }
                    }

                Text("On by default. Keeps macOS-managed system apps out of the inventory. Turn it off to include them; changing this setting rescans immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scanning") {
                LabeledContent("Update checks") {
                    Text("Checks use each app’s own source: App Store, vendor feeds, GitHub, or a package manager. Supported apps can be updated with Sparkle, Homebrew or Microsoft AutoUpdate after your confirmation.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("You can also refresh the inventory manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Now") {
                        Task { await viewModel.scan() }
                    }
                    .disabled(viewModel.isScanning)
                }
            }

            BackgroundCheckSettingsSections(service: viewModel.backgroundChecks)

            Section("Release Channels") {
                Toggle(
                    "Allow pre-release updates for Stable installations",
                    isOn: $allowPrereleaseForStable
                )

                Text("Off by default. Stable software is compared only with Stable releases; Beta, Alpha, RC, Canary, and Nightly builds are never offered unless you explicitly enable this option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            LaunchAtLoginService.shared.refreshStatus()
            launchAtLoginEnabled = LaunchAtLoginService.isEnabled()
            launchAtLoginError = LaunchAtLoginService.shared.statusMessage
        }
    }

    private var appearancePane: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearanceRawValue) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("System follows the current macOS appearance. Light and Dark keep Update Atlas in the selected theme independently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Accent Color") {
                LabeledContent("Accent color") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 7) {
                            ForEach(AppAccentColor.allCases) { accent in
                                AccentSwatch(accent: accent, isSelected: accent == selectedAccentColor) {
                                    accentColorRawValue = accent.rawValue
                                }
                            }
                        }
                        Text(selectedAccentColor.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("System uses the accent color selected in macOS. Other choices apply only to Update Atlas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Update Atlas").font(.title.bold())
                            #if DEBUG
                            DebugBuildBadge()
                            #endif
                        }
                        Text(appVersionText).foregroundStyle(.secondary)
                    }
                }
                Text("See what is installed on your Mac and where each update comes from.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label("Open Source", systemImage: "chevron.left.forwardslash.chevron.right")
                    Text(verbatim: "· GPL-3.0-only")
                        .foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Links").font(.headline)
                    Link(destination: AboutLinks.repositoryURL) {
                        Label("Open Source Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: AboutLinks.websiteURL) {
                        Label("alperenalan.com", systemImage: "globe")
                    }
                    SupportDevelopmentLink()
                    Text("Update Atlas is free. Supporting development is optional and never changes scanning or update results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Text("Made in Istanbul by Alperen Alan")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        return String(format: String(localized: "Version %@ (Build %@)", bundle: AppL10n.bundle, locale: AppL10n.locale),
                      info?["CFBundleShortVersionString"] as? String ?? "—",
                      info?["CFBundleVersion"] as? String ?? "—")
    }

    private var selectedAccentColor: AppAccentColor {
        AppAccentColor(rawValue: accentColorRawValue) ?? .system
    }
}

/// One colour dot in the System Settings style: the selected dot carries an inner white mark,
/// and System shows the multicolour dot macOS uses for "follow the system accent".
private struct AccentSwatch: View {
    let accent: AppAccentColor
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    if isSelected {
                        Circle().fill(.white).frame(width: 6, height: 6)
                    }
                }
                .padding(2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(accent.title)
        .accessibilityLabel(accent.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: AnyShapeStyle {
        if accent == .system {
            AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                                          center: .center))
        } else {
            AnyShapeStyle(accent.previewColor)
        }
    }
}
