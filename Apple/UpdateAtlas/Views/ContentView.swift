import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: AppInventoryViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(OnboardingSettings.completedKey) private var hasCompletedOnboarding = false
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject private var launchAtLoginService = LaunchAtLoginService.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isOnboardingPresented = false
    @State private var didApplyStartupVisibility = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(viewModel: viewModel)
                        .navigationSplitViewColumnWidth(
                            min: 280, ideal: min(340, max(300, geometry.size.width * 0.20)), max: 360
                        )
                } detail: {
                    Group {
                        if viewModel.selectedFilterID == "history" {
                            InstallationHistoryView(viewModel: viewModel)
                        } else {
                            ApplicationListView(viewModel: viewModel)
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .blur(radius: viewModel.isForegroundScan ? 6 : 0)
                .disabled(viewModel.isForegroundScan)

                if viewModel.isForegroundScan {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                    scanProgressCard
                        .frame(width: max(0, min(440, geometry.size.width - 40)))
                }
            }
        }
        .environment(\.locale, languageSettings.effectiveLocale)
        .sheet(isPresented: Binding(
            get: { viewModel.isSupportReminderPresented && !isOnboardingPresented },
            set: { if !$0 { viewModel.dismissSupportReminder() } }
        )) {
            SupportReminderView(viewModel: viewModel)
                .environment(\.locale, languageSettings.effectiveLocale)
        }
        .toolbar {
            if viewModel.selectedApplication != nil {
                ToolbarItem(placement: .primaryAction) {
                    let title = viewModel.isInspectorPresented
                        ? String(localized: "Hide Inspector", bundle: AppL10n.bundle, locale: AppL10n.locale)
                        : String(localized: "Show Inspector", bundle: AppL10n.bundle, locale: AppL10n.locale)
                    Button(title, systemImage: "sidebar.right") {
                        viewModel.isInspectorPresented.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("i", modifiers: [.option, .command])
                    .help(title)
                }
            }
        }
        .onAppear {
            viewModel.isInspectorPresented = viewModel.selectedApplication != nil
            UpdateNotificationService.shared.attach { ids in
                viewModel.revealNotificationItems(ids)
                openWindow(id: "main")
                NSApp.activate()
            }
            UpdateAtlasMenuBarController.shared.attach(
                viewModel: viewModel,
                openMainWindow: {
                    openWindow(id: "main")
                    for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "Update Atlas" {
                        window.makeKeyAndOrderFront(nil)
                    }
                },
                openSettingsWindow: { openSettings() }
            )
            applyStartupVisibilityIfNeeded()
        }
        .onChange(of: launchAtLoginService.hasRecordedLaunchEvent) { _, _ in
            applyStartupVisibilityIfNeeded()
        }
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if OnboardingSettings.shouldPresent(
                completed: completed,
                uninstalling: SelfUninstallService.shared.isUninstalling
            ) {
                openWindow(id: "main")
                NSApp.activate()
                isOnboardingPresented = true
            }
        }
        .sheet(isPresented: $isOnboardingPresented) {
            OnboardingView { preferences in
                try preferences.save()
                viewModel.selectedFilterID = preferences.defaultView.filterID
                hasCompletedOnboarding = true
                isOnboardingPresented = false
                UpdateAtlasMenuBarController.shared.refresh()
                Task {
                    await UpdateNotificationService.shared.requestPermissionIfEnabled()
                    await viewModel.start()
                }
            }
            .interactiveDismissDisabled()
        }
        .task {
            guard !SelfUninstallService.shared.isUninstalling else { return }
            if hasCompletedOnboarding {
                await UpdateNotificationService.shared.requestPermissionIfEnabled()
                await viewModel.start()
            } else {
                isOnboardingPresented = true
            }
        }
    }

    private var scanProgressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Scanning…")
                        .font(.title3.weight(.semibold))
                    Text(viewModel.scanPhase)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.accentColor)
            HStack {
                Spacer()
                Button("Cancel Scan") { viewModel.cancelScan() }
                    .disabled(viewModel.scanPhase == String(localized: "Stopping scan…", bundle: AppL10n.bundle, locale: AppL10n.locale))
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
    }

    private func applyStartupVisibilityIfNeeded() {
        guard !didApplyStartupVisibility, launchAtLoginService.hasRecordedLaunchEvent else { return }
        didApplyStartupVisibility = true
        guard hasCompletedOnboarding, launchAtLoginService.shouldStartQuietlyInMenuBar else { return }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == "main" || window.title == "Update Atlas" {
                window.orderOut(nil)
            }
        }
    }
}
