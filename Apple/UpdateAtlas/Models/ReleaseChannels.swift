import Foundation

enum ReleaseChannelSettings {
    static let allowPrereleaseForStableKey = "release-channels.allow-prerelease-for-stable"
    static let defaultAllowPrereleaseForStable = false
    static func current(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: allowPrereleaseForStableKey) as? Bool ?? defaultAllowPrereleaseForStable
    }
}

struct ReleaseChannel: Hashable, Sendable, Identifiable, Codable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case stable
        case lts
        case releaseCandidate
        case beta
        case alpha
        case canary
        case nightly
        case custom
    }

    let kind: Kind
    let vendorName: String?

    var id: String { rawValue }

    init(kind: Kind, vendorName: String? = nil) {
        self.kind = kind
        self.vendorName = vendorName
    }

    init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalized(trimmed)
        switch normalized {
        case "", "stable", "release", "production", "default":
            self.init(kind: .stable)
        case "lts", "longterm", "longtermsupport", "esr":
            self.init(kind: .lts)
        case "rc", "releasecandidate", "candidate":
            self.init(kind: .releaseCandidate)
        case "beta", "preview":
            self.init(kind: .beta)
        case "alpha", "dev", "developer":
            self.init(kind: .alpha)
        case "canary", "insider", "insiders", "edge":
            self.init(kind: .canary)
        case "nightly", "snapshot":
            self.init(kind: .nightly)
        default:
            self.init(kind: .custom, vendorName: trimmed)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch kind {
        case .stable: "stable"
        case .lts: "lts"
        case .releaseCandidate: "rc"
        case .beta: "beta"
        case .alpha: "alpha"
        case .canary: "canary"
        case .nightly: "nightly"
        case .custom: vendorName ?? "custom"
        }
    }

    var title: String {
        switch kind {
        case .stable: String(localized: "Stable", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .lts: String(localized: "LTS", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .releaseCandidate: String(localized: "RC", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .beta: String(localized: "Beta", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .alpha: String(localized: "Alpha", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .canary: String(localized: "Canary", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .nightly: String(localized: "Nightly", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .custom: vendorName ?? String(localized: "Custom", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var isPrerelease: Bool {
        switch kind {
        case .releaseCandidate, .beta, .alpha, .canary, .nightly: true
        case .stable, .lts, .custom: false
        }
    }

    static let stable = ReleaseChannel(kind: .stable)
    static let lts = ReleaseChannel(kind: .lts)
    static let releaseCandidate = ReleaseChannel(kind: .releaseCandidate)
    static let beta = ReleaseChannel(kind: .beta)
    static let alpha = ReleaseChannel(kind: .alpha)
    static let canary = ReleaseChannel(kind: .canary)
    static let nightly = ReleaseChannel(kind: .nightly)

    static func detect(
        version: String,
        explicitName: String? = nil,
        bundleIdentifier: String? = nil
    ) -> ReleaseChannel {
        if let explicitName,
           !explicitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ReleaseChannel(rawValue: explicitName)
        }

        let bundle = normalized(bundleIdentifier ?? "")
        if bundle.contains("canary") || bundle.contains("insider") { return .canary }
        if bundle.contains("nightly") { return .nightly }
        if bundle.contains("beta") { return .beta }
        if bundle.contains("alpha") { return .alpha }

        let value = version.lowercased()
        if value.range(of: #"(?:^|[\s._+\-])(?:nightly|snapshot)(?:$|[\s._+\-])"#, options: .regularExpression) != nil {
            return .nightly
        }
        if value.range(of: #"(?:^|[\s._+\-])(?:canary|insiders?)(?:$|[\s._+\-])"#, options: .regularExpression) != nil {
            return .canary
        }
        if value.range(of: #"(?:^|[\s._+\-])alpha\s*[0-9]*(?:$|[\s._+\-])"#, options: .regularExpression) != nil {
            return .alpha
        }
        if value.range(of: #"(?:^|[\s._+\-])beta\s*[0-9]*(?:$|[\s._+\-])"#, options: .regularExpression) != nil {
            return .beta
        }
        if value.range(of: #"(?:^|[\s._+\-])rc\s*[0-9]*(?:$|[\s._+\-])"#, options: .regularExpression) != nil {
            return .releaseCandidate
        }
        if value.range(of: #"(?:^|[\s._+\-])(?:lts|esr)(?:$|[\s._+\-])"#, options: .regularExpression) != nil {
            return .lts
        }
        return .stable
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

enum ReleaseChannelPolicy {
    static func allows(
        candidate: ReleaseChannel,
        for installed: ReleaseChannel,
        allowPrereleaseForStable: Bool
    ) -> Bool {
        if candidate == installed { return true }

        switch installed.kind {
        case .stable:
            return allowPrereleaseForStable && candidate.isPrerelease
        case .lts:
            return candidate.kind == .lts
        case .releaseCandidate, .beta, .alpha, .canary, .nightly:
            return candidate.kind == installed.kind
        case .custom:
            return candidate.kind == .custom
                && candidate.rawValue.caseInsensitiveCompare(installed.rawValue) == .orderedSame
        }
    }
}
