import Foundation

/// Resolves strings created outside SwiftUI's locale environment (model titles,
/// menu items, alerts, and status messages) using the language selected in-app.
enum AppL10n {
    static let languageKey = "app.language.code"
    private static let supportedCodes = ["en", "tr", "ru", "de", "fr", "zh-Hans", "ja"]
    private static let bundles: [String: Bundle] = Dictionary(
        uniqueKeysWithValues: supportedCodes.compactMap { code in
            guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (code, bundle)
        }
    )

    static var locale: Locale {
        locale(for: UserDefaults.standard.string(forKey: languageKey))
    }

    static var bundle: Bundle {
        bundle(for: UserDefaults.standard.string(forKey: languageKey))
    }

    /// Count-dependent text from a catalog key with plural variations; formatting the
    /// bundle's string applies each language's plural rule. English has no catalog entry,
    /// so a count of one uses the `singular` key where the English wording needs it.
    static func plural(
        _ key: String,
        singular: String? = nil,
        count: Int,
        bundle: Bundle = AppL10n.bundle,
        locale: Locale = AppL10n.locale
    ) -> String {
        let format = (count == 1 ? singular : nil) ?? key
        return String(format: bundle.localizedString(forKey: format, value: nil, table: nil), locale: locale, count)
    }

    static func locale(for languageCode: String?) -> Locale {
        guard let languageCode,
              supportedCodes.contains(languageCode) else {
            return .autoupdatingCurrent
        }
        return Locale(identifier: languageCode)
    }

    static func bundle(for languageCode: String?) -> Bundle {
        let chosenCode: String
        if let languageCode, supportedCodes.contains(languageCode) {
            chosenCode = languageCode
        } else {
            chosenCode = Bundle.preferredLocalizations(
                from: Bundle.main.localizations,
                forPreferences: Locale.preferredLanguages
            ).first ?? "en"
        }
        return bundles[chosenCode] ?? .main
    }
}
