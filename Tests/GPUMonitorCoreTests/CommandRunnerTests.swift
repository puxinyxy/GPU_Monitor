import Foundation
import Testing
import GPUMonitorCore

@Test func commandRunnerCapturesOutput() async throws {
    let result = try await CommandRunner().run(
        executable: "/bin/echo", arguments: ["hello"], timeout: .seconds(1)
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func commandRunnerCapturesStandardError() async throws {
    let result = try await CommandRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "printf output; printf diagnostic >&2"],
        timeout: .seconds(1)
    )

    #expect(result.stdout == "output")
    #expect(result.stderr == "diagnostic")
}

@Test func commandRunnerDrainsLargeStandardOutputAndErrorWithoutDeadlock() async throws {
    let result = try await CommandRunner().run(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "/usr/bin/head -c 1048576 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2",
        ],
        timeout: .seconds(3)
    )

    #expect(result.stdout.utf8.count == 1_048_576)
    #expect(result.stderr.utf8.count == 1_048_576)
}

@Test func commandRunnerTerminatesAfterTimeout() async throws {
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: CommandError.timedOut) {
        try await CommandRunner().run(
            executable: "/bin/sleep", arguments: ["2"], timeout: .milliseconds(100)
        )
    }

    #expect(startedAt.duration(to: clock.now) < .seconds(1))
}

@Test func commandRunnerMapsNonzeroExitAndIncludesStandardError() async {
    await #expect(throws: CommandError.nonZeroExit(code: 23, stderr: "failed safely")) {
        try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'failed safely' >&2; exit 23"],
            timeout: .seconds(1)
        )
    }
}
