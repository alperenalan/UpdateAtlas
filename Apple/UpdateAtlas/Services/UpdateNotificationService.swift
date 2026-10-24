import AppKit
import UserNotifications

enum NotificationPermission: Equatable {
    case notRequested, allowed, denied
    var title: String {
        switch self {
        case .notRequested: String(localized: "Permission not requested", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .allowed: String(localized: "Notifications allowed", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .denied: String(localized: "Notifications disabled in macOS", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }
}

@MainActor
protocol UpdateNotificationDelivering {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> Bool
    func post(_ candidates: [UpdateNotificationCandidate], sound: Bool) async throws
    func clear()
}

@MainActor
final class SystemUpdateNotificationDelivery: UpdateNotificationDelivering {
    static let requestID = "update-atlas.new-updates"
    var center: UNUserNotificationCenter { .current() }
    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: .allowed
        case .notDetermined: .notRequested
        default: .denied
        }
    }
    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }
    func post(_ candidates: [UpdateNotificationCandidate], sound: Bool) async throws {
        let content = Self.content(for: candidates, sound: sound)
        try await center.add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil))
    }
    static func content(for candidates: [UpdateNotificationCandidate], sound: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if candidates.count == 1, let candidate = candidates.first {
            let version = String(candidate.version.prefix(40))
            content.title = String(candidate.name.prefix(60))
            content.body = String(format: String(localized: "Version %@ is available.", bundle: AppL10n.bundle, locale: AppL10n.locale), version)
        } else {
            content.title = AppL10n.plural("%lld updates available", singular: "%lld update available", count: candidates.count)
            var lines = candidates.prefix(3).map { String($0.name.prefix(60)) + " → " + String($0.version.prefix(40)) }
            if candidates.count > 3 {
                lines.append(AppL10n.plural("and %lld more", count: candidates.count - 3))
            }
            content.body = lines.joined(separator: "\n")
        }
        content.sound = sound ? .default : nil
        content.threadIdentifier = "update-atlas.updates"
        content.categoryIdentifier = "UPDATE_ATLAS_UPDATES"
        // A digest opens the update list; only a single-item alert needs a target ID.
        content.userInfo = ["itemIDs": candidates.count == 1 ? candidates.map(\.id) : []]
        return content
    }
    func clear() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }
}

@MainActor
final class UpdateNotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotificationService()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var permission: NotificationPermission = .notRequested
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let delivery: any UpdateNotificationDelivering
    private var permissionGeneration = 0
    private var isProcessing = false
    private var pendingInventory: [InstalledApplication]?
    private var openItems: (([String]) -> Void)?
    private var pendingOpenIDs: [String]?

    init(defaults: UserDefaults = .standard, delivery: (any UpdateNotificationDelivering)? = nil) {
        self.defaults = defaults
        self.delivery = delivery ?? SystemUpdateNotificationDelivery()
        isEnabled = UpdateNotificationSettings.isEnabled(in: defaults)
        super.init()
    }

    var soundEnabled: Bool {
        get { defaults.object(forKey: UpdateNotificationSettings.soundKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: UpdateNotificationSettings.soundKey); objectWillChange.send() }
    }

    var notifyApplications: Bool {
        get { defaults.object(forKey: UpdateNotificationSettings.notifyAppsKey) as? Bool ?? UpdateNotificationSettings.defaultNotifyApps }
        set { defaults.set(newValue, forKey: UpdateNotificationSettings.notifyAppsKey); objectWillChange.send() }
    }

    var notifyGames: Bool {
        get { defaults.object(forKey: UpdateNotificationSettings.notifyGamesKey) as? Bool ?? UpdateNotificationSettings.defaultNotifyGames }
        set { defaults.set(newValue, forKey: UpdateNotificationSettings.notifyGamesKey); objectWillChange.send() }
    }

    var notifyPackages: Bool {
        get { defaults.object(forKey: UpdateNotificationSettings.notifyPackagesKey) as? Bool ?? UpdateNotificationSettings.defaultNotifyPackages }
        set { defaults.set(newValue, forKey: UpdateNotificationSettings.notifyPackagesKey); objectWillChange.send() }
    }

    func sendTestNotification() async {
        errorMessage = nil
        let current = await delivery.permission()
        if current == .notRequested {
            _ = try? await delivery.requestPermission()
        }
        let status = await delivery.permission()
        permission = status
        guard status == .allowed else {
            errorMessage = String(localized: "Notifications are not allowed in macOS Settings.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            return
        }
        let sample = UpdateNotificationCandidate(
            id: AppIdentity.bundleIdentifier + ".test",
            fingerprint: "test-fingerprint",
            name: String(localized: "Update Atlas (Test)", bundle: AppL10n.bundle, locale: AppL10n.locale),
            version: "2.0.0"
        )
        do {
            try await delivery.post([sample], sound: soundEnabled)
        } catch {
            errorMessage = String(localized: "Test notification could not be delivered.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    func configureNativeCenter() {
        guard let native = delivery as? SystemUpdateNotificationDelivery else { return }
        native.center.delegate = self
        let action = UNNotificationAction(identifier: "OPEN_UPDATES", title: String(localized: "Open Update Atlas", bundle: AppL10n.bundle, locale: AppL10n.locale), options: .foreground)
        native.center.setNotificationCategories([UNNotificationCategory(identifier: "UPDATE_ATLAS_UPDATES", actions: [action], intentIdentifiers: [], options: [])])
    }

    func attach(openItems: @escaping ([String]) -> Void) {
        self.openItems = openItems
        if let ids = pendingOpenIDs { pendingOpenIDs = nil; openItems(ids) }
    }

    func refreshPermission() async {
        let generation = permissionGeneration
        let status = await delivery.permission()
        guard generation == permissionGeneration else { return }
        permission = status
    }

    func requestPermissionIfEnabled() async {
        guard isEnabled else { return }
        let generation = permissionGeneration
        let status = await delivery.permission()
        guard generation == permissionGeneration, isEnabled else { return }
        permission = status
        if status == .notRequested {
            await setEnabled(true)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        permissionGeneration += 1
        let generation = permissionGeneration
        isEnabled = enabled
        defaults.set(enabled, forKey: UpdateNotificationSettings.enabledKey)
        errorMessage = nil
        if !enabled {
            isRequestingPermission = false
            pendingInventory = nil
            delivery.clear()
            return
        }
        isRequestingPermission = true
        defer { if generation == permissionGeneration { isRequestingPermission = false } }
        let current = await delivery.permission()
        guard generation == permissionGeneration, isEnabled else { return }
        do {
            if current == .notRequested { _ = try await delivery.requestPermission() }
            guard generation == permissionGeneration, isEnabled else { return }
            let status = await delivery.permission()
            guard generation == permissionGeneration, isEnabled else { return }
            permission = status
        } catch {
            guard generation == permissionGeneration else { return }
            errorMessage = String(localized: "Notification permission could not be requested. Try again.", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    func processCompletedScan(_ inventory: [InstalledApplication]) async {
        guard isEnabled else { return }
        pendingInventory = inventory
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        while let items = pendingInventory {
            pendingInventory = nil
            let generation = permissionGeneration
            let status = await delivery.permission() // Never prompts during a scan.
            guard isEnabled, generation == permissionGeneration else { continue }
            permission = status
            guard status == .allowed else { continue }
            let ledger = UpdateNotificationLedger(defaults: defaults)
            let candidates = ledger.pending(in: items)
            guard !candidates.isEmpty else { continue }
            do {
                try await delivery.post(candidates, sound: soundEnabled)
                guard isEnabled, generation == permissionGeneration else { delivery.clear(); continue }
                ledger.record(candidates)
                errorMessage = nil
            } catch {
                guard isEnabled, generation == permissionGeneration else { continue }
                errorMessage = String(localized: "The update notification could not be delivered. It will be retried after the next completed scan.", bundle: AppL10n.bundle, locale: AppL10n.locale)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run {
            guard self.isEnabled else { return [] }
            return self.soundEnabled ? [.banner, .list, .sound] : [.banner, .list]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let ids = response.notification.request.content.userInfo["itemIDs"] as? [String] ?? []
        await handleOpen(ids)
    }

    func handleOpen(_ ids: [String]) {
        if let openItems { openItems(ids) } else { pendingOpenIDs = ids }
    }
}
