import Foundation
import Testing
@testable import UpdateAtlas

@Suite("Pre-release roadmap features")
struct PreReleaseRoadmapTests {
    @Test("System Python packages are excluded from main Update Available list and menu bar count")
    func systemPythonExcludedFromMainUpdateList() throws {
        let suiteName = "test.python." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var sysPip = makeItem(
            id: "pip:requests",
            name: "requests",
            path: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/lib/python3.9/site-packages/requests",
            kind: .package,
            mechanism: .python,
            packageManager: .pythonPip,
            managerExecutablePath: "/usr/bin/python3"
        )
        sysPip.updateCheck = UpdateCheckResult(
            availability: .updateAvailable,
            installedVersion: "2.31.0",
            latestVersion: "2.32.0",
            checkedAt: Date(),
            source: .packageManager,
            detail: "Update available"
        )

        var normalApp = makeItem(
            id: "app:raycast",
            name: "Raycast",
            path: "/Applications/Raycast.app",
            kind: .application,
            mechanism: .sparkle
        )
        normalApp.updateCheck = sysPip.updateCheck

        #expect(sysPip.isSystemPythonPackage == true)
        #expect(normalApp.isSystemPythonPackage == false)

        // Default: hide system Python from main update list
        #expect(InventorySettings.hideSystemPythonUpdates(in: defaults) == true)
        #expect(MenuBarUpdateSummary.count([sysPip, normalApp]).total == 1)
        #expect(MenuBarUpdateList.items(in: [sysPip, normalApp]).map(\.id) == [normalApp.id])
    }

    @Test("App Store applications return inline App Store page action")
    func appStoreActionPolicy() {
        let appStoreItem = makeItem(
            id: "mas:xcode",
            name: "Xcode",
            path: "/Applications/Xcode.app",
            kind: .application,
            mechanism: .appStore
        )
        #expect(ManagerUpdatePolicy.action(for: appStoreItem) == .appStorePage)
    }

    @Test("Curl CLI local receipt reader parses semver from receipt files and rejects non-versions")
    func curlCLIReceiptReader() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let uvReceipt = root.appendingPathComponent(".config/uv/uv-receipt.json")
        try FileManager.default.createDirectory(at: uvReceipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":"0.5.14"}"#.utf8).write(to: uvReceipt)

        let uvRecipe = try #require(DirectInstallScanner.recipes.first(where: { $0.id == "uv" }))
        let version = uvRecipe.version(from: root.appendingPathComponent(".local/bin/uv"), homeDirectory: root)
        #expect(version == "0.5.14")

        try Data(#"{"version":"<!DOCTYPE html>"}"#.utf8).write(to: uvReceipt)
        #expect(uvRecipe.version(from: root.appendingPathComponent(".local/bin/uv"), homeDirectory: root) == nil)
    }

    @Test("DirectInstallScanner discovers newly added curl/standalone CLI tools")
    func directInstallExpandedRecipes() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let systemBin = root.appendingPathComponent("fake-system-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: systemBin, withIntermediateDirectories: true)

        let bunBinary = root.appendingPathComponent(".bun/bin/bun")
        try FileManager.default.createDirectory(at: bunBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: bunBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bunBinary.path)

        let scanner = DirectInstallScanner(homeDirectory: root, systemBinaryDirectory: systemBin)
        let snapshot = scanner.scan(packageCandidates: [], applicationCandidates: [])
        #expect(snapshot.candidates.contains(where: { $0.bundleIdentifier == "direct-cli:bun" }))
    }

    @Test("Wine and CrossOver bottle discovery enumerates installed Windows applications from system.reg")
    func wineBottleInstalledAppsDiscovery() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("Shared", isDirectory: true)

        let bottle = root.appendingPathComponent("Library/Application Support/CrossOver/Bottles/SteamBottle", isDirectory: true)
        let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
        let sevenZipDir = driveC.appendingPathComponent("Program Files/7-Zip", isDirectory: true)
        let notepadDir = driveC.appendingPathComponent("Program Files/Notepad++", isDirectory: true)
        try FileManager.default.createDirectory(at: sevenZipDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notepadDir, withIntermediateDirectories: true)
        try Data("[Bottle]\n".utf8).write(to: bottle.appendingPathComponent("cxbottle.conf"))
        try Data("exe".utf8).write(to: sevenZipDir.appendingPathComponent("7zFM.exe"))
        try Data("exe".utf8).write(to: notepadDir.appendingPathComponent("notepad++.exe"))

        let systemReg = """
        WINE REGISTRY Version 2

        [Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\7-Zip]
        "DisplayName"="7-Zip 24.08 (x64)"
        "DisplayVersion"="24.08.00.0"
        "InstallLocation"="C:\\\\Program Files\\\\7-Zip"

        [Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Uninstall\\\\Notepad++]
        "DisplayName"="Notepad++ (64-bit x64)"
        "DisplayVersion"="8.6.9"
        "InstallLocation"="C:\\\\Program Files\\\\Notepad++"
        """
        try Data(systemReg.utf8).write(to: bottle.appendingPathComponent("system.reg"))

        let provider = LocalDiscoveryProvider(home: root, shared: shared, applicationRoots: [])
        let result = provider.scan(configuration: .init(), control: ScanControl())

        let bottleCandidate = try #require(result.candidates.first(where: { $0.info["DiscoveryRole"] == "bottle" }))
        #expect(bottleCandidate.name.contains("SteamBottle"))

        let bottleApps = result.candidates.filter { $0.info["DiscoveryRole"] == "bottle-app" }
        #expect(bottleApps.count == 2)
        #expect(bottleApps.contains(where: { $0.name == "7-Zip 24.08 (x64)" && $0.displayVersion == "24.08.00.0" }))
        #expect(bottleApps.contains(where: { $0.name == "Notepad++ (64-bit x64)" && $0.displayVersion == "8.6.9" }))
    }

    @Test("UTM and VMware Fusion virtual machines are discovered as .virtualMachine items")
    func virtualMachineDiscovery() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("Shared", isDirectory: true)

        // 1. UTM bundle
        let utmBundle = root.appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents/Ubuntu.utm", isDirectory: true)
        try FileManager.default.createDirectory(at: utmBundle, withIntermediateDirectories: true)
        let utmConfig: [String: Any] = [
            "Information": ["Name": "Ubuntu 24.04 ARM64"],
            "Backend": "qemu"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: utmConfig, format: .xml, options: 0)
        try plistData.write(to: utmBundle.appendingPathComponent("config.plist"))

        // 2. VMware Fusion bundle
        let fusionBundle = root.appendingPathComponent("Virtual Machines.localized/Windows 11.vmwarevm", isDirectory: true)
        try FileManager.default.createDirectory(at: fusionBundle, withIntermediateDirectories: true)
        let vmxContent = """
        .encoding = "UTF-8"
        displayName = "Windows 11 Pro ARM"
        guestOS = "arm-windows11-64"
        """
        try Data(vmxContent.utf8).write(to: fusionBundle.appendingPathComponent("Windows 11.vmx"))

        let provider = LocalDiscoveryProvider(home: root, shared: shared, applicationRoots: [])
        let result = provider.scan(configuration: .init(), control: ScanControl())

        let vms = result.candidates.filter { $0.kind == .virtualMachine }
        #expect(vms.count == 2)
        #expect(vms.contains(where: { $0.name == "Ubuntu 24.04 ARM64" && $0.parentManagerBundleIdentifier == "com.utmapp.UTM" }))
        #expect(vms.contains(where: { $0.name == "Windows 11 Pro ARM" && $0.parentManagerBundleIdentifier == "com.vmware.fusion" }))

        let catalog = RemoteCatalog(schemaVersion: 1, catalogID: "test", revision: 0, generatedAt: Date(), expiresAt: nil, entries: [])
        let classified = UpdateDetectionEngine().classify(vms, catalog: catalog)
        #expect(classified.allSatisfy { InventoryScope.virtualMachinesAndBottles.includes($0) })
    }

    @Test("LanguageSettings offers only translated languages")
    @MainActor
    func languageAndOnboardingSettings() throws {
        let suiteName = "test.lang." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let primaryCodes = Set(LanguageSettings.primaryLanguages.map(\.id))
        #expect(primaryCodes == Set(["system", "en", "tr", "ru", "de", "fr", "zh-Hans", "ja"]))
        #expect(LanguageSettings.normalizedCode("es") == "system")

        let settings = LanguageSettings(defaults: defaults)
        settings.select("tr")
        #expect(settings.selectedCode == "tr")
        #expect(settings.effectiveLocale.identifier == "tr")
        defaults.set(["es"], forKey: "AppleLanguages")
        LanguageSettings.persist("es", in: defaults)
        #expect(defaults.string(forKey: LanguageSettings.languageKey) == "system")
        // UserDefaults can still return a registered macOS fallback (such as en-US).
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)

        defaults.set(true, forKey: OnboardingSettings.completedKey)
        #expect(defaults.bool(forKey: OnboardingSettings.completedKey) == true)
        OnboardingSettings.reset(in: defaults)
        #expect(defaults.bool(forKey: OnboardingSettings.completedKey) == false)
    }

    @Test("The published Agent Skill uses CLI commands and omits MCP setup")
    func aiIntegrationGuideGeneration() {
        let skillMarkdown = AIIntegrationGuide.skillMarkdown
        #expect(skillMarkdown.contains("name: update-atlas"))
        #expect(skillMarkdown.contains("update-atlas scan"))
        #expect(skillMarkdown.contains("update-atlas check"))
        #expect(!skillMarkdown.localizedCaseInsensitiveContains("mcp"))
        #expect(!AIIntegrationGuide.cliQuickReference.contains { $0.command == "update-atlas mcp" })
        #expect(AIIntegrationGuide.cliQuickReference.contains { $0.command == "update-atlas skill" })
    }

    @Test("CLI help advertises the Skill without advertising MCP")
    func cliHelpFirstReleaseScope() throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Helpers/update-atlas")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let help = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(help.contains("update-atlas skill"))
        #expect(!help.localizedCaseInsensitiveContains("mcp"))
    }

    @Test("Launch at login menu-bar-only startup and update-menu icons default to enabled")
    func menuBarAndStartupDefaults() throws {
        let suiteName = "test.startup." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(LaunchAtLoginSettings.openInMenuBarOnly(in: defaults) == true)
        defaults.set(false, forKey: LaunchAtLoginSettings.openInMenuBarOnlyKey)
        #expect(LaunchAtLoginSettings.openInMenuBarOnly(in: defaults) == false)

        #expect(MenuBarSettings.showAppIcons(in: defaults) == true)
        defaults.set(false, forKey: MenuBarSettings.showAppIconsKey)
        #expect(MenuBarSettings.showAppIcons(in: defaults) == false)
    }

    private func makeTempDir() throws -> URL {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = project.appendingPathComponent(".temporary_files/PreReleaseRoadmapTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeItem(
        id: String,
        name: String,
        path: String,
        kind: InventoryItemKind,
        mechanism: UpdateMechanismKind,
        packageManager: PackageManagerKind? = nil,
        managerExecutablePath: String = "/opt/homebrew/bin/brew"
    ) -> InstalledApplication {
        InstalledApplication(
            inventoryID: id,
            path: path,
            name: name,
            bundleIdentifier: "test.\(id)",
            displayVersion: "1.0.0",
            buildVersion: "1",
            teamIdentifier: nil,
            status: .supported,
            mechanism: mechanism,
            mechanismName: mechanism.rawValue,
            confidence: .verified,
            evidence: [],
            parentInventoryID: nil,
            parentManagerBundleIdentifier: nil,
            parentManagerName: nil,
            vendorURL: nil,
            catalogEntryID: nil,
            notes: "",
            kind: kind,
            packageProvenance: packageManager.map {
                PackageProvenance(
                    identifier: name,
                    manager: $0,
                    managerExecutablePath: managerExecutablePath,
                    installLocation: path,
                    explicitlyInstalled: true,
                    homepage: nil,
                    summary: nil,
                    isOutdated: true,
                    latestVersion: "2.32.0",
                    installedVersion: "2.31.0"
                )
            }
        )
    }
}
