import Foundation
import Darwin
import Testing
@testable import GPUMonitorCore

@Test func commandRunnerCompletionCanArriveBeforeWaiterRegistration() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()

    let synchronizedProcess = SynchronizedProcess()
    synchronizedProcess.processDidTerminate(process)
    let clock = ContinuousClock()
    let startedAt = clock.now
    let completion = await synchronizedProcess.waitForExit()

    #expect(completion.exitCode == 0)
    #expect(!completion.timedOut)
    #expect(!completion.cancelled)
    #expect(startedAt.duration(to: clock.now) < .milliseconds(100))
}

@Test func commandRunnerCompletesConcurrentImmediateProcesses() async throws {
    try await withThrowingTaskGroup(of: CommandResult.self) { group in
        for _ in 0..<50 {
            group.addTask {
                try await CommandRunner().run(
                    executable: "/usr/bin/true",
                    arguments: [],
                    timeout: .seconds(1)
                )
            }
        }

        for try await result in group {
            #expect(result.exitCode == 0)
        }
    }
}

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

@Test func commandRunnerForceKillsAndReapsAChildThatIgnoresSIGTERM() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appending(path: "gpu-monitor-term-resistant-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidURL) }
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: CommandError.timedOut) {
        try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; echo $$ > \"\(pidURL.path)\"; exec /bin/sleep 1.5",
            ],
            timeout: .milliseconds(50)
        )
    }

    #expect(startedAt.duration(to: clock.now) < .milliseconds(700))
    let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(pidText))
    errno = 0
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func commandRunnerCancellationForceKillsAndReapsAChildThatIgnoresSIGTERM() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appending(path: "gpu-monitor-cancel-resistant-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidURL) }
    let task = Task {
        try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; echo $$ > \"\(pidURL.path)\"; exec /bin/sleep 1.5",
            ],
            timeout: .seconds(5)
        )
    }

    for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidURL.path) {
        try await ContinuousClock().sleep(for: .milliseconds(1))
    }
    #expect(FileManager.default.fileExists(atPath: pidURL.path))
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(cancelledAt.duration(to: clock.now) < .milliseconds(700))
    let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(pidText))
    errno = 0
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func commandRunnerDoesNotWaitForDescendantHeldPipes() async throws {
    let clock = ContinuousClock()
    let startedAt = clock.now

    let result = try await CommandRunner().run(
        executable: "/bin/sh",
        arguments: ["-c", "printf parent-output; /bin/sleep 1.5 & exit 0"],
        timeout: .seconds(2)
    )

    #expect(result.stdout == "parent-output")
    #expect(startedAt.duration(to: clock.now) < .milliseconds(700))
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
