import SwiftUI
import AppKit

enum AppearanceSettings {
    static let appearanceKey = "appearance.mode"
    static let accentColorKey = "appearance.accentColor"
    static let defaultAppearance = AppAppearance.system.rawValue
    static let defaultAccentColor = AppAccentColor.system.rawValue

    @MainActor
    static func apply(_ rawValue: String?) {
        let mode = AppAppearance(rawValue: rawValue ?? defaultAppearance) ?? .system
        NSApplication.shared.appearance = mode.nsAppearance
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .light: String(localized: "Light", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .dark: String(localized: "Dark", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppAccentColor: String, CaseIterable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case indigo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .blue: String(localized: "Blue", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .purple: String(localized: "Purple", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .pink: String(localized: "Pink", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .red: String(localized: "Red", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .orange: String(localized: "Orange", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .yellow: String(localized: "Yellow", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .green: String(localized: "Green", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .mint: String(localized: "Mint", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .teal: String(localized: "Teal", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .cyan: String(localized: "Cyan", bundle: AppL10n.bundle, locale: AppL10n.locale)
        case .indigo: String(localized: "Indigo", bundle: AppL10n.bundle, locale: AppL10n.locale)
        }
    }

    var tintColor: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .indigo: .indigo
        }
    }

    var previewColor: Color {
        tintColor ?? Color(nsColor: .controlAccentColor)
    }

    var effectiveColor: Color {
        previewColor
    }

    var prefersDarkCheckmark: Bool {
        self == .yellow || self == .mint || self == .cyan
    }
}
