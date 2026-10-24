import Foundation

/// Refresh only the installation whose user-confirmed update cycle returned.
/// No folder discovery, dependency scan or unrelated manager/network request.
struct ApplicationRefreshService: Sendable {
    enum Failure: LocalizedError {
        case identityChanged, managerUnreadable
        var errorDescription: String? {
            switch self {
            case .identityChanged:
                String(localized: "The installation changed or could not be read. Scan again before updating.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .managerUnreadable:
                String(localized: "This package could not be refreshed. Check its manager and scan again.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }
    }
    typealias Run = @Sendable (ManagerUpdatePolicy.Command, ScanControl) throws -> PackageCommandResult

    func read(_ item: InstalledApplication, control: ScanControl,
              run: @escaping Run = { command, control in
                  try PackageCommandRunner.run(executable: command.executable, arguments: command.arguments,
                      timeout: 30, control: control, environmentOverrides: command.environment)
              }) async throws -> ApplicationCandidate {
        let task = Task.detached(priority: .userInitiated) {
            guard !control.shouldStop, !Task.isCancelled else { throw CancellationError() }
            var ownership: PackageProvenance?
            if let p = item.packageProvenance {
                guard [.homebrewCask, .homebrewFormula].contains(p.manager),
                      ManagerUpdatePolicy.validToken(p.identifier),
                      ManagerUpdatePolicy.validBrewPath(p.managerExecutablePath) else { throw Failure.identityChanged }
                // A scoped info request updates receipt/version/outdated state for this token only.
                let response = try run(ManagerUpdatePolicy.brewInfo(p), control)
                guard response.terminationStatus == 0,
                      PackageInventoryScanner.validJSON(response.output, arguments: ["--json=v2"]) else {
                    throw Failure.managerUnreadable
                }
                _ = try ManagerUpdateExecutor.brewRecord(response.output, provenance: p)
                let snapshot = PackageInventoryScanner.parseHomebrew(data: response.output,
                    executablePath: p.managerExecutablePath)
                if item.path.hasSuffix(".app") {
                    ownership = snapshot.caskApplicationsByPath[URL(fileURLWithPath: item.path).standardizedFileURL.path]
                    guard ownership?.identifier == p.identifier else { throw Failure.identityChanged }
                } else {
                    // Formula Cellar paths change with the version; identity does not.
                    guard let candidate = snapshot.candidates.first(where: {
                        $0.inventoryID == item.id && $0.bundleIdentifier == item.bundleIdentifier
                    }), candidate.packageProvenance?.manager == p.manager else { throw Failure.identityChanged }
                    guard !control.shouldStop, !Task.isCancelled else { throw CancellationError() }
                    return candidate
                }
            }
            guard !control.shouldStop, !Task.isCancelled else { throw CancellationError() }
            guard item.path.hasSuffix(".app") else { throw Failure.identityChanged }
            return try ApplicationScanner.refreshedBundle(item, provenance: ownership)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: {
            control.cancel()
            task.cancel()
        }
    }
}
