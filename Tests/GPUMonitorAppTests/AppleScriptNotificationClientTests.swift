import Foundation
import GPUMonitorCore
import Testing
@testable import GPUMonitorNotifications

private actor RecordingNotificationCommandRunner: CommandRunning {
    struct Invocation: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let timeout: Duration
    }

    private var invocations: [Invocation] = []

    func run(
        executable: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> CommandResult {
        invocations.append(.init(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    var recordedInvocations: [Invocation] { invocations }
}

@Test func compatibilityClientUsesFixedExecutableScriptAndTimeout() async throws {
    let runner = RecordingNotificationCommandRunner()
    let client = AppleScriptNotificationClient(runner: runner)

    try await client.add(title: "GPU Monitor", body: "服务器 10165 已离线")

    #expect(await runner.recordedInvocations == [.init(
        executable: "/usr/bin/osascript",
        arguments: [
            "-e", "on run argv",
            "-e", "display notification (item 2 of argv) with title \"GPU Monitor\" subtitle (item 1 of argv) sound name \"default\"",
            "-e", "end run",
            "--", "GPU Monitor", "服务器 10165 已离线",
        ],
        timeout: .seconds(5)
    )])
}

@Test func compatibilityClientKeepsUntrustedTextInSingleArgvElements() async throws {
    let runner = RecordingNotificationCommandRunner()
    let client = AppleScriptNotificationClient(runner: runner)
    let suspiciousTitle = "GPU \"Monitor\"; do shell script"
    let suspiciousBody = "line 1\n`touch /tmp/no` $(touch /tmp/no) \\ end"

    try await client.add(title: suspiciousTitle, body: suspiciousBody)

    let invocations = await runner.recordedInvocations
    let invocation = try #require(invocations.first)
    #expect(invocation.arguments[6] == "--")
    #expect(invocation.arguments[7] == suspiciousTitle)
    #expect(invocation.arguments[8] == suspiciousBody)
    #expect(invocation.arguments[3] == "display notification (item 2 of argv) with title \"GPU Monitor\" subtitle (item 1 of argv) sound name \"default\"")
}
