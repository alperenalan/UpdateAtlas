import XCTest
@testable import UpdateAtlas

final class LocalizationRuntimeTests: XCTestCase {
    @MainActor
    func testComputedLabelsFollowSelectedLanguageWithoutRelaunch() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppL10n.languageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppL10n.languageKey)
            } else {
                defaults.removeObject(forKey: AppL10n.languageKey)
            }
        }

        let cases: [(code: String, update: String, cli: String)] = [
            ("tr", "Güncelleme Mevcut", "Yüklü Değil"),
            ("ru", "Доступно обновление", "Не установлено"),
            ("de", "Update verfügbar", "Nicht installiert"),
            ("fr", "Mise à jour disponible", "Non installé"),
            ("zh-Hans", "有可用更新", "未安装"),
            ("ja", "アップデートあり", "未インストール"),
            ("en", "Update Available", "Not Installed")
        ]

        for entry in cases {
            defaults.set(entry.code, forKey: AppL10n.languageKey)
            XCTAssertEqual(AppL10n.locale.identifier, entry.code)
            XCTAssertTrue(AppL10n.bundle.bundlePath.hasSuffix("/\(entry.code).lproj"), entry.code)
            XCTAssertEqual(DefaultInventoryView.updateAvailable.title, entry.update, entry.code)
            XCTAssertEqual(CLIInstallationService.InstallationState.notInstalled.title, entry.cli, entry.code)
        }
    }
}
