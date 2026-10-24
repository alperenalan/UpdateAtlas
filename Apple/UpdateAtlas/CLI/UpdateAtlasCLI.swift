import Darwin
import Foundation

@main
enum UpdateAtlasCLI {
    private static let appDomain = AppIdentity.bundleIdentifier

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["help"] || arguments.isEmpty {
            write("""
            Update Atlas CLI — read-only software inventory
            Usage: update-atlas scan [OPTIONS]
                   update-atlas check [OPTIONS]
                   update-atlas skill
                   update-atlas --version

            Options: --offline, --fail-on-updates, --include-system, --include-paths, --updates-only,
                     --kind KIND, --manager OPAQUE_ID or --children-of OPAQUE_ID,
                     --progress or --no-progress, --folder ABSOLUTE_PATH (repeatable),
                     --docker or --no-docker
            KIND: application, game, managedComponent, extension, module, runtime,
                  modLoader, mod, shaderPack, resourcePack, helper, commandLineTool, package,
                  containerContext, composeProject, container, containerImage, containerVolume,
                  wineBottle, virtualMachine
            Filters combine; --manager includes its owner and descendants, while
            --children-of returns descendants only. IDs come from an unfiltered scan.
            summary separates full-inventory counts from returned-item counts.
            coverage counts verified versus unverified items across the full inventory.
            scanDiagnostics lists partial discovery failures without local paths.
            Commands use a shared 120-second discovery/check budget and bounded output.
            Filters do not restrict scanning or network checks.

            settings list|get KEY|set KEY VALUE|reset KEY
            settings folders add|remove ABSOLUTE_PATH
            catalog show|refresh|matching true|matching false
            catalog enable|disable ENTRY_ID
            skill prints the SKILL.md instruction guide for AI coding agents.
            --offline reads local metadata and Homebrew/npm receipts without launching
            package managers, checking release sources or refreshing catalogs. Other
            package environments and Docker are explicitly skipped. check --offline
            reports checkPerformed=false; a missing latest version is not up to date.
            Exit codes: 0 success, 2 invalid arguments, 3 invalid local configuration,
            4 service failure, 5 partial results, 10 updates (--fail-on-updates), 130 cancelled.
            Fatal errors have schema-versioned JSON on stdout; help/version remain text.
            scan skips app-source checks and remote catalog refresh. Package-manager
            inventory commands may still contact their configured registries.
            check refreshes the catalog and checks available update sources over the network.
            Both commands print schema-versioned JSON to stdout. No updates are installed.
            Optional updateAction describes a GUI confirmation or App Store page action,
            never an installation performed by this command.
            Live progress goes to stderr in terminals; pipes remain quiet by default.
            --progress forces plain progress in logs; --no-progress suppresses it.
            Additional discovery follows Settings > Discovery. --folder adds a folder
            for this command only; --docker/--no-docker override the saved Docker choice.
            Docker reads the current connection without starting it, entering containers
            or pulling images. discovery exposes local source, state and image identity.
            Local paths are omitted unless --include-paths is supplied.
            """, to: .standardOutput)
            return
        }
        if arguments == ["--version"] || arguments == ["version"] {
            write(versionLabel, to: .standardOutput)
            return
        }
        if arguments == ["skill"] {
            write(AIIntegrationGuide.skillMarkdown, to: .standardOutput)
            return
        }
        if arguments.first == "settings" || arguments.first == "catalog" {
            await runManagement(arguments)
            return
        }
        let query: CLIInventoryQuery
        do {
            query = try CLIInventoryQuery(arguments: arguments)
        } catch {
            fail("invalid_arguments", "Invalid arguments. Run update-atlas --help.", exit: .usage)
        }
        let command = query.command
        let progress = CLIScanProgress(mode: CLIScanProgress.mode(
            for: query.progress, isTerminal: isatty(STDERR_FILENO) == 1,
            supportsAnimation: ProcessInfo.processInfo.environment["TERM"] != "dumb"
        ))

        let preferences = UserDefaults(suiteName: appDomain) ?? .standard
        let includeSystem = query.includeSystem
            || (preferences.object(forKey: InventorySettings.includeSystemApplicationsKey) as? Bool
                ?? InventorySettings.defaultIncludeSystemApplications)
        let includePaths = query.includePaths
        let catalogEnabled = preferences.object(forKey: CatalogSettings.matchingEnabledKey) as? Bool
            ?? CatalogSettings.defaultMatchingEnabled
        let catalogService = RemoteCatalogService()
        progress.update("Loading bundled catalog…")
        let localSnapshot = await catalogService.snapshot(for: .localOnly)
        guard localSnapshot.catalog.revision > 0 else {
            progress.finish("Scan failed: invalid catalog")
            fail("invalid_catalog", "The bundled catalog is missing or invalid; refusing an incomplete inventory.", exit: .configuration)
        }
        let control = ScanControl()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { control.cancel() }
        interrupt.resume()
        defer { interrupt.cancel() }

        let scanner = ApplicationScanner()
        async let catalogTask = catalogService.snapshot(for: command == .check && !query.offline ? .scan : .localOnly)
        async let inventoryTask = scanner.scanWithFindings(
            includeSystemApplications: includeSystem, control: control,
            discovery: DiscoveryConfiguration(
                folders: DiscoveryConfiguration.current(from: preferences).folders + query.folders,
                includeDocker: query.docker ?? preferences.bool(forKey: DiscoveryConfiguration.dockerKey)),
            offline: query.offline,
            progress: { phase in
                switch phase {
                case .packages: progress.update("Inspecting package environments…")
                case .applications: progress.update("Discovering installed applications…")
                case .updateSources: progress.update("Checking update sources…")
                }
            }, activity: { progress.update($0) }
        )
        let inventory = await inventoryTask
        progress.update("Loading catalog…")
        let snapshot = await catalogTask
        guard snapshot.catalog.revision > 0 else {
            progress.finish("Scan failed: invalid catalog")
            fail("invalid_catalog", "The bundled catalog is missing or invalid; refusing an incomplete inventory.", exit: .configuration)
        }
        let catalog = CatalogActivationPolicy.applying(
            to: snapshot.catalog,
            matchingEnabled: catalogEnabled,
            disabledRuleKeys: Set(preferences.stringArray(forKey: CatalogSettings.disabledRuleKeysKey) ?? [])
        )
        progress.update("Classifying \(inventory.candidates.count) discovered items…")
        let detected = UpdateDetectionEngine().classify(inventory.candidates, catalog: catalog)
        let items = command == .check && !query.offline ? await UpdateCheckService(allowPrereleaseForStable: ReleaseChannelSettings.current(from: preferences)).check(
            detected, control: control,
            progress: { done, total in progress.update("Checking update sources · \(done)/\(total) items") }
        ) : detected
        let selected: [InstalledApplication]
        do {
            selected = try query.selectedItems(in: items)
        } catch {
            progress.finish("Scan failed: unknown manager ID")
            fail("invalid_arguments", "The selected manager ID is not in the inventory. Run an unfiltered scan to obtain current IDs.", exit: .usage)
        }
        let response = Response(
            schemaVersion: 1,
            ok: true,
            networkPolicy: query.offline ? "offline" : "online",
            isPartial: inventory.diagnostics.contains { $0.reason != .offlineSkipped } || control.shouldStop
                || items.contains { $0.updateCheck.availability == .checkFailed } || snapshot.warning != nil,
            catalogSourceCode: CLIContract.catalogSource(snapshot.source),
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            checkPerformed: command == .check && !query.offline,
            catalogRevision: snapshot.catalog.revision,
            catalogSource: snapshot.source.title,
            catalogWarning: snapshot.warning,
            coverage: InventoryCoverageSummary(items),
            scanDiagnostics: inventory.diagnostics + (control.hasTimedOut ? [ScanDiagnostic(source: "Scan", reason: .timedOut)] : []),
            summary: CLIInventorySummary(inventory: items, returned: selected),
            items: selected.map { Item($0, includePath: includePaths) }
        )
        progress.update("Preparing JSON results…")
        let resultExit = CLIContract.scanExit(diagnostics: response.scanDiagnostics,
            failedChecks: response.summary.checkFailedCount, catalogWarning: snapshot.warning != nil,
            cancelled: control.isCancelled, updates: response.summary.availableUpdateCount,
            failOnUpdates: query.failOnUpdates)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response)
            let diagnostics = response.scanDiagnostics.count
            progress.finish("\(diagnostics == 0 ? "Completed" : "Completed with \(diagnostics) scan warnings"): \(items.count) items, \(selected.count) returned")
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            exit(resultExit.rawValue)
        } catch {
            progress.finish("Scan failed: could not encode results")
            fail("invalid_catalog", "The operation could not be completed. See stderr for details.", exit: .configuration)
        }
    }

    private static func write(_ value: String, to handle: FileHandle) {
        handle.write(Data((value + "\n").utf8))
    }

    private static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            write("Could not encode JSON.", to: .standardError)
            exit(CLIContract.Exit.configuration.rawValue)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func fail(_ code: String, _ message: String, exit status: CLIContract.Exit) -> Never {
        emit(CLIContract.Failure(code, message: message, exit: status))
        write(message, to: .standardError)
        exit(status.rawValue)
    }

    private struct SettingsResponse: Encodable {
        let schemaVersion = 1
        let ok = true
        let settings: [String: CLIPreferences.Value]
    }
    private struct CatalogResponse: Encodable {
        let schemaVersion = 1
        let ok: Bool
        let source: String
        let endpoint: String
        let matchingEnabled: Bool
        let disabledRuleKeys: [String]
        let warning: String?
        let catalog: RemoteCatalog
    }

    private static func runManagement(_ arguments: [String]) async {
        let defaults = UserDefaults(suiteName: appDomain) ?? .standard
        let preferences = CLIPreferences(defaults: defaults)
        let args = Array(arguments.dropFirst())
        do {
            if arguments.first == "settings" {
                switch args.first {
                case "list" where args.count == 1: break
                case "get" where args.count == 2:
                    emit(SettingsResponse(settings: [args[1]: try preferences.get(args[1])]))
                    return
                case "set" where args.count == 3: try preferences.set(args[1], value: args[2])
                case "reset" where args.count == 2: try preferences.reset(args[1])
                case "folders" where args.count == 3: try preferences.folder(args[1], path: args[2])
                default: throw CLIPreferences.PreferenceError.invalidArguments
                }
                emit(SettingsResponse(settings: preferences.settings()))
                return
            }
            let service = RemoteCatalogService()
            var snapshot = await service.snapshot(for: .localOnly)
            guard snapshot.catalog.revision > 0 else {
                fail("invalid_catalog", "The bundled catalog is missing or invalid.", exit: .configuration)
            }
            switch args.first {
            case "show" where args.count == 1: break
            case "refresh" where args.count == 1:
                snapshot = await service.snapshot(for: .scan)
            case "matching" where args.count == 2 && ["true", "false"].contains(args[1]):
                defaults.set(args[1] == "true", forKey: CatalogSettings.matchingEnabledKey)
            case "enable" where args.count == 2, "disable" where args.count == 2:
                guard snapshot.catalog.entries.contains(where: { $0.id == args[1] }) else {
                    fail("unknown_rule", "The rule ID does not exist in the selected catalog.", exit: .usage)
                }
                let key = CatalogActivationPolicy.ruleKey(catalogID: snapshot.catalog.catalogID, entryID: args[1])
                var disabled = Set(defaults.stringArray(forKey: CatalogSettings.disabledRuleKeysKey) ?? [])
                if args[0] == "disable" { disabled.insert(key) } else { disabled.remove(key) }
                defaults.set(disabled.sorted(), forKey: CatalogSettings.disabledRuleKeysKey)
            default: throw CLIPreferences.PreferenceError.invalidArguments
            }
            let success = args.first != "refresh" || snapshot.warning == nil
            emit(CatalogResponse(ok: success, source: CLIContract.catalogSource(snapshot.source),
                endpoint: CatalogSettings.officialRemoteURL,
                matchingEnabled: defaults.object(forKey: CatalogSettings.matchingEnabledKey) as? Bool ?? true,
                disabledRuleKeys: (defaults.stringArray(forKey: CatalogSettings.disabledRuleKeysKey) ?? []).sorted(),
                warning: snapshot.warning, catalog: snapshot.catalog))
            if !success { exit(CLIContract.Exit.service.rawValue) }
        } catch {
            fail("invalid_arguments", "Invalid setting or catalog arguments. See --help.", exit: .usage)
        }
    }

    private static var versionLabel: String {
        guard let metadata = BundledAppResources.versionInfo(),
              let version = metadata["CFBundleShortVersionString"] as? String,
              let build = metadata["CFBundleVersion"] as? String else {
            return "Update Atlas CLI (development build)"
        }
        return "Update Atlas CLI \(version) (Build \(build))"
    }

    private struct Response: Encodable {
        let schemaVersion: Int
        let ok: Bool
        let networkPolicy: String
        let isPartial: Bool
        let catalogSourceCode: String
        let generatedAt: String
        let checkPerformed: Bool
        let catalogRevision: Int
        let catalogSource: String
        let catalogWarning: String?
        let coverage: InventoryCoverageSummary
        let scanDiagnostics: [ScanDiagnostic]
        let summary: CLIInventorySummary
        let items: [Item]
    }

    private struct Item: Encodable {
        let id: String
        let name: String
        let kind: String
        let installedVersion: String
        let latestVersion: String?
        let updateStatus: String
        let mechanismStatus: String
        let updateMechanism: String
        let updateAction: String?
        let parentID: String?
        let gamePlatform: String?
        let releaseChannel: String
        let checkSource: String?
        let checkDetail: String?
        let path: String?
        let discovery: DiscoveryFacts?

        init(_ item: InstalledApplication, includePath: Bool) {
            id = opaqueID(item.id)
            name = item.name
            kind = item.kind.rawValue
            installedVersion = item.displayVersion
            latestVersion = item.updateCheck.latestVersion
            updateStatus = item.updateCheck.availability.rawValue
            mechanismStatus = item.status.rawValue
            updateMechanism = item.mechanism.rawValue
            updateAction = ManagerUpdatePolicy.action(for: item)?.rawValue
            parentID = item.parentInventoryID.map(opaqueID)
            gamePlatform = item.gamePlatform?.rawValue
            releaseChannel = item.inventoryReleaseChannel
            checkSource = item.updateCheck.source?.rawValue
            // Provider diagnostics may contain local paths; keep the default JSON path-free.
            checkDetail = includePath ? item.updateCheck.detail : nil
            path = includePath ? item.path : nil
            discovery = item.discovery
        }
    }

    private static func opaqueID(_ value: String) -> String { CLIInventoryQuery.opaqueID(value) }
}
