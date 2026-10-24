import Foundation
import Testing
@testable import UpdateAtlas

@Suite("Plural count labels")
struct PluralLocalizationTests {
    @Test("English uses the singular key only for one", arguments: [
        (1, "1 update available"), (2, "2 updates available"), (12, "12 updates available")
    ])
    func english(count: Int, expected: String) {
        let text = AppL10n.plural(
            "%lld updates available", singular: "%lld update available", count: count,
            bundle: AppL10n.bundle(for: "en"), locale: Locale(identifier: "en")
        )
        #expect(text == expected)
    }

    @Test("Russian applies one, few and many forms", arguments: [
        (1, "Доступно 1 обновление"), (3, "Доступно 3 обновления"),
        (5, "Доступно 5 обновлений"), (21, "Доступно 21 обновление")
    ])
    func russian(count: Int, expected: String) {
        let text = AppL10n.plural(
            "%lld updates available", singular: "%lld update available", count: count,
            bundle: AppL10n.bundle(for: "ru"), locale: Locale(identifier: "ru")
        )
        #expect(text == expected)
    }

    @Test("Managed update counts follow French plural rules")
    func frenchManagedUpdates() {
        let bundle = AppL10n.bundle(for: "fr")
        let locale = Locale(identifier: "fr")
        #expect(AppL10n.plural("%lld managed updates", singular: "%lld managed update", count: 1, bundle: bundle, locale: locale) == "1 mise à jour gérée")
        #expect(AppL10n.plural("%lld managed updates", singular: "%lld managed update", count: 4, bundle: bundle, locale: locale) == "4 mises à jour gérées")
    }
}
