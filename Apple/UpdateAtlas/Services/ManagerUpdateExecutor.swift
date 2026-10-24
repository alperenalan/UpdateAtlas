import Foundation

/// Synchronous work runs off the main actor. The injected runner makes install paths
/// testable without invoking a real package manager or modifying another app.
struct ManagerUpdateExecutor {
    enum Outcome: Equatable { case verified, unchanged, submitted }
    enum Failure: LocalizedError {
        case ownershipChanged, unavailable, commandFailed, invalidRelease
        var errorDescription: String? {
            switch self {
            case .ownershipChanged: String(localized: "The installation changed since the scan. Scan again before updating.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .unavailable: String(localized: "The update manager could not be verified. Open its own update window.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .commandFailed: String(localized: "The manager did not complete the update. Review its output and scan again.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .invalidRelease: String(localized: "Homebrew cannot safely update this item here: it may be pinned, have no checksum, or use a prerelease. Use Homebrew directly.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }
    }
    typealias Run = (ManagerUpdatePolicy.Command, TimeInterval) throws -> PackageCommandResult

    static func execute(_ item: InstalledApplication, action: ManagerUpdatePolicy.Action,
                        run: Run, validate: () -> Bool, installedVersion: () -> String?,
                        installedBuild: () -> String? = { nil }) throws -> Outcome {
        guard validate(), let command = ManagerUpdatePolicy.installCommand(for: item, action: action) else { throw Failure.unavailable }
        switch action {
        case .homebrewConfirmation:
            guard let p = item.packageProvenance else { throw Failure.ownershipChanged }
            let info = ManagerUpdatePolicy.brewInfo(p)
            let before = try run(info, 30)
            guard before.terminationStatus == 0 else { throw Failure.commandFailed }
            let record = try brewRecord(before.output, provenance: p)
            guard owns(item, data: before.output), record.installedVersion == expectedBrewVersion(p, item: item) else {
                throw Failure.ownershipChanged
            }
            if !record.outdated { return .unchanged }
            guard !record.pinned, record.hasChecksum, record.stable else { throw Failure.invalidRelease }
            // Compare actual bundle metadata, not a normalized inventory display version
            // (Android Studio, for example, expands its short bundle version).
            let bundleVersionBefore = item.kind == .application ? installedVersion() : nil
            let bundleBuildBefore = item.kind == .application ? installedBuild() : nil
            if item.kind == .application, bundleVersionBefore == nil || bundleBuildBefore == nil {
                throw Failure.ownershipChanged
            }
            // Repeat identity/running checks after the preflight before mutation.
            guard validate() else { throw Failure.ownershipChanged }
            guard try run(command, 1800).terminationStatus == 0 else { throw Failure.commandFailed }
            let after = try run(info, 30)
            guard after.terminationStatus == 0 else { return .submitted }
            let updated = try brewRecord(after.output, provenance: p)
            // Exit zero alone also covers skipped/pinned/no-op upgrades.
            guard !updated.outdated, VersionComparator.isNewer(updated.installedVersion, than: record.installedVersion) else { return .submitted }
            if item.kind == .application {
                guard let version = installedVersion(), let build = installedBuild(),
                      version != bundleVersionBefore || build != bundleBuildBefore else { return .submitted }
            }
            return .verified
        case .microsoftAutoUpdateConfirmation:
            let before = installedVersion()
            guard before == item.displayVersion else { throw Failure.ownershipChanged }
            guard try run(command, 660).terminationStatus == 0 else { throw Failure.commandFailed }
            guard let after = installedVersion(), let before, VersionComparator.isNewer(after, than: before) else { return .submitted }
            return .verified
        default: throw Failure.unavailable
        }
    }

    struct BrewRecord {
        let installedVersion: String
        let outdated: Bool
        let pinned: Bool
        let hasChecksum: Bool
        let stable: Bool
    }
    static func brewRecord(_ data: Data, provenance p: PackageProvenance) throws -> BrewRecord {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.ownershipChanged }
        let cask = p.manager == .homebrewCask
        let records = root[cask ? "casks" : "formulae"] as? [[String: Any]] ?? []
        guard records.count == 1, let r = records.first,
              [r[cask ? "token" : "name"] as? String, r[cask ? "full_token" : "full_name"] as? String].contains(p.identifier),
              let outdated = r["outdated"] as? Bool else { throw Failure.ownershipChanged }
        let version: String
        let latest: String
        if cask {
            guard let installed = (r["installed"] as? String) ?? (r["installed"] as? [String])?.last, !installed.isEmpty,
                  let release = r["version"] as? String else { throw Failure.ownershipChanged }
            version = installed; latest = release
        } else {
            guard let installs = r["installed"] as? [[String: Any]], installs.count == 1,
                  let installed = installs.first?["version"] as? String,
                  let release = (r["versions"] as? [String: Any])?["stable"] as? String else { throw Failure.ownershipChanged }
            version = installed; latest = release
        }
        let sha = r["sha256"] as? String
        let pinned = r["pinned"] as? Bool ?? false
        return BrewRecord(installedVersion: version, outdated: outdated, pinned: pinned,
                          hasChecksum: !cask || sha?.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
                          stable: latest != "latest" && ReleaseChannel.detect(version: latest, explicitName: nil,
                                                                              bundleIdentifier: p.identifier).kind == .stable)
    }
    private static func expectedBrewVersion(_ p: PackageProvenance, item: InstalledApplication) -> String {
        p.installedVersion ?? item.displayVersion
    }

    static func owns(_ item: InstalledApplication, data: Data) -> Bool {
        guard let p = item.packageProvenance else { return false }
        let snapshot = PackageInventoryScanner.parseHomebrew(data: data, executablePath: p.managerExecutablePath)
        if item.kind == .application {
            return snapshot.caskApplicationsByPath[URL(fileURLWithPath: item.path).standardizedFileURL.path]?.identifier == p.identifier
        }
        return snapshot.candidates.contains {
            $0.path == item.path && $0.packageProvenance?.identifier == p.identifier
        }
    }
}
