import Foundation

/// Scanner callbacks and the heartbeat can run on different queues. The lock protects
/// all mutable state and serializes writes; the output closure must itself be Sendable.
final class CLIScanProgress: @unchecked Sendable {
    enum Mode: Equatable { case silent, plain, animated }

    static func mode(for preference: CLIProgressPreference, isTerminal: Bool, supportsAnimation: Bool) -> Mode {
        guard preference != .disabled, preference == .enabled || isTerminal else { return .silent }
        return isTerminal && supportsAnimation ? .animated : .plain
    }

    private let lock = NSLock()
    private let mode: Mode
    private let output: @Sendable (Data) -> Void
    private let now: @Sendable () -> TimeInterval
    private let startedAt: TimeInterval
    private var message = "Starting scan…"
    private var frame = 0
    private var lastPlainHeartbeat: TimeInterval
    private var finished = false
    private var timer: DispatchSourceTimer?

    init(mode: Mode, usesTimer: Bool = true,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         output: @escaping @Sendable (Data) -> Void = { FileHandle.standardError.write($0) }) {
        self.mode = mode
        self.output = output
        self.now = now
        startedAt = now()
        lastPlainHeartbeat = startedAt
        if mode != .silent {
            lock.withLock { render() }
            if usesTimer {
                let heartbeat = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                let interval: DispatchTimeInterval = mode == .animated ? .milliseconds(100) : .seconds(5)
                heartbeat.schedule(deadline: .now() + interval, repeating: interval)
                heartbeat.setEventHandler { [weak self] in self?.tick() }
                timer = heartbeat
                heartbeat.resume()
            }
        }
    }

    deinit { timer?.cancel() }

    func update(_ value: String) {
        lock.withLock {
            guard !finished, mode != .silent else { return }
            // Progress never injects terminal controls, multiline text or unbounded labels.
            let clean = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(96))
            guard !clean.isEmpty, clean != message else { return }
            message = clean
            render()
        }
    }

    func tick() {
        lock.withLock {
            guard !finished, mode != .silent else { return }
            if mode == .plain {
                guard now() - lastPlainHeartbeat >= 5 else { return }
                lastPlainHeartbeat = now()
            }
            render()
        }
    }

    func finish(_ summary: String) {
        lock.withLock {
            guard !finished else { return }
            finished = true
            timer?.cancel()
            timer = nil
            guard mode != .silent else { return }
            let prefix = mode == .animated ? "\r\u{1B}[2K" : ""
            output(Data((prefix + summary + " (" + elapsed + ")\n").utf8))
        }
    }

    private var elapsed: String { String(Int(max(0, now() - startedAt))) + "s" }

    // Called only under lock. No stdout writes, guessed percentages or local paths.
    private func render() {
        let line: String
        if mode == .animated {
            let frames = ["|", "/", "-", "\\"]
            line = "\r\u{1B}[2K" + frames[frame % frames.count] + " " + message + " · " + elapsed
            frame += 1
        } else {
            line = "[" + elapsed + "] " + message + "\n"
        }
        output(Data(line.utf8))
    }
}
