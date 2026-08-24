import Foundation

public protocol GPUProbing: Sendable {
    func sample(server: ServerConfig) async throws -> ServerSnapshot
}

public enum GPUProbeError: Error, Equatable, Sendable {
    case connectionTimedOut
    case connectionFailed(exitCode: Int32)
    case connectionUnavailable
    case invalidResponse
}

extension GPUProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionTimedOut:
            return "The GPU server connection timed out."
        case let .connectionFailed(exitCode):
            return "The GPU server connection failed with status \(exitCode)."
        case .connectionUnavailable:
            return "The GPU server connection could not be started."
        case .invalidResponse:
            return "The GPU server returned an invalid response."
        }
    }
}

public struct SSHGPUProbe: GPUProbing, Sendable {
    private let runner: any CommandRunning
    private let knownHostsURL: URL

    public init(
        runner: any CommandRunning = CommandRunner(),
        knownHostsURL: URL = AppPaths.live().knownHostsURL
    ) {
        self.runner = runner
        self.knownHostsURL = knownHostsURL
    }

    public func sample(server: ServerConfig) async throws -> ServerSnapshot {
        let expandedIdentityPath = (server.identityFile as NSString).expandingTildeInPath
        let arguments = [
            "-T", "-i", expandedIdentityPath,
            "-p", String(server.port),
            "-o", "BatchMode=yes",
            "-o", "ConnectionAttempts=1",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "LogLevel=ERROR",
            "\(server.username)@\(server.host)",
        ]

        let result: CommandResult
        do {
            result = try await runner.run(
                executable: "/usr/bin/ssh",
                arguments: arguments,
                timeout: .seconds(8)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch CommandError.timedOut {
            throw GPUProbeError.connectionTimedOut
        } catch let CommandError.nonZeroExit(code, _) {
            throw GPUProbeError.connectionFailed(exitCode: code)
        } catch {
            throw GPUProbeError.connectionUnavailable
        }

        do {
            return try NVIDIAOutputParser().parse(result.stdout, server: server, capturedAt: Date())
        } catch {
            throw GPUProbeError.invalidResponse
        }
    }
}
