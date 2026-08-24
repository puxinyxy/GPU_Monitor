import Foundation

public protocol GPUProbing: Sendable {
    func sample(server: ServerConfig) async throws -> ServerSnapshot
}

public enum ProbeFailure: Error, Equatable, Sendable {
    case connectivity
    case hostKeySecurity
    case authentication
    case remoteCommand
    case invalidResponse
    case localLaunch
}

extension ProbeFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectivity:
            return "The GPU server could not be reached."
        case .hostKeySecurity:
            return "SSH host-key verification failed."
        case .authentication:
            return "SSH public-key authentication failed."
        case .remoteCommand:
            return "The remote GPU query failed."
        case .invalidResponse:
            return "The GPU server returned an invalid response."
        case .localLaunch:
            return "The local SSH client could not be started."
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
            "-T",
            "-F", "/dev/null",
            "-i", expandedIdentityPath,
            "-p", String(server.port),
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ConnectionAttempts=1",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ClearAllForwardings=yes",
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
            throw ProbeFailure.connectivity
        } catch let CommandError.nonZeroExit(_, stderr) {
            throw Self.classifyOpenSSHFailure(stderr)
        } catch {
            throw ProbeFailure.localLaunch
        }

        do {
            return try NVIDIAOutputParser().parse(result.stdout, server: server, capturedAt: Date())
        } catch {
            throw ProbeFailure.invalidResponse
        }
    }

    private static func classifyOpenSSHFailure(_ stderr: String) -> ProbeFailure {
        let diagnostic = stderr.lowercased()

        if containsAny(diagnostic, [
            "remote host identification has changed",
            "host key verification failed",
            "host-key verification failed",
            "no ed25519 host key is known",
            "no ecdsa host key is known",
            "no rsa host key is known",
            "offending ed25519 key",
            "offending ecdsa key",
            "offending rsa key",
        ]) {
            return .hostKeySecurity
        }

        if containsAny(diagnostic, [
            "permission denied",
            "authentication failed",
            "no supported authentication methods available",
            "too many authentication failures",
        ]) {
            return .authentication
        }

        if containsAny(diagnostic, [
            "network is unreachable",
            "connection refused",
            "operation timed out",
            "connection timed out",
            "no route to host",
            "could not resolve hostname",
            "temporary failure in name resolution",
            "name or service not known",
            "connection reset",
            "connection closed",
            "connection aborted",
            "broken pipe",
        ]) {
            return .connectivity
        }

        return .remoteCommand
    }

    private static func containsAny(_ diagnostic: String, _ fragments: [String]) -> Bool {
        fragments.contains(where: diagnostic.contains)
    }
}
