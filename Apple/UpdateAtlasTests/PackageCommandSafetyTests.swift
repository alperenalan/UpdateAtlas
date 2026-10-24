import Foundation
import Testing
@testable import UpdateAtlas

@Suite("Package-manager command safety")
struct PackageCommandSafetyTests {
    @Test("Relative and empty PATH entries never resolve an executable")
    func relativePathEntriesAreIgnored() {
        let found = ExecutableLocator.all(named: "ls", additionalPaths: [], searchPath: ".:bin::usr/bin:/bin")
        #expect(found == ["/bin/ls"])
    }

    @Test("Only relative entries yield nothing")
    func onlyRelativeEntries() {
        #expect(ExecutableLocator.all(named: "ls", additionalPaths: [], searchPath: ".:bin:./tools").isEmpty)
    }

    @Test("Duplicate pip package names keep the first latest version")
    func duplicatePipNamesKeepFirst() throws {
        let json = #"[{"name":"Requests","version":"2.0","latest_version":"2.32.0"},{"name":"requests","version":"2.0","latest_version":"9.9.9"},{"name":"rich","version":"13.0","latest_version":"13.7.1"}]"#
        let outdated = try #require(PackageInventoryScanner.parsePipOutdated(Data(json.utf8)))
        #expect(outdated == ["requests": "2.32.0", "rich": "13.7.1"])
    }
}
