import Foundation
import GPUMonitorCore

protocol CompatibilityNotificationClient: Sendable {
    func add(title: String, body: String) async throws
}

struct AppleScriptNotificationClient: CompatibilityNotificationClient, Sendable {
    private let runner: any CommandRunning

    init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    func add(title: String, body: String) async throws {
        _ = try await runner.run(
            executable: "/usr/bin/osascript",
            arguments: [
                "-e", "on run argv",
                "-e", #"display notification (item 2 of argv) with title "GPU Monitor" subtitle (item 1 of argv) sound name "default""#,
                "-e", "end run",
                "--", title, body,
            ],
            timeout: .seconds(5)
        )
    }
}
