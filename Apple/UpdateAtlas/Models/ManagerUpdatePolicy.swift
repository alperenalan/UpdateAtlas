import Foundation

/// Compiled manager actions; catalog data can never supply commands or flags.
enum ManagerUpdatePolicy {
    enum Action: String, Sendable {
        case sparkleConfirmation, homebrewConfirmation, microsoftAutoUpdateConfirmation, appStorePage
    }
    struct Command: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }
    static let microsoftUpdaterPath = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
    // Reviewed MAU identifiers. Teams and Edge are deliberately absent.
    static let microsoftApps: [String: (id: String, name: String)] = [
        "com.microsoft.Word": ("MSWD2019", "Microsoft Word"),
        "com.microsoft.Excel": ("XCEL2019", "Microsoft Excel"),
        "com.microsoft.Powerpoint": ("PPT32019", "Microsoft PowerPoint"),
        "com.microsoft.Outlook": ("OPIM2019", "Microsoft Outlook"),
        "com.microsoft.onenote.mac": ("ONMC2019", "Microsoft OneNote"),
        "com.microsoft.OneDrive": ("ONDR18", "OneDrive")
    ]

    static func action(for item: InstalledApplication,
                       executableExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Action? {
        if item.mechanism == .appStore { return .appStorePage }
        if DirectUpdatePolicy.configuration(for: item) != nil { return .sparkleConfirmation }
        guard item.bundleIdentifier != AppIdentity.bundleIdentifier, item.releaseChannel.kind == .stable,
              !hasStoreReceipt(at: item.path) else { return nil }
        if let provenance = item.packageProvenance,
           [.homebrewCask, .homebrewFormula].contains(provenance.manager),
           item.updateCheck.availability == .updateAvailable,
           validToken(provenance.identifier), validBrewPath(provenance.managerExecutablePath),
           executableExists(provenance.managerExecutablePath) { return .homebrewConfirmation }
        if item.kind == .application, item.mechanism == .externalManager,
           item.parentManagerBundleIdentifier == "com.microsoft.autoupdate2", item.parentInventoryID == nil,
           item.packageProvenance == nil, item.teamIdentifier == "UBF8T346G9",
           let app = microsoftApps[item.bundleIdentifier], item.path == "/Applications/" + app.name + ".app",
           executableExists(microsoftUpdaterPath) { return .microsoftAutoUpdateConfirmation }
        return nil
    }

    static func offersInlineUpdate(for item: InstalledApplication,
                                   executableExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Bool {
        guard item.updateCheck.availability == .updateAvailable,
              let action = action(for: item, executableExists: executableExists) else { return false }
        return action != .appStorePage
    }

    static func offersInlineAppStore(for item: InstalledApplication) -> Bool {
        item.mechanism == .appStore && item.updateCheck.availability == .updateAvailable
    }

    static func hasStoreReceipt(at path: String) -> Bool {
        ["/Contents/_MASReceipt/receipt", "/WrappedBundle/_MASReceipt/receipt", "/Wrapper/iTunesMetadata.plist"]
            .contains { FileManager.default.fileExists(atPath: path + $0) }
    }

    static func validToken(_ value: String) -> Bool {
        // Tokens, including fully qualified taps, are operands, never paths/URLs/options.
        value.range(of: "^[a-z0-9][a-z0-9+._-]*(/[a-z0-9][a-z0-9+._-]*){0,2}$", options: .regularExpression) != nil
            && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    static func validBrewPath(_ value: String) -> Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains(value)
    }
    static let brewEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1", "HOMEBREW_NO_ANALYTICS": "1"
    ]
    static func brewInfo(_ provenance: PackageProvenance) -> Command {
        Command(executable: provenance.managerExecutablePath,
                arguments: ["info", "--json=v2", provenance.manager == .homebrewCask ? "--cask" : "--formula", provenance.identifier],
                environment: brewEnvironment)
    }
    static func installCommand(for item: InstalledApplication, action: Action) -> Command? {
        switch action {
        case .homebrewConfirmation:
            guard let p = item.packageProvenance, [.homebrewCask, .homebrewFormula].contains(p.manager),
                  validToken(p.identifier), validBrewPath(p.managerExecutablePath) else { return nil }
            var arguments = ["upgrade", p.manager == .homebrewCask ? "--cask" : "--formula"]
            if p.manager == .homebrewCask { arguments += ["--no-quit", "--require-sha", "--greedy-auto-updates"] }
            arguments.append(p.identifier)
            // The app's explicit confirmation replaces brew's interactive stdin prompt.
            return Command(executable: p.managerExecutablePath, arguments: arguments,
                           environment: brewEnvironment.merging(["HOMEBREW_NO_ASK": "1"]) { _, new in new })
        case .microsoftAutoUpdateConfirmation:
            guard let app = microsoftApps[item.bundleIdentifier] else { return nil }
            // No --terminate: the manager must never force-close user work.
            return Command(executable: microsoftUpdaterPath,
                           arguments: ["--install", "--apps", app.id, "--wait", "600"], environment: [:])
        default: return nil
        }
    }
}

enum AppStoreDestination {
    static func validatedPage(_ url: URL?) -> URL? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "apps.apple.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.split(separator: "/").contains(where: {
                  $0.range(of: "^id[0-9]+$", options: .regularExpression) != nil
              }) else { return nil }
        return url
    }
}
