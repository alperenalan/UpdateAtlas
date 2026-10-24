import Foundation

enum ScanPhase: String, Sendable {
    case packages, applications, updateSources
    var title: String {
        switch self {
        case .packages: String(localized: "Checking package environments…", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .applications: String(localized: "Discovering installed software…", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateSources: String(localized: "Checking update sources…", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

struct ScanDiagnostic: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case unavailable, timedOut, invalidOutput, commandFailed, outputTooLarge, cancelled, unreadable, offlineSkipped
    }
    enum Operation: String, Codable, Sendable {
        case npmGlobalRoot, npmGlobalList, npmGlobalOutdated
        case gogInstalledTable, utmBundleListing, utmConfiguration
    }
    // Manager plus ordinal, never a home/environment path in default CLI JSON.
    let source: String
    let reason: Reason
    let operation: Operation?

    init(source: String, reason: Reason, operation: Operation? = nil) {
        self.source = source
        self.reason = reason
        self.operation = operation
    }
    var message: String {
        let detail: String
        switch reason {
        case .unavailable: detail = String(localized: "Could not start the inventory command.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .timedOut: detail = String(localized: "The inventory command timed out.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .invalidOutput: detail = String(localized: "The inventory response could not be read.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .commandFailed: detail = String(localized: "The inventory command failed.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .outputTooLarge: detail = String(localized: "The inventory response exceeded the size limit.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .cancelled: detail = String(localized: "The scan was cancelled.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .offlineSkipped: detail = String(localized: "External inventory commands are skipped in offline mode.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .unreadable: detail = String(localized: "The application folder could not be read.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
        return String(format: String(localized: "%@: %@", bundle: AppL10n.bundle, locale: AppL10n.locale), sourceTitle, detail)
    }

    /// Display label only: `source` stays as written because the CLI JSON contract exposes it.
    var sourceTitle: String {
        let parts = source.split(separator: " #")
        if parts.count == 2, let ordinal = Int(parts[1]) {
            switch parts[0] {
            case "Custom folder": return String(format: String(localized: "Custom Folder %lld", bundle: AppL10n.bundle, locale: AppL10n.locale), ordinal)
            case "Applications": return String(format: String(localized: "Applications Folder %lld", bundle: AppL10n.bundle, locale: AppL10n.locale), ordinal)
            default: return source
            }
        }
        switch source {
        case "Application managers": return String(localized: "Application Managers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "Wine bottles": return String(localized: "Wine Bottles", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "Wine Wrappers": return String(localized: "Wine Wrappers", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case "GOG manifest": return String(localized: "GOG Manifest", bundle: AppL10n.bundle, locale: AppL10n.locale)
        default: return source
        }
    }
}

// Detached discovery and the GUI cancellation action share only this locked state.
final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let deadline: ContinuousClock.Instant
    init(timeout: TimeInterval = 120) {
        deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var hasTimedOut: Bool { ContinuousClock.now >= deadline }
    var shouldStop: Bool { isCancelled || hasTimedOut }
}

struct InventoryCoverageSummary: Codable, Equatable, Sendable {
    let inventoryItemCount: Int
    let verifiedItemCount: Int
    let unverifiedItemCount: Int
    let failedItemCount: Int
    let managerOwnedItemCount: Int
    init(_ inventory: [InstalledApplication]) {
        let items = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        inventoryItemCount = items.count
        verifiedItemCount = items.filter { [.upToDate, .updateAvailable].contains($0.updateCheck.availability) }.count
        unverifiedItemCount = inventoryItemCount - verifiedItemCount
        failedItemCount = items.filter { $0.updateCheck.availability == .checkFailed }.count
        managerOwnedItemCount = items.filter { [.managedExternally, .managedBySystem].contains($0.updateCheck.availability) }.count
    }
}
