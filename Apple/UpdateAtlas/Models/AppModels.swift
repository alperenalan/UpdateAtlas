import Foundation

enum GroupingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case mechanismStatus = "status"
    case updateMechanism = "updateSource"

    static let defaultsKey = "inventory.grouping-mode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mechanismStatus: String(localized: "Mechanism Status", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateMechanism: String(localized: "Update Mechanism", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var explanation: String {
        switch self {
        case .mechanismStatus:
            String(localized: "Mechanism Status groups apps by whether their update owner is supported, external, or unresolved.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateMechanism:
            String(localized: "Update Mechanism groups apps by who delivers their updates, such as App Store, Sparkle, or a manager.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

enum DefaultInventoryView: String, CaseIterable, Identifiable, Sendable {
    case updateAvailable = "update.updateAvailable"
    case upToDate = "update.upToDate"
    case allInOne = "scope.allInOne"
    case applications = "scope.applications"
    case directUpdateCapable = "scope.directUpdateCapable"
    case commandLineTools = "scope.commandLineTools"
    case virtualMachinesAndBottles = "scope.virtualMachinesAndBottles"
    case games = "scope.games"
    case packageManagers = "scope.packageManagers"
    case containers = "scope.containers"

    var id: String { rawValue }
    var filterID: String { rawValue }

    var title: String {
        switch self {
        case .updateAvailable: String(localized: "Update Available", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .upToDate: String(localized: "Up to Date", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .allInOne: String(localized: "All Software", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .applications: String(localized: "Applications", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .directUpdateCapable: String(localized: "Auto-Update & Direct", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .commandLineTools: String(localized: "Command-line Tools", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .virtualMachinesAndBottles: String(localized: "VMs & Windows Bottles", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .games: String(localized: "Games & Game Clients", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .packageManagers: String(localized: "Package Managers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .containers: String(localized: "Containers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

enum InventoryItemKind: String, Codable, Sendable {
    case application
    case game
    case managedComponent
    case `extension`
    case module
    case runtime
    case modLoader
    case mod
    case shaderPack
    case resourcePack
    case helper
    case commandLineTool
    case package
    case containerContext, composeProject, container, containerImage, containerVolume, wineBottle, virtualMachine

    var title: String {
        switch self {
        case .application: String(localized: "Application", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .game: String(localized: "Game", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .managedComponent: String(localized: "Managed Component", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .extension: String(localized: "Extension", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .module: String(localized: "Extra Module", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .runtime: String(localized: "Runtime", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .modLoader: String(localized: "Mod Loader", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .mod: String(localized: "Mod", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .shaderPack: String(localized: "Shader Pack", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .resourcePack: String(localized: "Resource Pack", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .helper: String(localized: "Application Helper", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .commandLineTool: String(localized: "Command-line Tool", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .package: String(localized: "Package", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .containerContext: String(localized: "Container Connection", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .composeProject: String(localized: "Compose Project", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .container: String(localized: "Container", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .containerImage: String(localized: "Container Image", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .containerVolume: String(localized: "Container Volume", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .wineBottle: String(localized: "Wine Bottle", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .virtualMachine: String(localized: "Virtual Machine", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .application: "app.fill"
        case .game: "gamecontroller.fill"
        case .managedComponent: "shippingbox.and.arrow.backward.fill"
        case .extension: "puzzlepiece.extension.fill"
        case .module: "square.stack.3d.up.fill"
        case .runtime: "memorychip.fill"
        case .modLoader: "gearshape.2.fill"
        case .mod: "puzzlepiece.fill"
        case .shaderPack: "sun.max.fill"
        case .resourcePack: "square.stack.3d.up.fill"
        case .helper: "link.badge.plus"
        case .commandLineTool: "terminal.fill"
        case .package: "shippingbox.fill"
        case .containerContext: "network"
        case .composeProject: "square.stack.3d.up.fill"
        case .container: "shippingbox.fill"
        case .containerImage: "cube.fill"
        case .containerVolume: "externaldrive.fill"
        case .wineBottle: "wineglass.fill"
        case .virtualMachine: "desktopcomputer"
        }
    }
}

enum InventoryColumn: String, CaseIterable, Identifiable, Sendable {
    case name
    case installedVersion
    case type
    case parent
    case updateMechanism
    case mechanismStatus
    case openSource
    case updateStatus

    static let defaultsKey = "inventory.visible-columns"
    static let widthDefaultsKey = "inventory.column-widths"
    static let required: Set<InventoryColumn> = [.name, .installedVersion, .updateStatus]
    static let defaults: Set<InventoryColumn> = [
        .name, .installedVersion, .updateMechanism, .mechanismStatus, .updateStatus
    ]

    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: String(localized: "Name", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .installedVersion: String(localized: "Installed Version", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .type: String(localized: "Type", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .parent: String(localized: "Managed By", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateMechanism: String(localized: "Update Mechanism", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .mechanismStatus: String(localized: "Mechanism Status", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .openSource: String(localized: "Open Source", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateStatus: String(localized: "Update Status", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
    var isRequired: Bool { Self.required.contains(self) }

    var defaultWidth: CGFloat {
        switch self {
        case .name: 280
        case .installedVersion: 120
        case .type: 120
        case .parent: 135
        case .updateMechanism: 145
        case .mechanismStatus: 140
        case .openSource: 105
        case .updateStatus: 155
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .name: 240
        case .installedVersion, .type, .openSource: 90
        case .parent, .updateMechanism, .mechanismStatus, .updateStatus: 110
        }
    }
}

enum InventoryScope: String, CaseIterable, Identifiable, Sendable {
    case allInOne
    case applications
    case directUpdateCapable
    case commandLineTools
    case virtualMachinesAndBottles
    case games
    case packageManagers
    case containers

    var id: String { "scope.\(rawValue)" }

    var title: String {
        switch self {
        case .allInOne: String(localized: "All Software", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .applications: String(localized: "Applications", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .directUpdateCapable: String(localized: "Auto-Update & Direct", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .commandLineTools: String(localized: "Command-line Tools", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .virtualMachinesAndBottles: String(localized: "VMs & Windows Bottles", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .games: String(localized: "Games & Game Clients", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .packageManagers: String(localized: "Package Managers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .containers: String(localized: "Containers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .allInOne: "square.grid.3x3.fill"
        case .applications: "macwindow"
        case .directUpdateCapable: "bolt.badge.checkmark.fill"
        case .commandLineTools: "terminal.fill"
        case .virtualMachinesAndBottles: "desktopcomputer.and.arrow.down"
        case .games: "gamecontroller.fill"
        case .packageManagers: "shippingbox.fill"
        case .containers: "cube.transparent.fill"
        }
    }

    func includes(_ application: InstalledApplication) -> Bool {
        switch self {
        case .allInOne:
            true
        case .applications:
            (application.kind == .application
                || application.kind == .managedComponent
                || application.kind == .extension
                || application.kind == .module
                || application.kind == .runtime
                || application.kind == .wineBottle
                || application.kind == .virtualMachine
                || application.kind == .modLoader
                || application.kind == .mod
                || application.kind == .shaderPack
                || application.kind == .resourcePack
                || application.kind == .helper)
                && application.packageProvenance == nil
                && !application.isGameRelated
        case .directUpdateCapable:
            application.supportsAutoOrDirectUpdate && !application.isSystemPythonPackage
        case .commandLineTools:
            application.kind == .commandLineTool && application.packageProvenance == nil
        case .virtualMachinesAndBottles:
            application.isVirtualMachineOrBottleRelated
        case .games:
            application.isGameRelated && application.packageProvenance == nil
        case .packageManagers:
            application.packageProvenance != nil
        case .containers:
            application.discovery?.source == "Docker"
        }
    }
}

enum GamePlatformKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case steam
    case gog
    case epic
    case heroic
    case battleNet
    case eaApp
    case riot
    case itch
    case modrinth
    case curseForge
    case retroArch
    case standalone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steam: "Steam"
        case .gog: "GOG"
        case .epic: "Epic Games"
        case .heroic: "Heroic"
        case .battleNet: "Battle.net"
        case .eaApp: "EA App"
        case .riot: "Riot Client"
        case .itch: "itch.io"
        case .modrinth: "Modrinth"
        case .curseForge: "CurseForge"
        case .retroArch: String(localized: "Emulators & RetroArch", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .standalone: String(localized: "Standalone / App Store", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .steam: "gamecontroller.fill"
        case .gog: "sparkles"
        case .epic: "bolt.fill"
        case .heroic: "gamecontroller.fill"
        case .battleNet: "shield.Lefthalf.filled"
        case .eaApp: "sportscourt.fill"
        case .riot: "flame.fill"
        case .itch: "bag.fill"
        case .modrinth: "cube.box.fill"
        case .curseForge: "hammer.fill"
        case .retroArch: "arcade.stick.console.fill"
        case .standalone: "macwindow"
        }
    }

    var managerBundleIdentifier: String? {
        switch self {
        case .steam: "com.valvesoftware.steam"
        case .gog: "com.gog.galaxy"
        case .epic: "com.epicgames.EpicGamesLauncher"
        case .heroic: "com.heroicgameslauncher.hgl"
        case .battleNet: "net.battle.app"
        case .eaApp: "com.ea.mac.eaapp"
        case .riot: "com.riotgames.RiotGames.RiotClient"
        case .itch: "io.itch.mac"
        case .modrinth: "com.modrinth.theseus"
        case .curseForge: "com.overwolf.curseforge"
        case .retroArch: "com.libretro.RetroArch"
        case .standalone: nil
        }
    }

    func includes(_ application: InstalledApplication) -> Bool {
        if application.gamePlatform == self { return true }
        if let managerBundleIdentifier, application.parentManagerBundleIdentifier == managerBundleIdentifier {
            return true
        }
        return false
    }
}

enum PackageManagerKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case homebrewCask
    case homebrewFormula
    case npm
    case pythonPip
    case pipx
    case uvTool
    case cargo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrewCask: String(localized: "Homebrew Cask", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .homebrewFormula: String(localized: "Homebrew Formula", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .npm: String(localized: "npm (global)", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .pythonPip: String(localized: "Python / pip", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .pipx: "pipx"
        case .uvTool: String(localized: "uv tool", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .cargo: "Cargo"
        }
    }

    var mechanism: UpdateMechanismKind {
        switch self {
        case .homebrewCask, .homebrewFormula: .homebrew
        case .npm: .npm
        case .pythonPip: .python
        case .pipx: .pipx
        case .uvTool: .uvTool
        case .cargo: .cargo
        }
    }

    var symbolName: String {
        switch self {
        case .homebrewCask: "mug.fill"
        case .homebrewFormula: "mug.fill"
        case .npm: "shippingbox.fill"
        case .pythonPip: "curlybraces.square.fill"
        case .pipx, .uvTool: "curlybraces.square.fill"
        case .cargo: "shippingbox.fill"
        }
    }

    func includes(_ application: InstalledApplication) -> Bool {
        application.packageProvenance?.manager == self
    }
}

struct PackageProvenance: Hashable, Codable, Sendable {
    let identifier: String
    let manager: PackageManagerKind
    let managerExecutablePath: String
    let installLocation: String?
    let explicitlyInstalled: Bool
    let homepage: URL?
    let summary: String?
    let isOutdated: Bool?
    let latestVersion: String?
    let installedVersion: String?

    init(
        identifier: String,
        manager: PackageManagerKind,
        managerExecutablePath: String,
        installLocation: String?,
        explicitlyInstalled: Bool,
        homepage: URL?,
        summary: String?,
        isOutdated: Bool?,
        latestVersion: String? = nil,
        installedVersion: String? = nil
    ) {
        self.identifier = identifier
        self.manager = manager
        self.managerExecutablePath = managerExecutablePath
        self.installLocation = installLocation
        self.explicitlyInstalled = explicitlyInstalled
        self.homepage = homepage
        self.summary = summary
        self.isOutdated = isOutdated
        self.latestVersion = latestVersion
        self.installedVersion = installedVersion
    }

    var environmentLabel: String? {
        let path = managerExecutablePath
        switch manager {
        case .pythonPip, .pipx, .uvTool:
            if path.contains("/.pyenv/") { return "pyenv" }
            if path.contains("miniconda") || path.contains("anaconda") || path.contains("miniforge") { return String(localized: "Conda Python", bundle: AppL10n.bundle, locale: AppL10n.locale) }
            if path.hasPrefix("/opt/homebrew/") { return String(localized: "Homebrew Python", bundle: AppL10n.bundle, locale: AppL10n.locale) }
            if path.hasPrefix("/usr/local/") { return String(localized: "Local Python", bundle: AppL10n.bundle, locale: AppL10n.locale) }
            if path.hasPrefix("/usr/bin/") || path.hasPrefix("/Library/Developer/") || path.hasPrefix("/System/") || path.contains("Xcode.app") {
                return String(localized: "System Python", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
            return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        case .npm:
            if path.contains("/.nvm/") { return "nvm" }
            if path.contains("/.local/") { return String(localized: "User npm", bundle: AppL10n.bundle, locale: AppL10n.locale) }
            return nil
        case .cargo, .homebrewCask, .homebrewFormula:
            return nil
        }
    }
}

enum UpdateSupportStatus: String, CaseIterable, Codable, Sendable {
    case supported
    case managedExternally
    case needsCatalog
    case unsupported
    case checkFailed

    var title: String {
        switch self {
        case .supported: String(localized: "Supported", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .managedExternally: String(localized: "Managed Externally", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .needsCatalog: String(localized: "Needs Catalog", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .unsupported: String(localized: "Unsupported", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .checkFailed: String(localized: "Check Failed", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .supported: "checkmark.circle.fill"
        case .managedExternally: "briefcase.fill"
        case .needsCatalog: "exclamationmark.circle.fill"
        case .unsupported: "questionmark.circle.fill"
        case .checkFailed: "exclamationmark.triangle.fill"
        }
    }
}

enum UpdateAvailability: String, CaseIterable, Codable, Sendable {
    case notChecked
    case checking
    case upToDate
    case updateAvailable
    case checkFailed
    case sourcePending
    case managedExternally
    case managedBySystem

    var title: String {
        switch self {
        case .notChecked: String(localized: "Not Checked", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .checking: String(localized: "Checking…", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .upToDate: String(localized: "Up to Date", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateAvailable: String(localized: "Update Available", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .checkFailed: String(localized: "Check Failed", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .sourcePending: String(localized: "Source Resolution Pending", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .managedExternally: String(localized: "Managed Externally", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .managedBySystem: String(localized: "Managed by macOS", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .notChecked: "minus.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .upToDate: "checkmark.circle.fill"
        case .updateAvailable: "arrow.down.circle.fill"
        case .checkFailed: "exclamationmark.triangle.fill"
        case .sourcePending: "books.vertical.fill"
        case .managedExternally: "briefcase.fill"
        case .managedBySystem: "apple.logo"
        }
    }
}

enum UpdateCheckSource: String, Codable, Sendable {
    case packageManager
    case sparkleAppcast
    case chromeVersionHistory
    case githubReleases
    case platformDownloads
    case steamManifest
    case githubCompare
    case electronManifest
    case visualStudioCode
    case blenderDownloads
    case homebrewCaskCatalog
    case androidStudioOfficial
    case canonSupport
    case appStore
    case jsonDocument
    case ideMarketplace
    case minecraftVersionManifest

    var title: String {
        switch self {
        case .packageManager: String(localized: "Package Manager", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .sparkleAppcast: String(localized: "Sparkle Appcast", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .chromeVersionHistory: String(localized: "Chrome Version History", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .githubReleases: String(localized: "GitHub Releases", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .platformDownloads: String(localized: "Official Platform Downloads", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .steamManifest: String(localized: "Steam Local Manifest", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .githubCompare: String(localized: "GitHub Commit Compare", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .electronManifest: String(localized: "Electron Release Manifest", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .visualStudioCode: String(localized: "Visual Studio Code Update Service", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .blenderDownloads: String(localized: "Blender Downloads", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .homebrewCaskCatalog: String(localized: "Homebrew Cask Catalog", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .androidStudioOfficial: String(localized: "Android Studio Official Releases", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .canonSupport: String(localized: "Canon Support", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .appStore: String(localized: "Mac App Store", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .jsonDocument: String(localized: "Vendor Release Document", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .ideMarketplace: String(localized: "IDE Extension Marketplace", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .minecraftVersionManifest: String(localized: "Minecraft Version Manifest", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

struct UpdateCheckResult: Hashable, Codable, Sendable {
    let availability: UpdateAvailability
    let installedVersion: String
    let latestVersion: String?
    let checkedAt: Date?
    let source: UpdateCheckSource?
    let detail: String
    let releaseNotesURL: URL?
    let releaseNotesSummary: String?
    let releaseChannel: ReleaseChannel?

    init(
        availability: UpdateAvailability,
        installedVersion: String,
        latestVersion: String?,
        checkedAt: Date?,
        source: UpdateCheckSource?,
        detail: String,
        releaseNotesURL: URL? = nil,
        releaseNotesSummary: String? = nil,
        releaseChannel: ReleaseChannel? = nil
    ) {
        self.availability = availability
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.checkedAt = checkedAt
        self.source = source
        self.detail = detail
        self.releaseNotesURL = releaseNotesURL
        self.releaseNotesSummary = releaseNotesSummary
        self.releaseChannel = releaseChannel
    }

    static func pending(installedVersion: String) -> UpdateCheckResult {
        UpdateCheckResult(
            availability: .notChecked,
            installedVersion: installedVersion,
            latestVersion: nil,
            checkedAt: nil,
            source: nil,
            detail: String(localized: "Waiting for an update provider check.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        )
    }

    static func sourcePending(installedVersion: String, detail: String) -> UpdateCheckResult {
        UpdateCheckResult(
            availability: .sourcePending,
            installedVersion: installedVersion,
            latestVersion: nil,
            checkedAt: nil,
            source: nil,
            detail: detail
        )
    }

    static func managedExternally(installedVersion: String, detail: String) -> UpdateCheckResult {
        UpdateCheckResult(
            availability: .managedExternally,
            installedVersion: installedVersion,
            latestVersion: nil,
            checkedAt: Date(),
            source: nil,
            detail: detail
        )
    }

    func withDetail(_ detail: String) -> UpdateCheckResult {
        UpdateCheckResult(
            availability: availability,
            installedVersion: installedVersion,
            latestVersion: latestVersion,
            checkedAt: checkedAt,
            source: source,
            detail: detail,
            releaseNotesURL: releaseNotesURL,
            releaseNotesSummary: releaseNotesSummary,
            releaseChannel: releaseChannel
        )
    }
}

enum UpdateMechanismKind: String, CaseIterable, Codable, Sendable {
    case sparkle
    case appStore
    case homebrew
    case npm
    case python
    case pipx
    case uvTool
    case cargo
    case googleUpdater
    case squirrel
    case githubReleases
    case ideExtension
    case externalManager
    case system
    case website
    case publisherCLIInstaller
    case unknown

    var title: String {
        switch self {
        case .sparkle: "Sparkle"
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .python: String(localized: "Python / pip", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .pipx: "pipx"
        case .uvTool: String(localized: "uv tool", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .cargo: "Cargo"
        case .googleUpdater: String(localized: "Google Updater", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .squirrel: String(localized: "Squirrel / Electron", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .githubReleases: String(localized: "GitHub Releases", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .ideExtension: String(localized: "IDE Extensions", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .externalManager: String(localized: "External Managers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .system: "macOS"
        case .website: String(localized: "Vendor Website", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .publisherCLIInstaller: String(localized: "Publisher CLI Installer", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .unknown: String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var explanation: String {
        switch self {
        case .sparkle: String(localized: "Sparkle checks a publisher’s appcast feed.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .appStore: String(localized: "The Mac App Store owns this app’s updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .homebrew: String(localized: "Homebrew tracks the installed formula or cask.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .npm: String(localized: "npm tracks this globally installed package.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .python: String(localized: "pip tracks this Python package.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .pipx: String(localized: "pipx owns this isolated Python tool.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .uvTool: String(localized: "uv owns this persistent Python tool.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .cargo: String(localized: "Cargo owns this installed Rust binary crate.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .googleUpdater: String(localized: "Google Updater delivers this app’s updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .squirrel: String(localized: "The app uses its built-in Electron updater.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .githubReleases: String(localized: "Published GitHub releases provide version information.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .ideExtension: String(localized: "The IDE manages this extension through its marketplace.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .externalManager: String(localized: "Another app or launcher owns this software’s updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .system: String(localized: "macOS Software Update manages this app.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .website: String(localized: "The publisher’s website provides the latest version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .publisherCLIInstaller: String(localized: "The publisher documents this standalone CLI path. Its update method may vary; Update Atlas does not run it.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .unknown: String(localized: "No reliable update owner has been identified yet.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .sparkle: "sparkles"
        case .appStore: "storefront.fill"
        case .homebrew: "shippingbox.fill"
        case .npm: "shippingbox.fill"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .pipx, .uvTool: "chevron.left.forwardslash.chevron.right"
        case .cargo: "shippingbox.fill"
        case .googleUpdater: "arrow.triangle.2.circlepath.circle.fill"
        case .squirrel: "bolt.horizontal.circle.fill"
        case .githubReleases: "arrow.triangle.branch"
        case .ideExtension: "puzzlepiece.extension.fill"
        case .externalManager: "briefcase.fill"
        case .system: "apple.logo"
        case .website: "globe"
        case .publisherCLIInstaller: "terminal.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

enum EvidenceLevel: String, Codable, Sendable {
    case confirmed
    case informational
    case warning
}

struct DetectionEvidence: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let detail: String
    let level: EvidenceLevel

    init(id: String = UUID().uuidString, title: String, detail: String, level: EvidenceLevel) {
        self.id = id
        self.title = title
        self.detail = detail
        self.level = level
    }
}

enum DetectionConfidence: Int, Codable, Comparable, Sendable {
    case low = 1
    case medium = 3
    case high = 4
    case verified = 5

    static func < (lhs: DetectionConfidence, rhs: DetectionConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .low: String(localized: "Low", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .medium: String(localized: "Medium", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .high: String(localized: "High", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .verified: String(localized: "Verified", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

struct ApplicationCandidate: Hashable, Sendable {
    let inventoryID: String
    let path: String
    let name: String
    let bundleIdentifier: String
    let displayVersion: String
    let buildVersion: String
    let teamIdentifier: String?
    let parentInventoryID: String?
    let parentManagerBundleIdentifier: String?
    let isSystemApplication: Bool
    let info: [String: String]
    let kind: InventoryItemKind
    let gamePlatform: GamePlatformKind?
    let packageProvenance: PackageProvenance?

    init(
        inventoryID: String? = nil,
        path: String,
        name: String,
        bundleIdentifier: String,
        displayVersion: String,
        buildVersion: String,
        teamIdentifier: String?,
        parentInventoryID: String? = nil,
        parentManagerBundleIdentifier: String?,
        isSystemApplication: Bool,
        info: [String: String],
        kind: InventoryItemKind = .application,
        gamePlatform: GamePlatformKind? = nil,
        packageProvenance: PackageProvenance? = nil
    ) {
        self.inventoryID = inventoryID ?? "application:\(path)"
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.displayVersion = displayVersion
        self.buildVersion = buildVersion
        self.teamIdentifier = teamIdentifier
        self.parentInventoryID = parentInventoryID
        self.parentManagerBundleIdentifier = parentManagerBundleIdentifier
        self.isSystemApplication = isSystemApplication
        self.info = info
        self.kind = kind
        self.gamePlatform = gamePlatform
        self.packageProvenance = packageProvenance
    }
}

struct InstalledApplication: Identifiable, Hashable, Sendable {
    var id: String { inventoryID }

    let inventoryID: String
    let path: String
    let name: String
    let bundleIdentifier: String
    let displayVersion: String
    let buildVersion: String
    let teamIdentifier: String?
    let status: UpdateSupportStatus
    let mechanism: UpdateMechanismKind
    let mechanismName: String
    let confidence: DetectionConfidence
    let evidence: [DetectionEvidence]
    let parentInventoryID: String?
    let parentManagerBundleIdentifier: String?
    let parentManagerName: String?
    let vendorURL: URL?
    let updateFeedURL: URL?
    let versionProviders: [CatalogVersionProvider]
    var versionProvider: CatalogVersionProvider? { versionProviders.first }
    let catalogEntryID: String?
    let isOpenSource: Bool?
    let sourceCodeURL: URL?
    let releaseNotesURL: URL?
    let iconPath: String?
    let discovery: DiscoveryFacts?
    let notes: String
    let kind: InventoryItemKind
    let gamePlatform: GamePlatformKind?
    let packageProvenance: PackageProvenance?
    let releaseChannel: ReleaseChannel
    var updateCheck: UpdateCheckResult

    init(
        inventoryID: String,
        path: String,
        name: String,
        bundleIdentifier: String,
        displayVersion: String,
        buildVersion: String,
        teamIdentifier: String?,
        status: UpdateSupportStatus,
        mechanism: UpdateMechanismKind,
        mechanismName: String,
        confidence: DetectionConfidence,
        evidence: [DetectionEvidence],
        parentInventoryID: String? = nil,
        parentManagerBundleIdentifier: String?,
        parentManagerName: String?,
        vendorURL: URL?,
        updateFeedURL: URL? = nil,
        versionProvider: CatalogVersionProvider? = nil,
        versionProviders: [CatalogVersionProvider] = [],
        catalogEntryID: String?,
        isOpenSource: Bool? = nil,
        sourceCodeURL: URL? = nil,
        releaseNotesURL: URL? = nil,
        iconPath: String? = nil,
        notes: String,
        kind: InventoryItemKind,
        gamePlatform: GamePlatformKind? = nil,
        packageProvenance: PackageProvenance?,
        releaseChannel: ReleaseChannel? = nil,
        updateCheck: UpdateCheckResult? = nil,
        discovery: DiscoveryFacts? = nil
    ) {
        self.inventoryID = inventoryID
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.displayVersion = displayVersion
        self.buildVersion = buildVersion
        self.teamIdentifier = teamIdentifier
        self.status = status
        self.mechanism = mechanism
        self.mechanismName = mechanismName
        self.confidence = confidence
        self.evidence = evidence
        self.parentInventoryID = parentInventoryID
        self.parentManagerBundleIdentifier = parentManagerBundleIdentifier
        self.parentManagerName = parentManagerName
        self.vendorURL = vendorURL
        self.updateFeedURL = updateFeedURL
        self.versionProviders = versionProviders.isEmpty
            ? versionProvider.map { [$0] } ?? []
            : versionProviders
        self.catalogEntryID = catalogEntryID
        self.isOpenSource = isOpenSource
        self.sourceCodeURL = sourceCodeURL
        self.releaseNotesURL = releaseNotesURL
        self.iconPath = iconPath
        self.notes = notes
        self.discovery = discovery
        self.kind = kind
        self.gamePlatform = gamePlatform
        self.packageProvenance = packageProvenance
        self.releaseChannel = releaseChannel ?? ReleaseChannel.detect(
            version: displayVersion,
            explicitName: self.versionProviders.first?.releaseChannel?.rawValue,
            bundleIdentifier: bundleIdentifier
        )
        self.updateCheck = updateCheck ?? Self.initialUpdateCheck(
            status: status,
            installedVersion: displayVersion,
            mechanismName: mechanismName
        )
    }

    private static func initialUpdateCheck(
        status: UpdateSupportStatus,
        installedVersion: String,
        mechanismName: String
    ) -> UpdateCheckResult {
        switch status {
        case .supported:
            return .pending(installedVersion: installedVersion)
        case .managedExternally:
            return .managedExternally(
                installedVersion: installedVersion,
                detail: String(localized: "Update ownership belongs to", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(mechanismName)."
            )
        case .needsCatalog, .unsupported:
            return .sourcePending(
                installedVersion: installedVersion,
                detail: String(localized: "Update Atlas has queued this identity for catalog source resolution.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        case .checkFailed:
            return UpdateCheckResult(
                availability: .checkFailed,
                installedVersion: installedVersion,
                latestVersion: nil,
                checkedAt: Date(),
                source: nil,
                detail: String(localized: "The update-source check failed and should be retried.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            )
        }
    }

    var inventoryReleaseChannel: String {
        discovery?.source == "Docker" || discovery?.role == "bottle" || discovery?.role == "vm" ? "notApplicable" : releaseChannel.rawValue
    }

    var isManagedChild: Bool { parentInventoryID != nil || parentManagerBundleIdentifier != nil }
    var isPackageManagerItem: Bool { packageProvenance != nil }
    var isSystemPythonPackage: Bool { packageProvenance?.manager == .pythonPip }
    var isExcludedFromMainUpdateList: Bool {
        isSystemPythonPackage && InventorySettings.hideSystemPythonUpdates()
    }
    var supportsAutoOrDirectUpdate: Bool {
        if ManagerUpdatePolicy.action(for: self) != nil { return true }
        return [.sparkle, .googleUpdater, .squirrel, .appStore, .homebrew].contains(mechanism)
    }
    var isVirtualMachineOrBottleRelated: Bool {
        if kind == .virtualMachine || kind == .wineBottle { return true }
        if ["bottle", "vm", "bottle-app"].contains(discovery?.role ?? "") { return true }
        let managers: Set<String> = [
            "com.utmapp.UTM", "com.vmware.fusion", "com.parallels.desktop.console",
            "org.virtualbox.app.VirtualBox", "com.codeweavers.CrossOver",
            "com.isaacmarovitz.Whisky", "com.paulthetall.portingkit",
            "io.github.kegworks-app.kegworks", "app.getmythic.Mythic",
            "dev.kdrag0n.OrbStack"
        ]
        return managers.contains(bundleIdentifier)
            || (parentManagerBundleIdentifier.map { managers.contains($0) } ?? false)
    }
    var isGame: Bool { kind == .game }
    var isGameRelated: Bool { kind == .game || gamePlatform != nil }
    var contributesToGameCount: Bool {
        kind == .game || (kind == .application && gamePlatform != nil)
    }
    var isAppleSoftware: Bool {
        mechanism == .system || bundleIdentifier.hasPrefix("com.apple.")
    }
    var participatesInPrimaryApplicationViews: Bool { !isPackageManagerItem && !isGameRelated && discovery?.source != "Docker" }

    var versionLabel: String {
        guard !buildVersion.isEmpty, buildVersion != displayVersion else { return displayVersion }
        return "\(displayVersion) (\(buildVersion))"
    }

    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

struct InventoryFilter: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case scope(InventoryScope)
        case status(UpdateSupportStatus)
        case updateAvailability(UpdateAvailability)
        case gamePlatform(GamePlatformKind)
        case packageManager(PackageManagerKind)
        case mechanism(UpdateMechanismKind)
        case updateStat(UpdateStatKind)
    }

    let id: String
    let title: String
    let symbolName: String
    let count: Int
    let kind: Kind
}

enum UpdateStatKind: String, CaseIterable, Hashable, Sendable {
    case applications
    case autoUpdateReady
    case packageManagers

    var title: String {
        switch self {
        case .applications: String(localized: "Apps — Updates", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .autoUpdateReady: String(localized: "Direct / Auto-Update — Updates", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .packageManagers: String(localized: "Package Managers — Updates", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var symbolName: String {
        switch self {
        case .applications: "app.badge"
        case .autoUpdateReady: "bolt.badge.checkmark.fill"
        case .packageManagers: "shippingbox.fill"
        }
    }

    func includes(_ application: InstalledApplication) -> Bool {
        guard application.updateCheck.availability == .updateAvailable,
              !application.isExcludedFromMainUpdateList else { return false }
        return switch self {
        case .applications: application.participatesInPrimaryApplicationViews
        case .autoUpdateReady: application.supportsAutoOrDirectUpdate
        case .packageManagers: application.isPackageManagerItem
        }
    }
}
