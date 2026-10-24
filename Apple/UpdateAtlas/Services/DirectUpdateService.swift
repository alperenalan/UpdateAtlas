import AppKit
import Security
import Sparkle

/// Explicit GUI actions use the verified installation owner. Scans never install updates.
@MainActor
final class DirectUpdateService: ObservableObject {
    static let shared = DirectUpdateService()
    @Published private(set) var activeApplicationID: String?
    @Published private(set) var managerStatus: String?
    @Published private(set) var managerOutput = ""
    @Published private(set) var managerApplicationID: String?
    private var session: DirectUpdateSession?
    private var outputSessionID = UUID()
    private var managerTask: Task<Void, Never>?

    func requestUpdate(_ application: InstalledApplication, refresh: @escaping @MainActor () async -> Void) {
        guard activeApplicationID == nil else { return }
        guard let action = ManagerUpdatePolicy.action(for: application) else { return }
        if action == .appStorePage {
            activeApplicationID = application.id
            managerTask = Task {
                defer { activeApplicationID = nil; managerTask = nil }
                do {
                    let page = try await UpdateCheckService().appStorePage(for: application)
                    if let store = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") {
                        _ = try await NSWorkspace.shared.open([page], withApplicationAt: store, configuration: .init())
                    } else { NSWorkspace.shared.open(page) }
                }
                catch { showError(String(localized: "The App Store product page could not be found. Try scanning again.", bundle: AppL10n.bundle, locale: AppL10n.locale)) }
            }
            return
        }
        if action == .homebrewConfirmation || action == .microsoftAutoUpdateConfirmation {
            requestManagerUpdate(application, action: action, refresh: refresh)
            return
        }
        guard let configuration = DirectUpdatePolicy.configuration(for: application),
              let bundle = Bundle(url: configuration.bundleURL),
              Self.hasValidSignature(configuration.bundleURL, bundleIdentifier: application.bundleIdentifier,
                                     teamIdentifier: application.teamIdentifier) else {
            showError(String(localized: "This app’s signed update configuration could not be verified. Open the app to use its own updater.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            return
        }
        // Don't compete with a running target's built-in updater or terminate user work.
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.resolvingSymlinksInPath() == configuration.bundleURL.resolvingSymlinksInPath()
        }) else {
            showError(String(localized: "Quit the app before updating it here, then try again. You can also use its own updater.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            return
        }
        let newSession = DirectUpdateSession(bundle: bundle, configuration: configuration)
        newSession.finished = { [weak self] in
            guard let self else { return }
            self.session = nil
            // Keep the busy lock until the installation and its source have been rechecked.
            Task { @MainActor in
                await refresh()
                self.activeApplicationID = nil
            }
        }
        session = newSession
        activeApplicationID = application.id
        do {
            try newSession.updater.start()
            newSession.updater.checkForUpdates()
        } catch {
            session = nil
            activeApplicationID = nil
            showError(error.localizedDescription)
        }
    }

    private func requestManagerUpdate(_ application: InstalledApplication, action: ManagerUpdatePolicy.Action,
                                      refresh: @escaping @MainActor () async -> Void) {
        let confirmation = NSAlert()
        confirmation.messageText = application.name
        confirmation.informativeText = action == .homebrewConfirmation
            ? String(localized: "Homebrew will update only this package and required dependencies. It may run installer scripts or request macOS authorization. Quit the app first. Continue?", bundle: AppL10n.bundle, locale: AppL10n.locale)
            : String(localized: "Microsoft AutoUpdate will check and install updates for this app using its configured channel. It may request macOS authorization. Quit the app first; it will not be force-closed. Continue?", bundle: AppL10n.bundle, locale: AppL10n.locale)
        confirmation.addButton(withTitle: String(localized: "Update", bundle: AppL10n.bundle, locale: AppL10n.locale))
        confirmation.addButton(withTitle: String(localized: "Cancel", bundle: AppL10n.bundle, locale: AppL10n.locale))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        guard Self.validateManagerTarget(application, action: action) else {
            showError(String(localized: "The app or manager could not be verified, or the app is still running. Quit it and scan again.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            return
        }
        activeApplicationID = application.id
        let outputSession = UUID()
        outputSessionID = outputSession
        managerOutput = ""
        managerApplicationID = application.id
        managerStatus = String(localized: "Preparing update…", bundle: AppL10n.bundle, locale: AppL10n.locale)
        managerTask = Task {
            managerStatus = String(localized: "Updating with the package manager…", bundle: AppL10n.bundle, locale: AppL10n.locale)
            let owner = self
            let result = await Task.detached(priority: .userInitiated) { [owner] in
                Result {
                    try ManagerUpdateExecutor.execute(application, action: action, run: { command, timeout in
                        try PackageCommandRunner.run(executable: command.executable, arguments: command.arguments,
                            timeout: timeout, control: ScanControl(timeout: timeout), maximumOutputBytes: 16 * 1024 * 1024,
                            environmentOverrides: command.environment, mergeStandardError: command.arguments.first != "info", outputReceived: { data in
                                let output = String(decoding: data, as: UTF8.self)
                                Task { @MainActor [owner] in
                                    guard owner.outputSessionID == outputSession else { return }
                                    owner.managerOutput = String((owner.managerOutput + output).suffix(4000))
                                }
                            })
                    }, validate: { Self.validateManagerTarget(application, action: action) }, installedVersion: {
                        Self.bundleVersion(at: application.path)
                    }, installedBuild: { Self.bundleBuild(at: application.path) })
                }
            }.value
            managerStatus = nil
            // The installer has returned. Retain the busy lock during the one-item refresh.
            await refresh()
            activeApplicationID = nil
            managerTask = nil
            switch result {
            case .success(.verified): showError(String(localized: "The installed version changed successfully.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            case .success(.unchanged): showError(String(localized: "The manager reports no update for this item.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            case .success(.submitted): showError(String(localized: "The manager returned, but installation is not yet verified. It may still be pending in the manager. Review its output and scan again.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            case .failure(let error): showError(error.localizedDescription + "\n\n" + String(localized: "Installation may be incomplete or still running in the manager. Review its output and scan again.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            }
        }
    }

    nonisolated private static func bundleVersion(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
    }

    nonisolated private static func bundleBuild(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return info["CFBundleVersion"] as? String
    }

    nonisolated private static func validateManagerTarget(_ application: InstalledApplication,
                                                          action: ManagerUpdatePolicy.Action) -> Bool {
        guard ManagerUpdatePolicy.action(for: application) == action else { return false }
        if application.path.hasSuffix(".app") {
            let url = URL(fileURLWithPath: application.path)
            guard Bundle(url: url)?.bundleIdentifier == application.bundleIdentifier,
                  Self.bundleBuild(at: application.path) == application.buildVersion,
                  !NSWorkspace.shared.runningApplications.contains(where: {
                      $0.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                  }) else { return false }
        }
        if action == .microsoftAutoUpdateConfirmation {
            let updater = URL(fileURLWithPath: ManagerUpdatePolicy.microsoftUpdaterPath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return hasValidSignature(updater, bundleIdentifier: "com.microsoft.autoupdate2", teamIdentifier: "UBF8T346G9")
                && hasValidSignature(URL(fileURLWithPath: application.path),
                                     bundleIdentifier: application.bundleIdentifier, teamIdentifier: "UBF8T346G9")
                && URL(fileURLWithPath: ManagerUpdatePolicy.microsoftUpdaterPath).resolvingSymlinksInPath().path
                    .hasPrefix(updater.resolvingSymlinksInPath().path + "/Contents/MacOS/")
        }
        return action == .homebrewConfirmation
    }

    nonisolated static func hasValidSignature(_ url: URL, bundleIdentifier: String, teamIdentifier: String?) -> Bool {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return false }
        // Fail closed if the installation was replaced/re-signed since its inventory scan.
        return info[kSecCodeInfoIdentifier as String] as? String == bundleIdentifier
            && info[kSecCodeInfoTeamIdentifier as String] as? String == teamIdentifier
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Update Application", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK", bundle: AppL10n.bundle, locale: AppL10n.locale))
        alert.runModal()
    }
}

/// Override runtime getters instead of changing another app's persisted Sparkle settings.
@MainActor
final class ManualSparkleUpdater: SPUUpdater {
    override var automaticallyChecksForUpdates: Bool { get { false } set {} }
    override var automaticallyDownloadsUpdates: Bool { get { false } set {} }
    override var allowsAutomaticUpdates: Bool { false }
    override var sendsSystemProfile: Bool { get { false } set {} }
}

@MainActor
private final class DirectUpdateSession: NSObject, SPUUpdaterDelegate {
    let configuration: DirectUpdatePolicy.Configuration
    private let bundle: Bundle
    private let driver: SPUStandardUserDriver
    private(set) var updater: ManualSparkleUpdater!
    var finished: (() -> Void)?

    init(bundle: Bundle, configuration: DirectUpdatePolicy.Configuration) {
        self.bundle = bundle
        self.configuration = configuration
        driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        super.init()
        // The target, not Update Atlas, is the application Sparkle may relaunch.
        updater = ManualSparkleUpdater(hostBundle: bundle, applicationBundle: bundle,
                                       userDriver: driver, delegate: self)
    }

    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL.absoluteString }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else {
            throw NSError(domain: "UpdateAtlas.DirectUpdate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "Updates must be started by you.", bundle: AppL10n.bundle, locale: AppL10n.locale)])
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard DirectUpdatePolicy.allowsRelease(downloadURL: item.fileURL, installationType: item.installationType,
            version: item.displayVersionString, channel: item.channel, informationOnly: item.isInformationOnlyUpdate) else {
            throw NSError(domain: "UpdateAtlas.DirectUpdate", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "This release cannot be installed here. Use the app’s own updater.", bundle: AppL10n.bundle, locale: AppL10n.locale)])
        }
        // Sparkle validates the archive against the target's embedded EdDSA key and
        // performs its own version/compatibility/code-signing checks before installation.
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        // Leave Sparkle's callback stack before releasing its updater and driver.
        Task { @MainActor [weak self] in self?.finished?() }
    }
}
