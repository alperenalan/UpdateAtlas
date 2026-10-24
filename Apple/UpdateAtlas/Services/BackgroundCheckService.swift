import AppKit

/// App-owned lifetime: closing a SwiftUI window must not cancel the schedule.
@MainActor
final class BackgroundCheckService: ObservableObject {
    @Published private(set) var nextCheckDate: Date?
    @Published private(set) var isRunningScheduledScan = false
    private let defaults: UserDefaults
    private let usesTimers: Bool
    private let now: () -> Date
    private let isBusy: () -> Bool
    private let isOnboarded: () -> Bool
    private let scan: () async -> Void
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isSleeping = false
    private var retryAfterWake = false
    private var hasStarted = false

    init(defaults: UserDefaults = .standard, usesTimers: Bool = true, now: @escaping () -> Date = Date.init,
         isBusy: @escaping () -> Bool, isOnboarded: @escaping () -> Bool,
         scan: @escaping () async -> Void) {
        self.defaults = defaults
        self.usesTimers = usesTimers
        self.now = now
        self.isBusy = isBusy
        self.isOnboarded = isOnboarded
        self.scan = scan
    }

    deinit {
        timer?.invalidate()
        scanTask?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var isEnabled: Bool { defaults.object(forKey: BackgroundCheckSettings.enabledKey) as? Bool ?? false }
    var interval: CheckInterval { BackgroundCheckSettings.interval(in: defaults) }

    func start(observeWorkspace: Bool = true) {
        if !hasStarted {
            hasStarted = true
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

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: BackgroundCheckSettings.enabledKey)
        if enabled, defaults.object(forKey: BackgroundCheckSettings.lastAttemptKey) == nil {
            defaults.set(now(), forKey: BackgroundCheckSettings.lastAttemptKey)
        }
        if !enabled { scanTask?.cancel(); retryAfterWake = false }
        refresh()
    }

    func setInterval(_ interval: CheckInterval) {
        defaults.set(interval.rawValue, forKey: BackgroundCheckSettings.intervalKey)
        refresh()
    }

    func scanCompleted(at date: Date) {
        defaults.set(date, forKey: BackgroundCheckSettings.lastAttemptKey)
        retryAfterWake = false
        refresh()
    }

    func systemWillSleep() {
        isSleeping = true
        if isRunningScheduledScan { retryAfterWake = true; scanTask?.cancel() }
        timer?.invalidate()
        timer = nil
        nextCheckDate = nil
    }

    func systemDidWake() {
        isSleeping = false
        if retryAfterWake {
            defaults.set(now().addingTimeInterval(-interval.seconds), forKey: BackgroundCheckSettings.lastAttemptKey)
        }
        refresh()
    }

    func refresh() {
        timer?.invalidate()
        timer = nil
        guard hasStarted, isEnabled, isOnboarded(), !isSleeping else { nextCheckDate = nil; return }
        if defaults.object(forKey: BackgroundCheckSettings.lastAttemptKey) == nil {
            defaults.set(now(), forKey: BackgroundCheckSettings.lastAttemptKey)
        }
        if let saved = defaults.object(forKey: BackgroundCheckSettings.lastAttemptKey) as? Date, saved > now() {
            defaults.set(now(), forKey: BackgroundCheckSettings.lastAttemptKey)
        }
        let due = BackgroundCheckSettings.nextCheck(in: defaults, now: now())
        nextCheckDate = due
        // Busy/reentrant scans get a bounded retry, never a rapid timer loop.
        let delay = due <= now() ? (isBusy() || isRunningScheduledScan ? 60 : 0.1) : due.timeIntervalSince(now())
        guard usesTimers else { return }
        let newTimer = Timer(timeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
        newTimer.tolerance = min(60, max(1, delay * 0.1))
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func checkIfDue() async {
        guard hasStarted, isEnabled, isOnboarded(), !isSleeping,
              BackgroundCheckSettings.nextCheck(in: defaults, now: now()) <= now(),
              !isBusy(), !isRunningScheduledScan else { refresh(); return }
        isRunningScheduledScan = true
        defaults.set(now(), forKey: BackgroundCheckSettings.lastAttemptKey)
        refresh()
        scanTask = Task { [weak self, scan] in
            guard !Task.isCancelled else { self?.finishScheduledScan(); return }
            await scan()
            self?.finishScheduledScan()
        }
        await scanTask?.value
    }

    private func finishScheduledScan() {
        isRunningScheduledScan = false
        scanTask = nil
        refresh()
    }
}
