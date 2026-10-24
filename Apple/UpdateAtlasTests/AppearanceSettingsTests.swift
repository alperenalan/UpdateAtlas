import XCTest
import AppKit
@testable import UpdateAtlas

final class AppearanceSettingsTests: XCTestCase {
    @MainActor
    func testAppearanceSwitchesWholeApplicationAndSystemClearsOverride() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        XCTAssertEqual(AppearanceSettings.defaultAppearance, AppAppearance.system.rawValue)
        XCTAssertNil(AppAppearance.system.nsAppearance)
        XCTAssertEqual(AppAppearance.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppAppearance.dark.nsAppearance?.name, .darkAqua)

        AppearanceSettings.apply(AppAppearance.light.rawValue)
        XCTAssertEqual(application.appearance?.name, .aqua)
        AppearanceSettings.apply(AppAppearance.dark.rawValue)
        XCTAssertEqual(application.appearance?.name, .darkAqua)
        AppearanceSettings.apply(AppAppearance.system.rawValue)
        XCTAssertNil(application.appearance)
        AppearanceSettings.apply("invalid")
        XCTAssertNil(application.appearance)
    }

    func testAccentDefaultsToTheSystemAndCustomColorsProvideATint() {
        XCTAssertEqual(AppearanceSettings.defaultAccentColor, AppAccentColor.system.rawValue)
        XCTAssertNil(AppAccentColor.system.tintColor)
        XCTAssertNotNil(AppAccentColor.blue.tintColor)
        XCTAssertNotNil(AppAccentColor.purple.tintColor)
    }
}
