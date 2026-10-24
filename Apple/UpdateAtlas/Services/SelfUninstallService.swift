import AppKit
import Foundation

@MainActor
final class SelfUninstallService {
    static let shared = SelfUninstallService()

    private let bundleID = AppIdentity.bundleIdentifier
    private(set) var isUninstalling = false
    private(set) var hasMovedAppToTrash = false

    private init() {}

    func requestUninstall() {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.bundleURL.pathExtension == "app" else {
            showError(String(localized: "Update Atlas could not verify its own app bundle.", bundle: AppL10n.bundle, locale: AppL10n.locale))
            return
        }

        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let dataURLs = ownedDataURLs()
        let hasCLI = CLIInstallationService.isOwnedLink(for: appURL)
        let alert = NSAlert()
        alert.messageText = String(localized: "Uninstall Update Atlas?", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.informativeText = String(localized: "The app and the listed local data will move to the Trash. Empty the Trash to delete them permanently.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.alertStyle = .warning
        let checkboxHeight = CGFloat(hasCLI ? 40 : 0)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 196 + checkboxHeight))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: checkboxHeight, width: 520, height: 196))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let paths = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 196))
        paths.isEditable = false
        paths.isSelectable = true
        paths.drawsBackground = false
        paths.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        paths.textContainer?.widthTracksTextView = true
        paths.isHorizontallyResizable = false
        paths.isVerticallyResizable = true
        paths.maxSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        var lines = [String(localized: "Application", bundle: AppL10n.bundle, locale: AppL10n.locale), "  \(displayPath(appURL))", ""]
        if !dataURLs.isEmpty {
            lines.append(String(localized: "Local data", bundle: AppL10n.bundle, locale: AppL10n.locale))
            lines.append(contentsOf: dataURLs.map { "  \(displayPath($0))" })
            lines.append("")
        }
        if hasCLI {
            lines.append(String(localized: "CLI: ~/.local/bin/update-atlas", bundle: AppL10n.bundle, locale: AppL10n.locale))
        }
        paths.string = lines.joined(separator: "\n")
        scroll.documentView = paths
        accessory.addSubview(scroll)
        let removeCLI = NSButton(checkboxWithTitle: String(localized: "Also remove the command line tool", bundle: AppL10n.bundle, locale: AppL10n.locale), target: nil, action: nil)
        removeCLI.frame = NSRect(x: 0, y: 0, width: 500, height: 30)
        removeCLI.state = .on
        if hasCLI { accessory.addSubview(removeCLI) }
        alert.accessoryView = accessory
        alert.addButton(withTitle: String(localized: "Cancel", bundle: AppL10n.bundle, locale: AppL10n.locale))
        alert.addButton(withTitle: String(localized: "Move to Trash", bundle: AppL10n.bundle, locale: AppL10n.locale))
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let shouldRemoveCLI = hasCLI && removeCLI.state == .on
        isUninstalling = true

        Task {
            await performConfirmedUninstall(
                prepare: {
                    if LaunchAtLoginService.shared.isEnabled {
                        // A macOS Login Items failure must not keep a confirmed uninstall open.
                        try? LaunchAtLoginService.shared.setEnabled(false)
                    }
                    if hasCLI {
                        if shouldRemoveCLI {
                            try CLIInstallationService.removeOwnedLink(for: appURL)
                        } else {
                            try CLIInstallationService.retainOwnedCLI(for: appURL)
                        }
                    }
                },
                moveApp: { try await recycle([appURL]) },
                finish: {
                    if !dataURLs.isEmpty {
                        try await recycle(dataURLs)
                    }
                    // Clearing the onboarding key while the window is still alive must not
                    // present first-run setup before the application terminates.
                    UserDefaults.standard.removePersistentDomain(forName: bundleID)
                },
                onError: { error in
                    showError(String(
                        format: String(localized: "Uninstall was incomplete. Check the Trash and these locations before trying again:\n%@\n\nError: %@", bundle: AppL10n.bundle, locale: AppL10n.locale),
                        ([appURL] + dataURLs).map { displayPath($0) }.joined(separator: "\n"),
                        error.localizedDescription
                    ))
                },
                terminate: { NSApplication.shared.terminate(nil) }
            )
        }
    }

    /// Once the app itself reaches the Trash, later cleanup errors may be reported but
    /// cannot leave its still-running process and menu bar item behind.
    func performConfirmedUninstall(
        prepare: () throws -> Void,
        moveApp: () async throws -> Void,
        finish: () async throws -> Void,
        onError: (Error) -> Void,
        terminate: () -> Void
    ) async {
        hasMovedAppToTrash = false
        do {
            try prepare()
            try await moveApp()
            hasMovedAppToTrash = true
        } catch {
            isUninstalling = false
            onError(error)
            return
        }

        do {
            try await finish()
        } catch {
            onError(error)
        }
        terminate()
    }

    func displayPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// Only paths owned by this app. Never touch generic Library or another manager's data.
    func ownedDataURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let paths = [
            "Application Support/UpdateAtlas",
            "Caches/\(bundleID)",
            "HTTPStorages/\(bundleID)",
            "Saved Application State/\(bundleID).savedState",
            "Preferences/\(bundleID).plist"
        ]
        return paths.map { library.appendingPathComponent($0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func recycle(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urls) { recycled, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if recycled.count != urls.count {
                    continuation.resume(throwing: NSError(
                        domain: "UpdateAtlasUninstall",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "Some files were not moved to the Trash.", bundle: AppL10n.bundle, locale: AppL10n.locale)]
                    ))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not finish uninstalling Update Atlas", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "OK", bundle: AppL10n.bundle, locale: AppL10n.locale))
        alert.runModal()
    }
}
