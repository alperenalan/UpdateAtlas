import Foundation

enum BundledAppResources {
    /// Bundle.main can retain the shell's symlink path. Resolve the actual binary
    /// before deriving Resources or Info.plist; never search the caller's cwd.
    static func applicationBundle(executableURL: URL? = Bundle.main.executableURL) -> Bundle? {
        guard let executableURL else { return nil }
        var directory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        if directory.lastPathComponent == "Helpers" { directory.deleteLastPathComponent() }
        guard directory.lastPathComponent == "MacOS" else { return nil }
        directory.deleteLastPathComponent()
        guard directory.lastPathComponent == "Contents" else { return nil }
        directory.deleteLastPathComponent()
        guard directory.pathExtension.lowercased() == "app" else { return nil }
        return Bundle(url: directory)
    }

    static func bootstrapCatalogURL(executableURL: URL? = Bundle.main.executableURL) -> URL? {
        if let bundled = applicationBundle(executableURL: executableURL)?
            .url(forResource: "BootstrapCatalog", withExtension: "json") {
            return bundled
        }
        guard let directory = retainedCLIDirectory(executableURL: executableURL) else { return nil }
        let sibling = directory.appendingPathComponent("BootstrapCatalog.json")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    static func versionInfo(executableURL: URL? = Bundle.main.executableURL) -> [String: Any]? {
        if let info = applicationBundle(executableURL: executableURL)?.infoDictionary { return info }
        guard let directory = retainedCLIDirectory(executableURL: executableURL) else { return nil }
        let sibling = directory.appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: sibling) as? [String: Any]
    }

    private static func retainedCLIDirectory(executableURL: URL?) -> URL? {
        guard let executableURL else { return nil }
        let resolved = executableURL.resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        guard resolved.lastPathComponent == "update-atlas",
              UUID(uuidString: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().lastPathComponent == "update-atlas-cli" else {
            return nil
        }
        return directory
    }
}
