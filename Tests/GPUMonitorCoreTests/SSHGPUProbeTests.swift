import Foundation
import Testing
import GPUMonitorCore

private actor ProbeRecordingRunner: CommandRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let timeout: Duration
    }

    private let result: Result<CommandResult, Error>
    private var calls: [Call] = []

    init(stdout: String) {
        result = .success(CommandResult(exitCode: 0, stdout: stdout, stderr: ""))
    }

    init(error: Error) {
        result = .failure(error)
    }

    var onlyCall: Call {
        precondition(calls.count == 1)
        return calls[0]
    }

    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        return try result.get()
    }
}

@Test func probeUsesExactRestrictedSSHArgumentsAndNoRemoteCommand() async throws {
    let runner = ProbeRecordingRunner(stdout: validNVIDIAOutput)
    let probe = SSHGPUProbe(
        runner: runner,
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )

    let snapshot = try await probe.sample(server: .server10222)
    let call = await runner.onlyCall

    #expect(snapshot.server == .server10222)
    #expect(call.executable == "/usr/bin/ssh")
    #expect(call.timeout == .seconds(8))
    #expect(call.arguments == [
        "-T", "-i", "/tmp/gpu_monitor_ed25519",
        "-p", "10222",
        "-o", "BatchMode=yes",
        "-o", "ConnectionAttempts=1",
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=/tmp/known_hosts",
        "-o", "LogLevel=ERROR",
        "yanxiaoyang@122.207.108.8",
    ])
}

@Test func probeExpandsTildeInIdentityPath() async throws {
    let runner = ProbeRecordingRunner(stdout: validNVIDIAOutput)
    let probe = SSHGPUProbe(
        runner: runner,
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )
    let server = ServerConfig(
        id: "tilde", label: "tilde", host: "example.invalid", port: 22,
        username: "tester", identityFile: "~/.ssh/gpu_monitor_ed25519"
    )

    _ = try await probe.sample(server: server)

    let call = await runner.onlyCall
    #expect(call.arguments[2] == FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".ssh/gpu_monitor_ed25519").path)
}

@Test func probeMapsCommandFailuresWithoutLeakingCredentials() async {
    let secret = "super-secret-password"
    let runner = ProbeRecordingRunner(
        error: CommandError.nonZeroExit(code: 255, stderr: "permission denied: \(secret)")
    )
    let probe = SSHGPUProbe(
        runner: runner,
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )

    do {
        _ = try await probe.sample(server: .fixture)
        Issue.record("Expected the probe to fail")
    } catch {
        #expect(error as? GPUProbeError == .connectionFailed(exitCode: 255))
        #expect(!error.localizedDescription.contains(secret))
        #expect(!error.localizedDescription.contains(ServerConfig.fixture.identityFile))
    }
}

@Test func probeMapsParserFailuresToReadableErrors() async {
    let runner = ProbeRecordingRunner(stdout: "not nvidia output")
    let probe = SSHGPUProbe(
        runner: runner,
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )

    await #expect(throws: GPUProbeError.invalidResponse) {
        try await probe.sample(server: .fixture)
    }
}
