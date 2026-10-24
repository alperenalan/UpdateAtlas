import AppKit

/// Checks the configured catalog while the app process is alive, even with no window open.
/// This schedule is independent of the opt-in full inventory scan schedule.
@MainActor
final class CatalogRefreshService {
    static let interval: TimeInterval = 6 * 3_600
    static let retryInterval: TimeInterval = 15 * 60

    private let usesTimers: Bool
    private let now: () -> Date
    private let isEligible: () -> Bool
    private let isBusy: () -> Bool
    private let refreshCatalog: () async -> Bool
    private var timer: Timer?
    private var refreshTask: Task<Bool, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isSleeping = false
    private var retryAfterWake = false
    private var hasStarted = false
    private(set) var nextCheckDate: Date?

    init(usesTimers: Bool = true, now: @escaping () -> Date = Date.init,
         isEligible: @escaping () -> Bool, isBusy: @escaping () -> Bool,
         refreshCatalog: @escaping () async -> Bool) {
        self.usesTimers = usesTimers
        self.now = now
        self.isEligible = isEligible
        self.isBusy = isBusy
        self.refreshCatalog = refreshCatalog
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func start(observeWorkspace: Bool = true) {
        if !hasStarted {
            hasStarted = true
            nextCheckDate = now().addingTimeInterval(Self.interval)
            if observeWorkspace {
                let center = NSWorkspace.shared.notificationCenter
                observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.systemWillSleep() }
                })
                observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.systemDidWake() }
                })
            }
        }
        refresh()
    }

    /// A launch or manual scan already fetched the catalog; avoid a second request.
    func recordRefresh(success: Bool) {
        guard hasStarted else { return }
        nextCheckDate = now().addingTimeInterval(success ? Self.interval : Self.retryInterval)
        refresh()
    }

    func systemWillSleep() {
        isSleeping = true
        if refreshTask != nil { retryAfterWake = true; refreshTask?.cancel() }
        timer?.invalidate()
        timer = nil
    }

    func systemDidWake() {
        isSleeping = false
        if retryAfterWake { nextCheckDate = now(); retryAfterWake = false }
        refresh()
    }

    func refresh() {
        timer?.invalidate()
        timer = nil
        guard hasStarted, isEligible(), !isSleeping else { return }
        let due = nextCheckDate ?? now().addingTimeInterval(Self.interval)
        nextCheckDate = due
        let delay = due <= now() ? (isBusy() || refreshTask != nil ? 60 : 0.1) : due.timeIntervalSince(now())
        guard usesTimers else { return }
        let newTimer = Timer(timeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        newTimer.tolerance = min(60, max(1, delay * 0.1))
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func checkIfDue() async {
        guard hasStarted, isEligible(), !isSleeping,
              nextCheckDate.map({ $0 <= now() }) == true,
              !isBusy(), refreshTask == nil else { refresh(); return }
        // Advance before awaiting so another timer cannot start the same request.
        nextCheckDate = now().addingTimeInterval(Self.interval)
        refreshTask = Task { [refreshCatalog] in await refreshCatalog() }
        let succeeded = await refreshTask?.value ?? false
        refreshTask = nil
        if isSleeping { retryAfterWake = true; return }
        recordRefresh(success: succeeded)
    }
}
