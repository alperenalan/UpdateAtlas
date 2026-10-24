import Foundation
import Testing
@testable import UpdateAtlas

struct VendorUtilityScannerTests {
    @Test func findsNestedVendorApplicationsWithoutScanningUnrelatedFolders() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(".temporary_files/vendor-utilities-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let applications = fixture.appendingPathComponent("Applications")
        for path in [
            "Canon Utilities/IJ Scan Utility/Canon IJ Scan Utility2.app",
            "DDPM/DDPM.app",
            "Unrelated/Other.app"
        ] {
            try FileManager.default.createDirectory(
                at: applications.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }

        let names = Set(ApplicationScanner.vendorUtilityBundles(in: applications)
            .map(\.lastPathComponent))

        #expect(names == ["Canon IJ Scan Utility2.app", "DDPM.app"])
    }
}
