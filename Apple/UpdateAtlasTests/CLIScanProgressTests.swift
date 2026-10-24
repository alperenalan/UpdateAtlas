import Foundation
import XCTest
@testable import UpdateAtlas

final class CLIScanProgressTests: XCTestCase {
    func testAutomaticModeKeepsPipesQuietAndDumbTerminalsReadable() {
        XCTAssertEqual(CLIScanProgress.mode(for: .automatic, isTerminal: false, supportsAnimation: true), .silent)
        XCTAssertEqual(CLIScanProgress.mode(for: .automatic, isTerminal: true, supportsAnimation: true), .animated)
        XCTAssertEqual(CLIScanProgress.mode(for: .automatic, isTerminal: true, supportsAnimation: false), .plain)
        XCTAssertEqual(CLIScanProgress.mode(for: .enabled, isTerminal: false, supportsAnimation: true), .plain)
        XCTAssertEqual(CLIScanProgress.mode(for: .disabled, isTerminal: true, supportsAnimation: true), .silent)
    }

    func testStartsImmediatelyAnimatesDuringWaitAndStopsAfterCompletion() throws {
        let pipe = Pipe()
        let reporter = CLIScanProgress(mode: .animated, usesTimer: false, now: { 100 }, output: { pipe.fileHandleForWriting.write($0) })
        // Read the first write before any discovery/completion: it must already exist.
        let initial = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertTrue(initial.contains("Starting scan…"))
        reporter.update("Inspecting package environments · npm #1")
        reporter.tick()
        reporter.tick()
        reporter.finish("Completed: 3 items, 1 returned")
        reporter.update("Late callback")
        reporter.tick()
        reporter.finish("Duplicate completion")
        try pipe.fileHandleForWriting.close()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(output.contains("/ Inspecting"))
        XCTAssertTrue(output.contains("- Inspecting"))
        XCTAssertTrue(output.contains("\\ Inspecting"))
        XCTAssertTrue(output.hasSuffix("Completed: 3 items, 1 returned (0s)\n"))
        XCTAssertFalse(output.contains("Late callback"))
        XCTAssertFalse(output.contains("Duplicate completion"))
    }

    func testPlainHeartbeatContinuesWithElapsedTimeWithoutTerminalEscapes() throws {
        let pipe = Pipe()
        let clock = TestProgressClock()
        let reporter = CLIScanProgress(mode: .plain, usesTimer: false, now: { clock.now },
                                       output: { pipe.fileHandleForWriting.write($0) })
        reporter.update("Checking update sources · 2/8 items")
        clock.advance(4)
        reporter.tick()
        clock.advance(1)
        reporter.tick()
        clock.advance(5)
        reporter.tick()
        reporter.finish("Completed with 1 scan warnings: 8 items, 8 returned")
        try pipe.fileHandleForWriting.close()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(output.contains("[5s] Checking update sources · 2/8 items\n"))
        XCTAssertTrue(output.contains("[10s] Checking update sources · 2/8 items\n"))
        XCTAssertFalse(output.contains("[4s]"))
        XCTAssertFalse(output.contains("\u{1B}"))
        XCTAssertFalse(output.contains("\r"))
        XCTAssertTrue(output.hasSuffix("(10s)\n"))
    }

    func testSilentModeWritesNothingAndControlCharactersAreRemoved() throws {
        let pipe = Pipe()
        let silent = CLIScanProgress(mode: .silent, output: { pipe.fileHandleForWriting.write($0) })
        silent.update("Not shown")
        silent.tick()
        silent.finish("Not shown")
        let plain = CLIScanProgress(mode: .plain, usesTimer: false, output: { pipe.fileHandleForWriting.write($0) })
        plain.update("Checking\n\r\u{1B} sources")
        plain.finish("Completed")
        try pipe.fileHandleForWriting.close()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(output.contains("Not shown"))
        XCTAssertTrue(output.contains("Checking sources\n"))
        XCTAssertFalse(output.contains("\u{1B}"))
    }

    func testProgressOptionsDoNotChangeInventorySelectionAndConflictsFail() throws {
        XCTAssertEqual(try CLIInventoryQuery(arguments: ["scan"]).progress, .automatic)
        XCTAssertEqual(try CLIInventoryQuery(arguments: ["check", "--progress", "--kind", "game"]).progress, .enabled)
        XCTAssertEqual(try CLIInventoryQuery(arguments: ["scan", "--no-progress"]).progress, .disabled)
        for options in [["--progress", "--no-progress"], ["--no-progress", "--progress"], ["--progress", "--progress"]] {
            XCTAssertThrowsError(try CLIInventoryQuery(arguments: ["scan"] + options))
        }
        let inventory: [InstalledApplication] = []
        XCTAssertEqual(try CLIInventoryQuery(arguments: ["scan", "--progress"]).selectedItems(in: inventory).count, 0)
    }
}

// Test clock is read by Sendable callbacks; all access is locked, like the reporter.
private final class TestProgressClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
