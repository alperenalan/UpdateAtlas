import Foundation

enum CLIContract {
    static let schemaVersion = 1
    enum Exit: Int32 {
        case success = 0, usage = 2, configuration = 3, service = 4, partial = 5, updatesAvailable = 10, cancelled = 130
    }
    struct Failure: Encodable {
        let schemaVersion = CLIContract.schemaVersion
        let ok = false
        let error: Detail
        struct Detail: Encodable {
            let code: String
            let message: String
            let exitCode: Int32
        }
        init(_ code: String, message: String, exit: Exit) {
            error = Detail(code: code, message: message, exitCode: exit.rawValue)
        }
    }
    static func scanExit(diagnostics: [ScanDiagnostic], failedChecks: Int,
                         catalogWarning: Bool, cancelled: Bool, updates: Int, failOnUpdates: Bool) -> Exit {
        if cancelled { return .cancelled }
        if diagnostics.contains(where: { $0.reason != .offlineSkipped }) || failedChecks > 0 || catalogWarning { return .partial }
        return failOnUpdates && updates > 0 ? .updatesAvailable : .success
    }
    static func catalogSource(_ source: CatalogSnapshotSource) -> String {
        switch source { case .bundled: "bundled"; case .cache: "cache"; case .remote: "remote" }
    }
}
