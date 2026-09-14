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
        knownHostsURL: URL(fileURLWithPath: "/tmp/Application Support/known_hosts")
    )

    let snapshot = try await probe.sample(server: .server10122)
    let call = await runner.onlyCall

    #expect(snapshot.server == .server10122)
    #expect(call.executable == "/usr/bin/ssh")
    #expect(call.timeout == .seconds(30))
    #expect(call.arguments == [
        "-T",
        "-F", "/dev/null",
        "-i", "/tmp/gpu_monitor_ed25519",
        "-p", "10122",
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
        "-o", "UserKnownHostsFile=\"/tmp/Application Support/known_hosts\"",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "ClearAllForwardings=yes",
        "-o", "LogLevel=ERROR",
        "yanxiaoyang@122.207.108.8",
    ])
}

@Test func probeEscapesQuotesAndBackslashesInsideTheKnownHostsConfigValue() async throws {
    let runner = ProbeRecordingRunner(stdout: validNVIDIAOutput)
    let probe = SSHGPUProbe(
        runner: runner,
        knownHostsURL: URL(fileURLWithPath: "/tmp/GPU Monitor/quoted\"known\\hosts")
    )

    _ = try await probe.sample(server: .fixture)

    let call = await runner.onlyCall
    #expect(call.arguments.contains(
        "UserKnownHostsFile=\"/tmp/GPU Monitor/quoted\\\"known\\\\hosts\""
    ))
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
    #expect(call.arguments[4] == FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".ssh/gpu_monitor_ed25519").path)
}

@Test(arguments: [
    "ssh: connect to host private.example port 22: Network is unreachable",
    "ssh: connect to host private.example port 22: Connection refused",
])
func probeClassifiesRealOpenSSHConnectivityDiagnostics(_ stderr: String) async {
    let runner = ProbeRecordingRunner(error: CommandError.nonZeroExit(code: 255, stderr: stderr))
    let probe = SSHGPUProbe(runner: runner, knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts"))

    await #expect(throws: ProbeFailure.connectivity) {
        try await probe.sample(server: .fixture)
    }
}

@Test(arguments: [
    ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for private.example", ProbeFailure.hostKeySecurity),
    ("tester@private.example: Permission denied (publickey). secret-token", ProbeFailure.authentication),
    ("nvidia-smi: command not found on private.example", ProbeFailure.remoteCommand),
])
func probeClassifiesAndRedactsNonzeroSSHFailures(_ stderr: String, _ expected: ProbeFailure) async {
    let runner = ProbeRecordingRunner(error: CommandError.nonZeroExit(code: 255, stderr: stderr))
    let probe = SSHGPUProbe(runner: runner, knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts"))

    do {
        _ = try await probe.sample(server: .fixture)
        Issue.record("Expected the probe to fail")
    } catch {
        #expect(error as? ProbeFailure == expected)
        for sensitiveValue in ["private.example", "tester", "secret-token", ServerConfig.fixture.identityFile] {
            #expect(!error.localizedDescription.contains(sensitiveValue))
        }
    }
}

@Test func probeClassifiesTimeoutAndLocalLaunchSeparately() async {
    let timedOut = SSHGPUProbe(
        runner: ProbeRecordingRunner(error: CommandError.timedOut),
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )
    let localLaunch = SSHGPUProbe(
        runner: ProbeRecordingRunner(error: ProbeRunnerError.localLaunch),
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )

    await #expect(throws: ProbeFailure.connectivity) {
        try await timedOut.sample(server: .fixture)
    }
    await #expect(throws: ProbeFailure.localLaunch) {
        try await localLaunch.sample(server: .fixture)
    }
}

@Test func probeMapsParserFailuresToReadableErrors() async {
    let runner = ProbeRecordingRunner(stdout: "not nvidia output")
    let probe = SSHGPUProbe(
        runner: runner,
        knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts")
    )

    await #expect(throws: ProbeFailure.invalidResponse) {
        try await probe.sample(server: .fixture)
    }
}

private enum ProbeRunnerError: Error {
    case localLaunch
}
