import Darwin
import Foundation

struct PackageCommandResult: Sendable {
    let output: Data
    let terminationStatus: Int32
}

enum PackageCommandError: Error {
    case failed(ScanDiagnostic.Reason)
}

enum PackageCommandRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 20,
                    control: ScanControl, maximumOutputBytes: Int = 4 * 1024 * 1024,
                    environmentOverrides: [String: String] = [:], mergeStandardError: Bool = false,
                    outputReceived: @Sendable (Data) -> Void = { _ in }) throws -> PackageCommandResult {
        if control.isCancelled { throw PackageCommandError.failed(.cancelled) }
        if control.hasTimedOut { throw PackageCommandError.failed(.timedOut) }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PackageCommandError.failed(.unavailable) }
        defer { close(descriptors[0]) }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) >= 0 else {
            close(descriptors[1]); throw PackageCommandError.failed(.unavailable)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(descriptors[1]); throw PackageCommandError.failed(.unavailable)
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            close(descriptors[1]); throw PackageCommandError.failed(.unavailable)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        // The command and its children own a new process group; setup must fail
        // closed, otherwise group termination could target an unrelated process.
        let setup = [
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            mergeStandardError
                ? posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
                : posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            posix_spawnattr_setpgroup(&attributes, 0)
        ]
        guard setup.allSatisfy({ $0 == 0 }) else {
            close(descriptors[1]); throw PackageCommandError.failed(.unavailable)
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, new in new }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { argPointer in
            environment.withUnsafeBufferPointer { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argPointer.baseAddress!),
                            UnsafeMutablePointer(mutating: envPointer.baseAddress!))
            }
        }
        close(descriptors[1])
        guard status == 0 else { throw PackageCommandError.failed(.unavailable) }
        let deadline = min(control.deadline, ContinuousClock.now.advanced(by: .seconds(timeout)))
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var exitStatus: Int32 = 0
        var exited = false
        var eof = false
        var failure: ScanDiagnostic.Reason?
        while !exited || !eof {
            if control.isCancelled { failure = .cancelled; break }
            if ContinuousClock.now >= deadline { failure = .timedOut; break }
            // Bound each read batch so a producer cannot starve timeout/cancellation.
            for _ in 0..<16 {
                let count = read(descriptors[0], &buffer, buffer.count)
                if count > 0 {
                    if output.count + count > maximumOutputBytes { failure = .outputTooLarge; break }
                    let chunk = Data(buffer.prefix(count))
                    output.append(chunk)
                    outputReceived(chunk)
                } else {
                    if count == 0 { eof = true }
                    else if errno != EAGAIN && errno != EINTR { failure = .invalidOutput }
                    break
                }
            }
            if failure != nil { break }
            if !exited { exited = waitpid(pid, &exitStatus, WNOHANG) == pid }
            if !exited || !eof {
                var descriptor = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 25)
                if eof { usleep(25_000) }
            }
        }
        if let failure {
            kill(-pid, SIGTERM)
            usleep(50_000)
            kill(-pid, SIGKILL)
            if !exited {
                // SIGKILL closes our group; reap without blocking the scan indefinitely.
                for _ in 0..<40 {
                    if waitpid(pid, &exitStatus, WNOHANG) == pid { exited = true; break }
                    usleep(5_000)
                }
                if !exited {
                    let reapingPID = pid
                    DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; _ = waitpid(reapingPID, &status, 0) }
                }
            }
            throw PackageCommandError.failed(failure)
        }
        guard exitStatus & 0x7f == 0 else { throw PackageCommandError.failed(.commandFailed) }
        return PackageCommandResult(output: output, terminationStatus: (exitStatus >> 8) & 0xff)
    }
}
