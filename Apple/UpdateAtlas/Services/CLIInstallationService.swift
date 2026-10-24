import AppKit
import Darwin
import Foundation

@MainActor
final class CLIInstallationService {
    static let shared = CLIInstallationService()
    static let stateDidChange = Notification.Name("UpdateAtlasCLIInstallationStateDidChange")
    private init() {}

    enum InstallationState: Equatable {
        case notInstalled
        case installedAndCurrent(String)
        case installedNeedsRepair(String)
        case conflictWithOtherFile(String)

        var isInstalled: Bool {
            if case .installedAndCurrent = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .notInstalled:
                String(localized: "Not Installed", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .installedAndCurrent:
                String(localized: "Installed & Linked", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .installedNeedsRepair:
                String(localized: "Link Points to Another Location", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .conflictWithOtherFile:
                String(localized: "Existing File at ~/.local/bin/update-atlas", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }
    }

    var bundledTool: URL? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers/update-atlas")
    }

    static func installedLink(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/update-atlas")
    }

    func currentState(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstallationState {
        Self.installationState(home: home, bundledTool: bundledTool)
    }

    static func installationState(home: URL, bundledTool: URL?) -> InstallationState {
        let link = Self.installedLink(home: home)
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if let bundledTool,
               URL(fileURLWithPath: destination).standardizedFileURL == bundledTool.standardizedFileURL,
               manager.isExecutableFile(atPath: bundledTool.path) {
                return .installedAndCurrent(destination)
            }
            return .installedNeedsRepair(destination)
        }
        if manager.fileExists(atPath: link.path) {
            return .conflictWithOtherFile(link.path)
        }
        return .notInstalled
    }

    var isLocalBinInPATH: Bool {
        Self.isLocalBinInPATH(
            ProcessInfo.processInfo.environment["PATH"] ?? "",
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func isLocalBinInPATH(_ pathEnv: String, home: URL) -> Bool {
        let homeBin = home.appendingPathComponent(".local/bin").standardizedFileURL.path
        return pathEnv.split(separator: ":").contains { entry in
            let component = String(entry)
            let expanded = component.hasPrefix("~/")
                ? home.path + String(component.dropFirst())
                : component
            return URL(fileURLWithPath: expanded).standardizedFileURL.path == homeBin
        }
    }

    /// Only an explicit Install action in onboarding, Settings or the CLI window calls this mutation.
    func installConfirmed(showsSuccessAlert: Bool = true) {
        guard let tool = bundledTool, FileManager.default.isExecutableFile(atPath: tool.path) else {
            show(String(localized: "The bundled Update Atlas CLI could not be found. Install a build that includes the CLI.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .warning)
            return
        }
        let link = Self.installedLink()
        let manager = FileManager.default
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if URL(fileURLWithPath: existing).standardizedFileURL == tool.standardizedFileURL {
                show(String(localized: "The Update Atlas CLI is already installed at ~/.local/bin/update-atlas.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .informational)
            } else {
                show(String(localized: "~/.local/bin/update-atlas already points to another tool. Update Atlas will not replace it unless you choose Repair Link.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .warning)
            }
            return
        }
        guard !manager.fileExists(atPath: link.path) else {
            show(String(localized: "~/.local/bin/update-atlas already exists. Update Atlas will not overwrite it.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .warning)
            return
        }
        do {
            try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: tool)
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            if showsSuccessAlert {
                show(String(localized: "Installed at ~/.local/bin/update-atlas. If your shell cannot find it, add ~/.local/bin to PATH. The link follows this app when it is replaced at the same location.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .informational)
            }
        } catch {
            show(String(localized: "Could not install the CLI:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)", style: .warning)
        }
    }

    func repairLinkConfirmed() {
        guard let tool = bundledTool, FileManager.default.isExecutableFile(atPath: tool.path) else {
            show(String(localized: "The bundled Update Atlas CLI could not be found. Install a build that includes the CLI.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .warning)
            return
        }
        let link = Self.installedLink()
        let manager = FileManager.default
        do {
            if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                try manager.removeItem(at: link)
            }
            try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: tool)
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            show(String(localized: "Updated the ~/.local/bin/update-atlas symlink to point to this application bundle.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .informational)
        } catch {
            show(String(localized: "Could not repair the CLI link:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)", style: .warning)
        }
    }

    func uninstallConfirmed() {
        let link = Self.installedLink()
        let manager = FileManager.default
        guard case .installedAndCurrent = currentState() else {
            show(String(localized: "No Update Atlas CLI symlink was found at ~/.local/bin/update-atlas.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .informational)
            return
        }
        do {
            try manager.removeItem(at: link)
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            show(String(localized: "Removed ~/.local/bin/update-atlas.", bundle: AppL10n.bundle, locale: AppL10n.locale), style: .informational)
        } catch {
            show(String(localized: "Could not remove the CLI link:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(error.localizedDescription)", style: .warning)
        }
    }

    static func removeOwnedLink(
        for appURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        let link = installedLink(home: home)
        let expected = appURL.appendingPathComponent("Contents/MacOS/Helpers/update-atlas")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
              URL(fileURLWithPath: destination).standardizedFileURL == expected.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: link)
    }

    static func isOwnedLink(
        for appURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let expected = appURL.appendingPathComponent("Contents/MacOS/Helpers/update-atlas")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: installedLink(home: home).path
        ) else { return false }
        return URL(fileURLWithPath: destination).standardizedFileURL == expected.standardizedFileURL
    }

    /// Keeps the signed helper usable after the app bundle is recycled. The catalog and
    /// version metadata are copied with it; a symlink to the removed app would be broken.
    static func retainOwnedCLI(
        for appURL: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isOwnedLink(for: appURL, home: home) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manager = FileManager.default
        let tool = appURL.appendingPathComponent("Contents/MacOS/Helpers/update-atlas")
        let catalog = appURL.appendingPathComponent("Contents/Resources/BootstrapCatalog.json")
        let info = appURL.appendingPathComponent("Contents/Info.plist")
        guard manager.isExecutableFile(atPath: tool.path),
              manager.fileExists(atPath: catalog.path),
              manager.fileExists(atPath: info.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let parent = home.appendingPathComponent(".local/share/update-atlas-cli", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let retained = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: retained, withIntermediateDirectories: false)
        let link = installedLink(home: home)
        let replacement = link.deletingLastPathComponent()
            .appendingPathComponent(".update-atlas-uninstall-\(UUID().uuidString)")
        do {
            let retainedTool = retained.appendingPathComponent("update-atlas")
            try manager.copyItem(at: tool, to: retainedTool)
            try manager.copyItem(at: catalog, to: retained.appendingPathComponent("BootstrapCatalog.json"))
            try manager.copyItem(at: info, to: retained.appendingPathComponent("Info.plist"))
            guard manager.isExecutableFile(atPath: retainedTool.path),
                  isOwnedLink(for: appURL, home: home) else {
                throw CocoaError(.fileReadNoPermission)
            }
            try manager.createSymbolicLink(at: replacement, withDestinationURL: retainedTool)
            guard rename(replacement.path, link.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? manager.removeItem(at: replacement)
            try? manager.removeItem(at: retained)
            throw error
        }
    }

    private func show(_ message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Update Atlas CLI", bundle: AppL10n.bundle, locale: AppL10n.locale)
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: String(localized: "OK", bundle: AppL10n.bundle, locale: AppL10n.locale))
        alert.runModal()
    }
}
