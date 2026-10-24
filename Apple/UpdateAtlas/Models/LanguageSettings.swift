import Foundation
import SwiftUI

struct AppLanguageOption: Identifiable, Equatable, Hashable {
    let code: String
    let nativeName: String

    var id: String { code }

    var flagEmoji: String {
        switch code {
        case "en": "🇬🇧"
        case "tr": "🇹🇷"
        case "ru": "🇷🇺"
        case "de": "🇩🇪"
        case "fr": "🇫🇷"
        case "zh-Hans": "🇨🇳"
        case "ja": "🇯🇵"
        default: "🌐"
        }
    }

    var displayTitle: String {
        if code == LanguageSettings.systemLanguageCode {
            return "\(flagEmoji) \(String(localized: "System Default", bundle: AppL10n.bundle, locale: AppL10n.locale))"
        }
        return "\(flagEmoji) \(nativeName)"
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    nonisolated static let languageKey = AppL10n.languageKey
    nonisolated static let languageCodeKey = languageKey
    nonisolated static let systemLanguageCode = "system"
    nonisolated static let defaultLanguageCode = systemLanguageCode

    /// Languages with complete app-string translations. Keep this list in sync with Localizable.xcstrings.
    nonisolated static let primaryLanguages: [AppLanguageOption] = [
        AppLanguageOption(code: systemLanguageCode, nativeName: "System"),
        AppLanguageOption(code: "en", nativeName: "English"),
        AppLanguageOption(code: "tr", nativeName: "Türkçe"),
        AppLanguageOption(code: "ru", nativeName: "Русский"),
        AppLanguageOption(code: "de", nativeName: "Deutsch"),
        AppLanguageOption(code: "fr", nativeName: "Français"),
        AppLanguageOption(code: "zh-Hans", nativeName: "简体中文"),
        AppLanguageOption(code: "ja", nativeName: "日本語")
    ]

    nonisolated static func effectiveLocale(for code: String) -> Locale {
        AppL10n.locale(for: normalizedCode(code))
    }

    static func setLanguageCode(_ code: String, in defaults: UserDefaults = .standard) {
        persist(code, in: defaults)
        shared.selectedCode = normalizedCode(code)
    }

    @Published var selectedCode: String {
        didSet {
            guard oldValue != selectedCode else { return }
            Self.persist(selectedCode, in: defaults)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.languageKey) ?? Self.systemLanguageCode
        self.selectedCode = Self.normalizedCode(saved)
    }

    var effectiveLocale: Locale {
        Self.effectiveLocale(for: selectedCode)
    }

    var currentOption: AppLanguageOption {
        if let match = Self.primaryLanguages.first(where: { $0.code == selectedCode }) {
            return match
        }
        return Self.option(for: selectedCode)
    }

    func select(_ code: String) {
        selectedCode = Self.normalizedCode(code)
    }

    nonisolated static func normalizedCode(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return systemLanguageCode
        }
        if raw.caseInsensitiveCompare(systemLanguageCode) == .orderedSame {
            return systemLanguageCode
        }
        if let primary = primaryLanguages.first(where: { $0.code.caseInsensitiveCompare(raw) == .orderedSame }) {
            return primary.code
        }
        return systemLanguageCode
    }

    nonisolated static func option(for code: String) -> AppLanguageOption {
        if let primary = primaryLanguages.first(where: { $0.code == code }) {
            return primary
        }
        let locale = Locale(identifier: code)
        let native = locale.localizedString(forIdentifier: code)?.capitalized ?? code
        return AppLanguageOption(code: code, nativeName: native)
    }

    nonisolated static func persist(_ code: String, in defaults: UserDefaults = .standard) {
        let normalized = normalizedCode(code)
        defaults.set(normalized, forKey: languageKey)
        if normalized == systemLanguageCode {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([normalized], forKey: "AppleLanguages")
        }
    }
}
