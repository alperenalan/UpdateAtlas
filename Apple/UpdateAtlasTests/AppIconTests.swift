import XCTest
@testable import UpdateAtlas

final class AppIconTests: XCTestCase {
    func testPackagedApplicationIconExists() {
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
    }
}
