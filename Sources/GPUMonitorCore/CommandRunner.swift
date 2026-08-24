import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case timedOut
    case launchFailed(message: String)
    case nonZeroExit(code: Int32, stderr: String)
}

extension CommandError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The command timed out."
        case let .launchFailed(message):
            return "The command could not be started: \(message)"
        case let .nonZeroExit(code, _):
            return "The command exited with status \(code)."
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult
}

public struct CommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> CommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let processBox = SynchronizedProcess()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            do {
                try processBox.launch(process)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CommandError.launchFailed(message: error.localizedDescription)
            }

            let outputHandle = standardOutput.fileHandleForReading
            let errorHandle = standardError.fileHandleForReading
            let outputTask = Task.detached {
                outputHandle.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errorHandle.readDataToEndOfFile()
            }
            let waitTask = Task.detached {
                processBox.waitUntilExit(process)
            }
            let timeoutTask = Task {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                    processBox.timeout()
                } catch {
                    // Cancellation means the process completed before the deadline.
                }
            }

            let completion = await waitTask.value
            timeoutTask.cancel()

            let outputData = await outputTask.value
            let errorData = await errorTask.value
            let stdout = String(decoding: outputData, as: UTF8.self)
            let stderr = String(decoding: errorData, as: UTF8.self)

            if completion.cancelled {
                throw CancellationError()
            }
            if completion.timedOut {
                throw CommandError.timedOut
            }
            guard completion.exitCode == 0 else {
                throw CommandError.nonZeroExit(code: completion.exitCode, stderr: stderr)
            }

            return CommandResult(exitCode: completion.exitCode, stdout: stdout, stderr: stderr)
        } onCancel: {
            processBox.cancel()
        }
    }
}

private final class SynchronizedProcess: @unchecked Sendable {
    private enum State {
        case ready
        case running
        case finished
    }

    struct Completion: Sendable {
        let exitCode: Int32
        let timedOut: Bool
        let cancelled: Bool
    }

    private let lock = NSLock()
    private var state = State.ready
    private var process: Process?
    private var didTimeOut = false
    private var wasCancelled = false

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }

        if wasCancelled {
            throw CancellationError()
        }
        if didTimeOut {
            throw CommandError.timedOut
        }

        try process.run()
        self.process = process
        state = .running
    }

    func waitUntilExit(_ process: Process) -> Completion {
        process.waitUntilExit()

        lock.lock()
        defer { lock.unlock() }
        state = .finished
        self.process = nil
        return Completion(
            exitCode: process.terminationStatus,
            timedOut: didTimeOut,
            cancelled: wasCancelled
        )
    }

    func timeout() {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .ready:
            didTimeOut = true
        case .running:
            guard let process, process.isRunning else { return }
            didTimeOut = true
            process.terminate()
        case .finished:
            return
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        wasCancelled = true
        if state == .running, let process, process.isRunning {
            process.terminate()
        }
    }
}
