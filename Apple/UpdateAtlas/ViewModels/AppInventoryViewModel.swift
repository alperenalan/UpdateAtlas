import AppKit
import Foundation

@MainActor
final class AppInventoryViewModel: ObservableObject {
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var directInstallRemnants: [DirectInstallRemnant] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isForegroundScan = false
    @Published private(set) var isSupportReminderPresented = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var catalogSnapshot: CatalogSnapshot?
    @Published private(set) var scanError: String?
    @Published private(set) var scanDiagnostics: [ScanDiagnostic] = []
    @Published private(set) var scanPhase: String = ""
    @Published private(set) var historyEvents: [InstallationHistoryEvent] = []
    @Published private(set) var historyError: String?
    private var completedScanSequence = 0
    private var pendingNotificationIDs: [String]?
    lazy var backgroundChecks = BackgroundCheckService(
        isBusy: { [weak self] in self?.isScanning != false || DirectUpdateService.shared.activeApplicationID != nil },
        isOnboarded: { UserDefaults.standard.bool(forKey: OnboardingSettings.completedKey) },
        scan: { [weak self] in await self?.scan(trigger: .scheduled) }
    )
    lazy var catalogRefreshes = CatalogRefreshService(
        isEligible: { [weak self] in self != nil },
        isBusy: { [weak self] in self?.isScanning != false || DirectUpdateService.shared.activeApplicationID != nil },
        refreshCatalog: { [weak self] in await self?.refreshCatalogInBackground() ?? false }
    )
    private var activeScan: Task<Void, Never>?
    private var scanControl: ScanControl?
    var coverageSummary: InventoryCoverageSummary { InventoryCoverageSummary(applications) }
    @Published var searchText = ""
    @Published var isSearchFieldFocused = false
    @Published var selectedApplicationID: String? {
        didSet { if oldValue != selectedApplicationID { isInspectorPresented = selectedApplicationID != nil } }
    }
    @Published var isInspectorPresented = false
    @Published var selectedFilterID: String
    @Published var expandedManagerIDs = Set<String>()
    @Published var sortColumn: InventoryColumn = .name
    @Published var sortAscending = true
    @Published var visibleColumns: Set<InventoryColumn> {
        didSet {
            UserDefaults.standard.set(visibleColumns.map(\.rawValue).sorted(), forKey: InventoryColumn.defaultsKey)
        }
    }
    @Published var columnWidths: [InventoryColumn: CGFloat] {
        didSet {
            let encoded = Dictionary(uniqueKeysWithValues: columnWidths.map { ($0.key.rawValue, Double($0.value)) })
            UserDefaults.standard.set(encoded, forKey: InventoryColumn.widthDefaultsKey)
        }
    }
    @Published private(set) var disabledCatalogRuleKeys: Set<String>
    @Published var groupingMode: GroupingMode {
        didSet {
            UserDefaults.standard.set(groupingMode.rawValue, forKey: GroupingMode.defaultsKey)
            if selectedFilterID.hasPrefix("status.") || selectedFilterID.hasPrefix("mechanism.") {
                selectedFilterID = InventoryScope.allInOne.id
            }
        }
    }

    private let supportPreferences: SupportPreferences
    private let scanner: ApplicationScanner
    private let detector: UpdateDetectionEngine
    private let catalogService: RemoteCatalogService
    private let updateChecker: UpdateCheckService
    private var historyStore: InstallationHistoryStore

    init(
        scanner: ApplicationScanner = ApplicationScanner(),
        detector: UpdateDetectionEngine = UpdateDetectionEngine(),
        catalogService: RemoteCatalogService = .shared,
        updateChecker: UpdateCheckService = UpdateCheckService(),
        initialApplications: [InstalledApplication] = [],
        supportPreferences: SupportPreferences = SupportPreferences(),
        historyStore: InstallationHistoryStore? = nil
    ) {
        self.supportPreferences = supportPreferences
        self.scanner = scanner
        self.detector = detector
        self.catalogService = catalogService
        self.updateChecker = updateChecker
        self.historyStore = historyStore ?? InstallationHistoryStore(
            fileURL: initialApplications.isEmpty ? InstallationHistoryStore.defaultURL : nil
        )
        let savedMode = UserDefaults.standard.string(forKey: GroupingMode.defaultsKey)
        groupingMode = GroupingMode(rawValue: savedMode ?? "") ?? .mechanismStatus
        let savedDefaultView = UserDefaults.standard.string(forKey: InventorySettings.defaultViewKey)
        let defaultView = DefaultInventoryView(rawValue: savedDefaultView ?? "")
            ?? InventorySettings.defaultView
        selectedFilterID = defaultView.filterID
        let savedColumns = UserDefaults.standard.stringArray(forKey: InventoryColumn.defaultsKey) ?? []
        let restoredColumns = Set(savedColumns.compactMap(InventoryColumn.init(rawValue:)))
        visibleColumns = restoredColumns.isEmpty ? InventoryColumn.defaults : restoredColumns.union(InventoryColumn.required)
        let savedWidths = UserDefaults.standard.dictionary(forKey: InventoryColumn.widthDefaultsKey) ?? [:]
        columnWidths = Dictionary(uniqueKeysWithValues: InventoryColumn.allCases.map { column in
            let value = (savedWidths[column.rawValue] as? NSNumber)?.doubleValue
            return (column, max(column.minimumWidth, CGFloat(value ?? Double(column.defaultWidth))))
        })
        disabledCatalogRuleKeys = Set(
            UserDefaults.standard.stringArray(forKey: CatalogSettings.disabledRuleKeysKey) ?? []
        )
        applications = initialApplications
        historyEvents = self.historyStore.events
        if self.historyStore.loadError != nil {
            historyError = String(localized: "History could not be read or saved.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var selectedApplication: InstalledApplication? {
        applications.first(where: { $0.id == selectedApplicationID })
    }

    func historyEvents(for applicationID: String) -> [InstallationHistoryEvent] {
        historyEvents.filter { $0.itemID == applicationID }
    }

    var menuBarUpdateSummary: MenuBarUpdateSummary {
        MenuBarUpdateSummary.count(applications)
    }

    var isCatalogMatchingEnabled: Bool {
        UserDefaults.standard.object(forKey: CatalogSettings.matchingEnabledKey) as? Bool
            ?? CatalogSettings.defaultMatchingEnabled
    }

    var enabledCatalogRuleCount: Int {
        guard isCatalogMatchingEnabled, let catalog = catalogSnapshot?.catalog else { return 0 }
        return catalog.entries.lazy.filter { self.isCatalogEntryEnabled($0) }.count
    }

    func isCatalogEntryEnabled(_ entry: CatalogEntry) -> Bool {
        guard let catalogID = catalogSnapshot?.catalog.catalogID else { return false }
        let key = CatalogActivationPolicy.ruleKey(catalogID: catalogID, entryID: entry.id)
        return !disabledCatalogRuleKeys.contains(key)
    }

    func setCatalogEntry(_ entry: CatalogEntry, enabled: Bool) {
        guard let catalogID = catalogSnapshot?.catalog.catalogID else { return }
        let key = CatalogActivationPolicy.ruleKey(catalogID: catalogID, entryID: entry.id)
        if enabled {
            disabledCatalogRuleKeys.remove(key)
        } else {
            disabledCatalogRuleKeys.insert(key)
        }
        UserDefaults.standard.set(
            disabledCatalogRuleKeys.sorted(),
            forKey: CatalogSettings.disabledRuleKeysKey
        )
    }

    var scopeFilters: [InventoryFilter] {
        InventoryScope.allCases.filter { scope in
            scope != .containers || applications.contains(where: scope.includes) || selectedFilterID == scope.id
        }.map { scope in
            InventoryFilter(
                id: scope.id,
                title: scope.title,
                symbolName: scope.symbolName,
                count: applications.lazy.filter(scope.includes).count,
                kind: .scope(scope)
            )
        }
    }

    var libraryFilters: [InventoryFilter] {
        scopeFilters.filter { filter in
            guard case .scope(let scope) = filter.kind else { return false }
            return scope != .games && scope != .packageManagers
        }
    }

    var gameFilters: [InventoryFilter] {
        let allGames = InventoryFilter(
            id: InventoryScope.games.id,
            title: InventoryScope.games.title,
            symbolName: InventoryScope.games.symbolName,
            count: applications.lazy.filter(\.contributesToGameCount).count,
            kind: .scope(.games)
        )

        let platforms: [InventoryFilter] = GamePlatformKind.allCases.compactMap { platform in
            let count = applications.lazy.filter {
                $0.contributesToGameCount && platform.includes($0)
            }.count
            let id = "game-platform.\(platform.rawValue)"
            guard count > 0 || selectedFilterID == id else { return nil }
            return InventoryFilter(
                id: id,
                title: platform.title,
                symbolName: platform.symbolName,
                count: count,
                kind: .gamePlatform(platform)
            )
        }
        return [allGames] + platforms
    }

    var packageManagerFilters: [InventoryFilter] {
        let allItems = InventoryFilter(
            id: InventoryScope.packageManagers.id,
            title: String(localized: "All Package Items", bundle: AppL10n.bundle, locale: AppL10n.locale),
            symbolName: InventoryScope.packageManagers.symbolName,
            count: applications.lazy.filter(InventoryScope.packageManagers.includes).count,
            kind: .scope(.packageManagers)
        )

        let managers: [InventoryFilter] = PackageManagerKind.allCases.compactMap { manager in
            let count = applications.lazy.filter { manager.includes($0) }.count
            let id = "package-manager.\(manager.rawValue)"
            guard count > 0 || selectedFilterID == id else { return nil }
            return InventoryFilter(
                id: id,
                title: manager.title,
                symbolName: manager.symbolName,
                count: count,
                kind: .packageManager(manager)
            )
        }
        return [allItems] + managers
    }

    /// Primary navigation answers status and inventory questions. Specialist views remain
    /// reachable below without competing with the main destinations or repeating their rows.
    var primaryStatusFilters: [InventoryFilter] {
        let ids = ["update.updateAvailable", "update.upToDate", "update.checkFailed", "update.sourcePending"]
        return ids.compactMap { id in updateStatusFilters.first { $0.id == id } }
    }

    var primaryLibraryFilters: [InventoryFilter] {
        let ids = [
            InventoryScope.allInOne.id, InventoryScope.applications.id, InventoryScope.games.id,
            InventoryScope.packageManagers.id, InventoryScope.commandLineTools.id,
            InventoryScope.virtualMachinesAndBottles.id, InventoryScope.containers.id
        ]
        return ids.compactMap { id in filters.first { $0.id == id } }
    }

    var additionalFilters: [InventoryFilter] {
        let primaryIDs = Set((primaryStatusFilters + primaryLibraryFilters).map(\.id))
        return filters.filter { !primaryIDs.contains($0.id) }
    }

    var updateStatusFilters: [InventoryFilter] {
        let persistentStatuses: Set<UpdateAvailability> = [.updateAvailable, .upToDate]
        let order: [UpdateAvailability] = [
            .updateAvailable,
            .upToDate,
            .checking,
            .notChecked,
            .checkFailed,
            .sourcePending,
            .managedExternally,
            .managedBySystem
        ]

        return order.compactMap { availability in
            let count = applications.lazy.filter {
                self.matchesUpdateAvailability($0, availability)
            }.count
            guard count > 0 || persistentStatuses.contains(availability)
                || selectedFilterID == "update.\(availability.rawValue)" else { return nil }
            return InventoryFilter(
                id: "update.\(availability.rawValue)",
                title: availability.title,
                symbolName: availability.symbolName,
                count: count,
                kind: .updateAvailability(availability)
            )
        }
    }

    var updateStatsFilters: [InventoryFilter] {
        UpdateStatKind.allCases.map { stat in
            InventoryFilter(
                id: "update-stat.\(stat.rawValue)",
                title: stat.title,
                symbolName: stat.symbolName,
                count: applications.lazy.filter(stat.includes).count,
                kind: .updateStat(stat)
            )
        }
    }

    var groupingFilters: [InventoryFilter] {
        var result: [InventoryFilter] = []
        switch groupingMode {
        case .mechanismStatus:
            result += UpdateSupportStatus.allCases.compactMap { status in
                let count = applications.lazy.filter {
                    $0.participatesInPrimaryApplicationViews && $0.status == status
                }.count
                guard count > 0 || selectedFilterID == "status.\(status.rawValue)" else { return nil }
                return InventoryFilter(
                    id: "status.\(status.rawValue)",
                    title: status.title,
                    symbolName: status.symbolName,
                    count: count,
                    kind: .status(status)
                )
            }
        case .updateMechanism:
            result += UpdateMechanismKind.allCases.compactMap { mechanism in
                let count = applications.lazy.filter {
                    $0.participatesInPrimaryApplicationViews && $0.mechanism == mechanism
                }.count
                guard count > 0 || selectedFilterID == "mechanism.\(mechanism.rawValue)" else { return nil }
                return InventoryFilter(
                    id: "mechanism.\(mechanism.rawValue)",
                    title: mechanism.title,
                    symbolName: mechanism.symbolName,
                    count: count,
                    kind: .mechanism(mechanism)
                )
            }
        }

        return result
    }

    var filters: [InventoryFilter] {
        libraryFilters + updateStatusFilters + updateStatsFilters + gameFilters + packageManagerFilters + groupingFilters
    }

    var selectedFilterTitle: String {
        filters.first(where: { $0.id == selectedFilterID })?.title ?? "Software"
    }

    var selectedFilterDescription: String {
        guard let filter = filters.first(where: { $0.id == selectedFilterID }) else {
            return String(localized: "Detected software and its update ownership.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
        switch filter.kind {
        case .scope(.allInOne):
            return String(localized: "Every detected app, game client, managed component, and package.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.applications):
            return String(localized: "Applications together with the software they manage.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.directUpdateCapable):
            return String(localized: "Applications and packages that support direct, built-in, or automated updates.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.virtualMachinesAndBottles):
            return String(localized: "Virtual machine managers, guest operating systems, and Windows compatibility bottles.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.commandLineTools):
            return String(localized: "Command-line tools found at documented standalone paths, separate from package-manager inventory.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.games):
            return String(localized: "Installed games, game clients, instances, runtimes, and mods.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.packageManagers):
            return String(localized: "Packages and command-line tools tracked by their package managers.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .scope(.containers):
            return String(localized: "Local Docker connections, Compose projects, containers, images and volumes. These are separate objects, not application counts.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .status(let status):
            return String(format: String(localized: "Update mechanism classification: %@.", bundle: AppL10n.bundle, locale: AppL10n.locale), status.title)
        case .updateAvailability(let availability):
            return switch availability {
            case .notChecked: String(localized: "Software that has not been checked for updates yet.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .checking: String(localized: "Software being checked for updates right now.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .upToDate: String(localized: "Software confirmed to have the latest version.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .updateAvailable: String(localized: "Software with a newer version available.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .checkFailed: String(localized: "Software whose update check failed. Scan again to retry.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .sourcePending: String(localized: "Software without a known update source yet.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .managedExternally: String(localized: "Software updated by another app, such as a launcher or package manager.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            case .managedBySystem: String(localized: "Apple software that macOS keeps up to date.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        case .gamePlatform(let platform):
            return String(format: String(localized: "Installed games and clients for %@.", bundle: AppL10n.bundle, locale: AppL10n.locale), platform.title)
        case .packageManager(let manager):
            return String(format: String(localized: "Items installed and tracked by %@.", bundle: AppL10n.bundle, locale: AppL10n.locale), manager.title)
        case .mechanism(let mechanism):
            return mechanism.explanation
        case .updateStat(.applications):
            return String(localized: "Application updates that are ready for review.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateStat(.packageManagers):
            return String(localized: "Package-manager updates that are ready for review.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .updateStat(.autoUpdateReady):
            return String(localized: "Updates ready for software with direct or automated update support.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    private var directlyMatchedApplications: [InstalledApplication] {
        let selectedFilter = filters.first(where: { $0.id == selectedFilterID })?.kind
            ?? .scope(.allInOne)
        return applications.filter { application in
            let matchesFilter: Bool
            switch selectedFilter {
            case .scope(let scope):
                matchesFilter = scope.includes(application)
            case .status(let status):
                matchesFilter = application.participatesInPrimaryApplicationViews
                    && application.status == status
            case .updateAvailability(let availability):
                matchesFilter = matchesUpdateAvailability(application, availability)
            case .gamePlatform(let platform):
                matchesFilter = platform.includes(application)
            case .packageManager(let manager):
                matchesFilter = manager.includes(application)
            case .mechanism(let mechanism):
                matchesFilter = application.participatesInPrimaryApplicationViews
                    && application.mechanism == mechanism
            case .updateStat(let stat):
                matchesFilter = stat.includes(application)
            }

            let matchesSearch = searchText.isEmpty
                || application.name.localizedCaseInsensitiveContains(searchText)
                || application.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
                || application.mechanismName.localizedCaseInsensitiveContains(searchText)
                || application.kind.title.localizedCaseInsensitiveContains(searchText)
                || application.gamePlatform?.title.localizedCaseInsensitiveContains(searchText) == true
                || application.packageProvenance?.identifier.localizedCaseInsensitiveContains(searchText) == true
            return matchesFilter && matchesSearch
        }
    }

    private var matchingApplications: [InstalledApplication] {
        let selectedFilter = filters.first(where: { $0.id == selectedFilterID })?.kind
            ?? .scope(.allInOne)
        let directlyMatched = directlyMatchedApplications
        var includedIDs = Set(directlyMatched.map(\.id))
        switch selectedFilter {
        case .updateAvailability(.upToDate):
            // An outdated owner must not appear in Up to Date just to provide hierarchy.
            break
        default:
            for application in directlyMatched {
                includeAncestors(of: application, in: &includedIDs)
            }
        }
        if case .scope(.allInOne) = selectedFilter {
            // All inventory items already match; this keeps the complete ownership tree intact.
        } else if case .status(.managedExternally) = selectedFilter {
            for application in directlyMatched { includeDescendants(of: application, in: &includedIDs) }
        } else if case .scope(.games) = selectedFilter {
            for application in directlyMatched { includeDescendants(of: application, in: &includedIDs) }
        } else if case .scope(.virtualMachinesAndBottles) = selectedFilter {
            for application in directlyMatched { includeDescendants(of: application, in: &includedIDs) }
        } else if case .gamePlatform = selectedFilter {
            for application in directlyMatched { includeDescendants(of: application, in: &includedIDs) }
        }
        return applications.filter { includedIDs.contains($0.id) }
    }

    private func matchesUpdateAvailability(_ application: InstalledApplication,
                                           _ availability: UpdateAvailability) -> Bool {
        guard application.updateCheck.availability == availability else { return false }
        if availability == .updateAvailable { return !application.isExcludedFromMainUpdateList }
        if availability == .upToDate { return managedUpdateCount(for: application) == 0 }
        return true
    }

    var matchingApplicationIDs: Set<String> { Set(matchingApplications.map(\.id)) }

    var visibleApplications: [InstalledApplication] {
        hierarchicalSort(matchingApplications)
    }

    func toggleColumn(_ column: InventoryColumn) {
        guard !column.isRequired else { return }
        if visibleColumns.contains(column) { visibleColumns.remove(column) }
        else { visibleColumns.insert(column) }
        visibleColumns.formUnion(InventoryColumn.required)
    }

    func width(for column: InventoryColumn) -> CGFloat {
        columnWidths[column] ?? column.defaultWidth
    }

    func setColumnWidth(_ width: CGFloat, for column: InventoryColumn) {
        guard width.isFinite else { return }
        let resolved = max(column.minimumWidth, width)
        if columnWidths[column] != resolved { columnWidths[column] = resolved }
    }

    func sort(by column: InventoryColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    func start() async {
        backgroundChecks.start()
        catalogRefreshes.start()
        guard applications.isEmpty else { return }
        await scan(purpose: .applicationLaunch)
    }

    enum ScanTrigger { case manual, scheduled }

    func scan(purpose: CatalogLoadPurpose = .scan, trigger: ScanTrigger = .manual) async {
        guard !isScanning, DirectUpdateService.shared.activeApplicationID == nil, !Task.isCancelled else { return }
        isScanning = true
        isForegroundScan = trigger == .manual
        scanError = nil
        scanPhase = ScanPhase.packages.title
        let control = ScanControl()
        scanControl = control
        let previousSequence = completedScanSequence
        let task = Task { await self.performScan(purpose: purpose, control: control, trigger: trigger) }
        activeScan = task
        let timeout = Task {
            do { try await Task.sleep(until: control.deadline, clock: .continuous) }
            catch { return }
            task.cancel()
        }
        await withTaskCancellationHandler { await task.value } onCancel: { control.cancel(); task.cancel() }
        timeout.cancel()
        activeScan = nil
        scanControl = nil
        isScanning = false
        isForegroundScan = false
        if completedScanSequence != previousSequence, let date = lastScanDate {
            backgroundChecks.scanCompleted(at: date)
            if purpose.requiresRemoteRefresh {
                catalogRefreshes.recordRefresh(success: catalogSnapshot?.warning == nil)
            }
            if scanError == nil, !Task.isCancelled, !control.isCancelled {
                await UpdateNotificationService.shared.processCompletedScan(applications)
            }
        }
    }

    /// Settings shows the bundled or cached catalog before the first scan; this never
    /// contacts the network, so opening Settings cannot trigger a catalog download.
    func loadLocalCatalogIfNeeded() async {
        guard catalogSnapshot == nil else { return }
        let snapshot = await catalogService.snapshot(for: .localOnly)
        if catalogSnapshot == nil { catalogSnapshot = snapshot }
    }

    private func refreshCatalogInBackground() async -> Bool {
        guard !isScanning else { return false }
        let snapshot = await catalogService.snapshot(for: .scan)
        guard !Task.isCancelled, !isScanning else { return false }

        let changed = catalogSnapshot?.catalog.catalogID != snapshot.catalog.catalogID
            || catalogSnapshot?.catalog.revision != snapshot.catalog.revision
            || (catalogSnapshot?.source == .bundled) != (snapshot.source == .bundled)
        if changed {
            // The transport has already validated and cached the new document.
            // Reclassify inventory from that copy without making a second request.
            let previousSequence = completedScanSequence
            await scan(purpose: .localOnly, trigger: .scheduled)
            return completedScanSequence != previousSequence && snapshot.warning == nil
        }
        catalogSnapshot = snapshot
        return snapshot.warning == nil
    }

    func requestUpdate(_ application: InstalledApplication) {
        guard !isScanning, let current = applications.first(where: { $0.id == application.id }) else { return }
        DirectUpdateService.shared.requestUpdate(current) { [weak self] in
            await self?.refreshApplication(current)
        }
    }

    /// A completed installer refreshes one installation, never the whole inventory.
    /// Injectable dependencies let tests prove that unrelated rows/sources stay untouched.
    func refreshApplication(
        _ application: InstalledApplication,
        read: @escaping @Sendable (InstalledApplication, ScanControl) async throws -> ApplicationCandidate = {
            try await ApplicationRefreshService().read($0, control: $1)
        },
        check: @escaping @Sendable ([InstalledApplication], ScanControl) async -> [InstalledApplication] = {
            await UpdateCheckService().check($0, control: $1)
        }
    ) async {
        guard !isScanning, applications.contains(where: { $0.id == application.id }),
              DirectUpdateService.shared.activeApplicationID == nil
                || DirectUpdateService.shared.activeApplicationID == application.id else { return }
        isScanning = true
        isForegroundScan = true
        scanPhase = String(localized: "Checking now…", bundle: AppL10n.bundle, locale: AppL10n.locale) + " " + application.name
        let control = ScanControl()
        scanControl = control
        let task = Task {
            do {
                let candidate = try await read(application, control)
                guard !Task.isCancelled, !control.shouldStop else { self.finishInterruptedScan(control); return }
                guard candidate.inventoryID == application.id,
                      candidate.bundleIdentifier == application.bundleIdentifier else {
                    throw ApplicationRefreshService.Failure.identityChanged
                }
                let snapshot = await self.catalogService.snapshot(for: self.isCatalogMatchingEnabled ? .localOnly : .disabled)
                let catalog = CatalogActivationPolicy.applying(to: snapshot.catalog,
                    matchingEnabled: self.isCatalogMatchingEnabled, disabledRuleKeys: self.disabledCatalogRuleKeys)
                guard !Task.isCancelled, !control.shouldStop else { self.finishInterruptedScan(control); return }
                let detected = self.detector.classify([candidate], catalog: catalog)
                let checked = await check(detected, control)
                guard let updated = checked.first, checked.count == 1, updated.id == application.id else {
                    throw ApplicationRefreshService.Failure.identityChanged
                }
                guard !Task.isCancelled, !control.shouldStop else { self.finishInterruptedScan(control); return }
                self.applyApplicationRefresh(updated)
            } catch {
                guard !Task.isCancelled, !control.shouldStop else { self.finishInterruptedScan(control); return }
                // Keep the row/identity but replace its stale success/update result with a failure.
                if let index = self.applications.firstIndex(where: { $0.id == application.id }) {
                    self.applications[index].updateCheck = UpdateCheckResult(availability: .checkFailed,
                        installedVersion: application.displayVersion, latestVersion: nil, checkedAt: Date(),
                        source: application.updateCheck.source, detail: error.localizedDescription)
                }
            }
        }
        activeScan = task
        let timeout = Task {
            do { try await Task.sleep(until: control.deadline, clock: .continuous) } catch { return }
            control.cancel()
            task.cancel()
        }
        await withTaskCancellationHandler { await task.value } onCancel: { control.cancel(); task.cancel() }
        timeout.cancel()
        activeScan = nil
        scanControl = nil
        isScanning = false
        isForegroundScan = false
        clearSelectionIfHidden()
        // A partial refresh does not advance full-scan date, notification digest,
        // periodic scheduling or the three-scan support counter.
    }

    private func applyApplicationRefresh(_ updated: InstalledApplication) {
        guard let index = applications.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = applications[index]
        applications[index] = updated
        do {
            try historyStore.recordRefresh(updated, previous: previous, at: Date())
            historyEvents = historyStore.events
            historyError = nil
        } catch {
            historyError = String(localized: "History could not be read or saved.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    func cancelScan() {
        scanPhase = String(localized: "Stopping scan…", bundle: AppL10n.bundle, locale: AppL10n.locale)
        scanControl?.cancel()
        activeScan?.cancel()
    }

    private func finishInterruptedScan(_ control: ScanControl) {
        scanError = control.hasTimedOut
            ? String(localized: "The scan reached its time limit. Previous results are unchanged. Scan again to retry.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            : String(localized: "Scan cancelled. Previous results are unchanged.", bundle: AppL10n.bundle, locale: AppL10n.locale)
    }

    private func performScan(purpose: CatalogLoadPurpose, control: ScanControl, trigger: ScanTrigger) async {
        async let catalogTask = catalogService.snapshot(for: purpose)
        let includeSystemApplications = UserDefaults.standard.object(
            forKey: InventorySettings.includeSystemApplicationsKey
        ) as? Bool ?? InventorySettings.defaultIncludeSystemApplications
        async let applicationsTask = scanner.scanWithFindings(
            includeSystemApplications: includeSystemApplications, control: control,
            progress: { [weak self] phase in
                Task { @MainActor in
                    guard self?.isScanning == true, !control.shouldStop else { return }
                    self?.scanPhase = phase.title
                }
            }
        )
        let (snapshot, scanResult) = await (catalogTask, applicationsTask)
        let effectiveCatalog = CatalogActivationPolicy.applying(
            to: snapshot.catalog,
            matchingEnabled: isCatalogMatchingEnabled,
            disabledRuleKeys: disabledCatalogRuleKeys
        )
        let detected = detector.classify(scanResult.candidates, catalog: effectiveCatalog)
        guard !Task.isCancelled, !control.shouldStop else { finishInterruptedScan(control); return }
        scanPhase = ScanPhase.updateSources.title
        let checked = await updateChecker.check(detected, control: control)
        guard !Task.isCancelled, !control.shouldStop else { finishInterruptedScan(control); return }

        let scanDate = Date()
        if scanResult.diagnostics.isEmpty {
            do {
                try historyStore.recordScan(checked, at: scanDate, isComplete: true)
                historyEvents = historyStore.events
                historyError = nil
            } catch {
                historyError = String(localized: "History could not be read or saved.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }
        catalogSnapshot = snapshot
        applications = checked
        directInstallRemnants = scanResult.directInstallRemnants
        lastScanDate = scanDate
        expandedManagerIDs = Set(
            checked
                .filter { parent in
                    checked.contains {
                        $0.parentInventoryID == parent.id
                            || ($0.parentInventoryID == nil
                                && $0.parentManagerBundleIdentifier == parent.bundleIdentifier)
                    }
                }
                .map(\.id)
        )

        if let selectedApplicationID,
           !checked.contains(where: { $0.id == selectedApplicationID }) {
            self.selectedApplicationID = nil
        }
        clearSelectionIfHidden()

        scanDiagnostics = scanResult.diagnostics
        scanError = snapshot.warning
        if !scanDiagnostics.isEmpty {
            let warning = String(localized: "Partial scan: some environments could not be checked.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            scanError = [scanError, warning].compactMap { $0 }.joined(separator: " ")
        }
        // Source-check failures do not invalidate a completed inventory. A scan warning,
        // cancellation or empty inventory must not advance the support counter.
        recordSupportScanCompletion(successful: scanError == nil, itemCount: checked.count, trigger: trigger)
        completedScanSequence += 1
        if let ids = pendingNotificationIDs {
            pendingNotificationIDs = nil
            revealNotificationItems(ids)
        }
    }

    func recordSupportScanCompletion(successful: Bool, itemCount: Int, trigger: ScanTrigger = .manual) {
        guard trigger == .manual else { return }
        supportPreferences.recordCompletedScan(successful: successful, itemCount: itemCount)
        if supportPreferences.shouldPresentReminder(destination: SupportSettings.configuredURL) {
            isSupportReminderPresented = true
        }
    }

    func markSupportReminderShown() {
        supportPreferences.markReminderShown()
    }

    func dismissSupportReminder() {
        supportPreferences.dismissReminder()
        isSupportReminderPresented = false
    }

    func toggleExpanded(_ application: InstalledApplication) {
        if expandedManagerIDs.contains(application.id) {
            expandedManagerIDs.remove(application.id)
        } else {
            expandedManagerIDs.insert(application.id)
        }
    }

    func hasManagedChildren(_ application: InstalledApplication, among ids: Set<String>) -> Bool {
        applications.contains {
            ids.contains($0.id) && isDirectChild($0, of: application)
        }
    }

    func hierarchyDepth(of application: InstalledApplication, among ids: Set<String>) -> Int {
        var depth = 0
        var current = application
        var seen = Set<String>()
        while let owner = parent(of: current), ids.contains(owner.id), seen.insert(owner.id).inserted {
            depth += 1
            current = owner
        }
        return depth
    }

    func managedUpdateCount(for application: InstalledApplication) -> Int {
        var visited = Set<String>()

        func countDescendants(of parent: InstalledApplication) -> Int {
            guard visited.insert(parent.id).inserted else { return 0 }
            return applications
                .filter { isDirectChild($0, of: parent) }
                .reduce(into: 0) { total, child in
                    if child.updateCheck.availability == .updateAvailable { total += 1 }
                    total += countDescendants(of: child)
                }
        }

        return countDescendants(of: application)
    }

    func isVisibleByExpansion(_ application: InstalledApplication) -> Bool {
        guard let parent = parent(of: application) else {
            return true
        }
        return expandedManagerIDs.contains(parent.id) && isVisibleByExpansion(parent)
    }

    func hierarchyDepth(of application: InstalledApplication) -> Int {
        var depth = 0
        var current = application
        var seen = Set<String>()
        while let parent = parent(of: current), seen.insert(parent.id).inserted {
            depth += 1
            current = parent
        }
        return depth
    }

    func managerApplicationURL(for application: InstalledApplication) -> URL? {
        let bundleID = application.parentManagerBundleIdentifier
            ?? (application.mechanism == .externalManager ? application.bundleIdentifier : nil)
        guard let bundleID else { return nil }
        if let manager = parent(of: application), manager.bundleIdentifier == bundleID,
           manager.path.hasSuffix(".app"), manager.existsOnDisk {
            let url = URL(fileURLWithPath: manager.path)
            if Bundle(url: url)?.bundleIdentifier == bundleID { return url }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: url)?.bundleIdentifier == bundleID else { return nil }
        return url
    }

    func inlineOpenAction(for application: InstalledApplication) -> MenuBarUpdateAction? {
        MenuBarUpdateAction.inlineOpen(
            for: application,
            updateAction: ManagerUpdatePolicy.action(for: application),
            managerAvailable: managerApplicationURL(for: application) != nil,
            applicationAvailable: application.path.hasSuffix(".app") && application.existsOnDisk,
            releasePageAvailable: MenuBarUpdateAction.releasePageURL(for: application) != nil,
            websiteAvailable: MenuBarUpdateAction.safeWebURL(application.vendorURL) != nil
        )
    }

    func openManager(for application: InstalledApplication) {
        guard DirectUpdateService.shared.activeApplicationID != application.id,
              let url = managerApplicationURL(for: application) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func showUpdateList() {
        searchText = ""
        selectedApplicationID = nil
        selectedFilterID = DefaultInventoryView.updateAvailable.filterID
    }

    func revealNotificationItems(_ ids: [String]) {
        searchText = ""
        selectedFilterID = "update.updateAvailable"
        selectedApplicationID = nil
        let notified = Set(ids)
        for item in applications where notified.contains(CLIInventoryQuery.opaqueID(item.id))
            || (ids.isEmpty && item.updateCheck.availability == .updateAvailable) {
            expandAncestors(of: item)
        }
        if applications.isEmpty {
            pendingNotificationIDs = ids
        } else if ids.count == 1, let item = applications.first(where: {
            CLIInventoryQuery.opaqueID($0.id) == ids[0] && $0.updateCheck.availability == .updateAvailable
        }) {
            revealApplication(id: item.id)
        }
    }

    func revealApplication(id: String) {
        guard let application = applications.first(where: { $0.id == id }) else { return }
        searchText = ""
        selectedFilterID = InventoryScope.allInOne.id
        expandAncestors(of: application)
        selectedApplicationID = id
    }

    private func expandAncestors(of application: InstalledApplication) {
        var current = application
        var visited = Set<String>()
        while let owner = parent(of: current), visited.insert(owner.id).inserted {
            expandedManagerIDs.insert(owner.id)
            current = owner
        }
    }

    func showInFinder(_ application: InstalledApplication) {
        let path = application.packageProvenance?.installLocation ?? application.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var visibleTableApplicationIDs: [String] {
        visibleApplications.map(\.id)
    }

    func selectAdjacent(offset: Int) {
        let ids = visibleTableApplicationIDs
        selectedApplicationID = SelectionNavigator.adjacentID(
            in: ids,
            current: selectedApplicationID,
            offset: offset
        )
    }

    func clearSelection() {
        selectedApplicationID = nil
    }

    func clearSelectionIfHidden() {
        guard let selectedApplicationID else { return }
        if !visibleTableApplicationIDs.contains(selectedApplicationID) {
            self.selectedApplicationID = nil
        }
    }

    func openVendorWebsite(_ application: InstalledApplication) {
        guard let vendorURL = application.vendorURL else { return }
        NSWorkspace.shared.open(vendorURL)
    }

    func openApplication(_ application: InstalledApplication) {
        let url = URL(fileURLWithPath: application.path)
        guard application.path.hasSuffix(".app"), application.existsOnDisk,
              DirectUpdateService.shared.activeApplicationID != application.id else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

    func openAppStore(for application: InstalledApplication) {
        Task {
            do {
                let url = try await updateChecker.appStorePage(for: application)
                let storeURL = URL(string: url.absoluteString.replacingOccurrences(of: "https://", with: "macappstores://")) ?? url
                if !NSWorkspace.shared.open(storeURL) {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                if let fallback = URL(string: "macappstores://apps.apple.com/") {
                    NSWorkspace.shared.open(fallback)
                }
            }
        }
    }

    private func hierarchicalSort(_ input: [InstalledApplication]) -> [InstalledApplication] {
        let inputIDs = Set(input.map(\.id))
        let roots = input.filter { application in
            guard let parent = parent(of: application) else { return true }
            return !inputIDs.contains(parent.id)
        }.sorted(by: ordered)

        func appendTree(_ application: InstalledApplication, to result: inout [InstalledApplication]) {
            result.append(application)
            guard expandedManagerIDs.contains(application.id) else { return }
            for child in input.filter({ isDirectChild($0, of: application) }).sorted(by: ordered) {
                appendTree(child, to: &result)
            }
        }

        var result: [InstalledApplication] = []
        for root in roots { appendTree(root, to: &result) }
        return result
    }

    private func ordered(_ lhs: InstalledApplication, _ rhs: InstalledApplication) -> Bool {
        let comparison: ComparisonResult
        switch sortColumn {
        case .name:
            comparison = lhs.name.localizedStandardCompare(rhs.name)
        case .installedVersion:
            comparison = VersionComparator.compare(lhs.displayVersion, rhs.displayVersion)
        case .type:
            comparison = lhs.kind.title.localizedStandardCompare(rhs.kind.title)
        case .parent:
            comparison = (lhs.parentManagerName ?? "").localizedStandardCompare(rhs.parentManagerName ?? "")
        case .updateMechanism:
            comparison = lhs.mechanismName.localizedStandardCompare(rhs.mechanismName)
        case .mechanismStatus:
            comparison = lhs.status.title.localizedStandardCompare(rhs.status.title)
        case .openSource:
            comparison = openSourceSortValue(lhs).localizedStandardCompare(openSourceSortValue(rhs))
        case .updateStatus:
            comparison = lhs.updateCheck.availability.title.localizedStandardCompare(rhs.updateCheck.availability.title)
        }
        if comparison == .orderedSame {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func openSourceSortValue(_ application: InstalledApplication) -> String {
        switch application.isOpenSource {
        case .some(true): String(localized: "Yes", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .some(false): String(localized: "No", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .none: String(localized: "Unknown", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    private func parent(of application: InstalledApplication) -> InstalledApplication? {
        if let parentID = application.parentInventoryID,
           let parent = applications.first(where: { $0.id == parentID }) { return parent }
        guard let bundleID = application.parentManagerBundleIdentifier else { return nil }
        return applications.first { $0.bundleIdentifier == bundleID }
    }

    private func isDirectChild(_ child: InstalledApplication, of parent: InstalledApplication) -> Bool {
        child.parentInventoryID == parent.id
            || (child.parentInventoryID == nil
                && child.parentManagerBundleIdentifier == parent.bundleIdentifier)
    }

    private func includeAncestors(of application: InstalledApplication, in ids: inout Set<String>) {
        guard let parent = parent(of: application), ids.insert(parent.id).inserted else { return }
        includeAncestors(of: parent, in: &ids)
    }

    private func includeDescendants(of application: InstalledApplication, in ids: inout Set<String>) {
        for child in applications where isDirectChild(child, of: application) {
            if ids.insert(child.id).inserted { includeDescendants(of: child, in: &ids) }
        }
    }

}

enum SelectionNavigator {
    static func adjacentID(in ids: [String], current: String?, offset: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return offset < 0 ? ids.last : ids.first
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}
