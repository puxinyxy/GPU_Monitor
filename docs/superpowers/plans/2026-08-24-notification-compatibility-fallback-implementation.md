# GPU Monitor Notification Compatibility Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep `UserNotifications` as the preferred macOS notification channel and automatically use a safe `/usr/bin/osascript` system-notification channel only when macOS rejects this ad-hoc signed app with `UNError.Code.notificationsNotAllowed`.

**Architecture:** Add a focused compatibility client that invokes a fixed AppleScript through `CommandRunning` with title and body as separate argv values. `MacOSNotificationSink` owns a two-state native/compatibility router, respects explicit denial, returns to native delivery when authorization becomes available, and keeps the existing `NotificationSink` seam for a future WeChat implementation. The menu exposes compatibility as an orange, non-error status.

**Tech Stack:** Swift 6.3 in Swift 5 language mode, Foundation `Process`, UserNotifications, SwiftUI, Swift Testing, zsh packaging-policy tests, macOS 14+, ad-hoc code signing.

## Global Constraints

- Keep source, design, plan, and documentation under `/Users/yxy/Documents/workspace/gpu-monitor`.
- Preserve `NotificationSink`; do not add WeChat SDK, webhook, or account code.
- Prefer `UserNotifications`; activate compatibility only for `UNErrorDomain` plus `UNError.Code.notificationsNotAllowed.rawValue` when the current native state is not `denied`.
- Never bypass an explicit `.denied` state.
- Invoke only the absolute executable `/usr/bin/osascript`; never invoke a shell or use `do shell script`.
- Keep AppleScript source fixed; pass title and body after `--` as separate argv elements.
- Use a 5-second compatibility-command timeout and stop launching additional notification processes after task cancellation.
- Do not expose notification text, SSH stderr, passwords, private-key paths, or error internals in logs or UI error summaries.
- Keep polling at 15 seconds, do not change GPU state confirmation, SSH behavior, server configuration, or login-item behavior.

---

## File Structure

- Create `Sources/GPUMonitorNotifications/AppleScriptNotificationClient.swift`: compatibility-delivery protocol and the only production code allowed to invoke `/usr/bin/osascript`.
- Create `Tests/GPUMonitorAppTests/AppleScriptNotificationClientTests.swift`: exact executable/argv/timeout and injection-boundary tests.
- Modify `Sources/GPUMonitorNotifications/MacOSNotificationSink.swift`: remove temporary authorization diagnostics and route authorization/delivery between native and compatibility clients.
- Modify `Sources/GPUMonitorCore/NotificationContracts.swift`: add the public `.compatibility` authorization state without changing `NotificationSink`.
- Modify `Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift`: routing, denial, recovery, failure-count, and cancellation tests.
- Modify `Sources/GPUMonitorApp/MenuContentView.swift`: isolate notification display mapping and render compatibility in orange.
- Create `Tests/GPUMonitorAppTests/NotificationStatusDisplayTests.swift`: complete display mapping tests including compatibility.
- Modify `Tests/PackagingTests/package_scripts_test.sh`: static policy checks for fixed executable, argv boundary, and no shell construction.
- Modify `README.md` and `docs/superpowers/specs/2026-08-24-gpu-monitor-design.md`: document the real compatibility behavior and its Script Editor branding limitation.

---

### Task 1: Safe AppleScript Compatibility Client

**Files:**
- Create: `Sources/GPUMonitorNotifications/AppleScriptNotificationClient.swift`
- Create: `Tests/GPUMonitorAppTests/AppleScriptNotificationClientTests.swift`

**Interfaces:**
- Consumes: `CommandRunning.run(executable:arguments:timeout:) async throws -> CommandResult` from `GPUMonitorCore`.
- Produces: `CompatibilityNotificationClient.add(title:body:) async throws` and `AppleScriptNotificationClient`.

- [ ] **Step 1: Write the failing exact-invocation and argument-isolation tests**

Create the test file with a recording runner and these assertions:

```swift
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
```

- [ ] **Step 2: Run the app test runner and verify RED**

Run:

```bash
swift run GPUMonitorAppTestsRunner
```

Expected: compilation fails because `AppleScriptNotificationClient` does not exist. This is the intended RED failure.

- [ ] **Step 3: Implement the minimal compatibility client**

Create:

```swift
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
                "-e", "display notification (item 2 of argv) with title \"GPU Monitor\" subtitle (item 1 of argv) sound name \"default\"",
                "-e", "end run",
                "--", title, body,
            ],
            timeout: .seconds(5)
        )
    }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift run GPUMonitorAppTestsRunner
```

Expected: all existing app tests plus the two new client tests pass, with no warnings.

- [ ] **Step 5: Commit the client**

```bash
git add Sources/GPUMonitorNotifications/AppleScriptNotificationClient.swift Tests/GPUMonitorAppTests/AppleScriptNotificationClientTests.swift
git commit -m "feat: add safe macOS notification compatibility client"
```

---

### Task 2: Compatibility Authorization State and Menu Status

**Files:**
- Modify: `Sources/GPUMonitorCore/NotificationContracts.swift`
- Modify: `Sources/GPUMonitorApp/MenuContentView.swift`
- Create: `Tests/GPUMonitorAppTests/NotificationStatusDisplayTests.swift`

**Interfaces:**
- Consumes: existing `NotificationAuthorizationState` and `StatusFooter`.
- Produces: `NotificationAuthorizationState.compatibility`, `NotificationStatusDisplay.init(_:)`, and `NotificationStatusTone`; Task 3 relies on the new authorization case.

- [ ] **Step 1: Write the failing display-mapping tests**

Create:

```swift
import GPUMonitorCore
import Testing
@testable import GPUMonitorUI

@Test func compatibilityNotificationStatusIsAvailableButVisuallyDistinct() {
    let display = NotificationStatusDisplay(.compatibility)

    #expect(display.text == "通知：兼容模式")
    #expect(display.systemImage == "bell.fill")
    #expect(display.tone == .compatibility)
}

@Test func existingNotificationStatusMappingsRemainStable() {
    let cases: [(NotificationAuthorizationState, String, String, NotificationStatusTone)] = [
        (.notDetermined, "通知：待授权", "bell.badge", .secondary),
        (.authorized, "通知：已授权", "bell.fill", .success),
        (.denied, "通知：未授权", "bell.slash.fill", .failure),
        (.provisional, "通知：临时授权", "bell.fill", .success),
        (.ephemeral, "通知：临时授权", "bell.fill", .success),
        (.error, "通知：状态错误", "bell.badge", .failure),
    ]

    for (state, text, image, tone) in cases {
        let display = NotificationStatusDisplay(state)
        #expect(display.text == text)
        #expect(display.systemImage == image)
        #expect(display.tone == tone)
    }
}
```

- [ ] **Step 2: Run app tests and verify RED**

Run:

```bash
swift run GPUMonitorAppTestsRunner
```

Expected: compilation fails because `.compatibility`, `NotificationStatusDisplay`, and `NotificationStatusTone` do not exist.

- [ ] **Step 3: Add the authorization case and focused display value**

Add `.compatibility` without changing either notification protocol:

```swift
public enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
    case compatibility
    case error
}
```

Add these values near the top of `MenuContentView.swift`:

```swift
enum NotificationStatusTone: Equatable, Sendable {
    case secondary
    case success
    case compatibility
    case failure
}

struct NotificationStatusDisplay: Equatable, Sendable {
    let text: String
    let systemImage: String
    let tone: NotificationStatusTone

    init(_ state: NotificationAuthorizationState) {
        switch state {
        case .notDetermined:
            text = "通知：待授权"
            systemImage = "bell.badge"
            tone = .secondary
        case .authorized:
            text = "通知：已授权"
            systemImage = "bell.fill"
            tone = .success
        case .denied:
            text = "通知：未授权"
            systemImage = "bell.slash.fill"
            tone = .failure
        case .provisional, .ephemeral:
            text = "通知：临时授权"
            systemImage = "bell.fill"
            tone = .success
        case .compatibility:
            text = "通知：兼容模式"
            systemImage = "bell.fill"
            tone = .compatibility
        case .error:
            text = "通知：状态错误"
            systemImage = "bell.badge"
            tone = .failure
        }
    }
}
```

Insert this line immediately after `var body: some View {` in `StatusFooter`:

```swift
let notification = NotificationStatusDisplay(model.notificationAuthorization)
```

Replace the existing notification `Label` and its color modifier with:

```swift
Label(notification.text, systemImage: notification.systemImage)
    .foregroundStyle(notificationColor(for: notification.tone))
```

Map its tone exactly as follows:

```swift
private func notificationColor(for tone: NotificationStatusTone) -> Color {
    switch tone {
    case .secondary: .secondary
    case .success: .green
    case .compatibility: .orange
    case .failure: .red
    }
}
```

Remove the three old duplicate authorization switches.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift run GPUMonitorAppTestsRunner
```

Expected: all app tests pass and every authorization enum case has an explicit display mapping.

- [ ] **Step 5: Commit the authorization state and menu status**

```bash
git add Sources/GPUMonitorCore/NotificationContracts.swift Sources/GPUMonitorApp/MenuContentView.swift Tests/GPUMonitorAppTests/NotificationStatusDisplayTests.swift
git commit -m "feat: show notification compatibility mode"
```

---

### Task 3: Authorization and Delivery Router

**Files:**
- Modify: `Sources/GPUMonitorNotifications/MacOSNotificationSink.swift`
- Modify: `Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift`

**Interfaces:**
- Consumes: `CompatibilityNotificationClient.add(title:body:)` from Task 1 and existing `UserNotificationCenterClient`.
- Produces: `MacOSNotificationSink` selects native or compatibility delivery while preserving its public initializer and both existing protocols.

- [ ] **Step 1: Extend the fake clients and write failing routing tests**

Replace the fake center’s immutable authorization state with the following stored value and methods, then add the compatibility fake and test server:

```swift
private actor FakeNotificationCenter: UserNotificationCenterClient {
    private let authorizationResult: Result<NotificationAuthorizationState, Error>
    private let addFailures: Set<Int>
    private var currentState: NotificationAuthorizationState
    private var authorizationRequestCount = 0
    private var requests: [MacOSNotificationRequest] = []

    init(
        authorizationResult: Result<NotificationAuthorizationState, Error> = .success(.authorized),
        currentState: NotificationAuthorizationState? = nil,
        addFailures: Set<Int> = []
    ) {
        self.authorizationResult = authorizationResult
        self.currentState = currentState ?? ((try? authorizationResult.get()) ?? .error)
        self.addFailures = addFailures
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        authorizationRequestCount += 1
        return try authorizationResult.get()
    }

    func authorizationState() async -> NotificationAuthorizationState { currentState }

    func setCurrentState(_ state: NotificationAuthorizationState) {
        currentState = state
    }

    func add(_ request: MacOSNotificationRequest) async throws {
        let index = requests.count
        requests.append(request)
        if addFailures.contains(index) {
            throw FakeCenterError.containsSensitiveDetails
        }
    }

    var recordedRequests: [MacOSNotificationRequest] { requests }
    var requestCount: Int { authorizationRequestCount }
}

private actor FakeCompatibilityNotificationClient: CompatibilityNotificationClient {
    struct Message: Equatable, Sendable {
        let title: String
        let body: String
    }

    private let failures: Set<Int>
    private(set) var messages: [Message] = []

    init(failures: Set<Int> = []) {
        self.failures = failures
    }

    func add(title: String, body: String) async throws {
        let index = messages.count
        messages.append(.init(title: title, body: body))
        if failures.contains(index) { throw FakeCenterError.containsSensitiveDetails }
    }
}

private actor CancellingCompatibilityNotificationClient: CompatibilityNotificationClient {
    private(set) var callCount = 0

    func add(title: String, body: String) async throws {
        callCount += 1
        throw CancellationError()
    }
}

private let notificationTestServer = ServerConfig(
    id: "server-test",
    label: "Test Server",
    host: "example.invalid",
    port: 22,
    username: "tester",
    identityFile: "/private/test-key"
)

private func notificationsNotAllowedError() -> NSError {
    NSError(
        domain: UNErrorDomain,
        code: UNError.Code.notificationsNotAllowed.rawValue
    )
}

@Test func notificationsNotAllowedActivatesCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .compatibility)
    let result = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(result.isSuccess)
    #expect(await center.recordedRequests.isEmpty)
    #expect(await compatibility.messages == [.init(
        title: "服务器已恢复",
        body: "服务器 Test Server 已恢复在线"
    )])
}

@Test func explicitDenialNeverActivatesCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .denied
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .denied)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])
    #expect(await compatibility.messages.isEmpty)
}

@Test func compatibilityReturnsToNativeWhenAuthorizationBecomesAvailable() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .compatibility)
    await center.setCurrentState(.authorized)
    #expect(await sink.authorizationState() == .authorized)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func compatibilityReportsPartialFailuresWithoutSensitiveDetails() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient(failures: [0, 2])
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    let result = await sink.send(events: [
        .serverRecovered(server: notificationTestServer),
        .serverOffline(server: notificationTestServer, message: "secret backend token"),
        .serverRecovered(server: notificationTestServer),
    ])

    #expect(result.attemptedCount == 3)
    #expect(result.deliveredCount == 1)
    #expect(result.failures.map(\.messageIndex) == [0, 2])
}
```

Add the remaining boundary tests explicitly:

```swift
@Test func unrelatedAuthorizationErrorDoesNotActivateCompatibility() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(FakeCenterError.containsSensitiveDetails),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .error)
    #expect(await compatibility.messages.isEmpty)
}

@Test func compatibilityPersistsWhileNativeStateRemainsUnavailable() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let sink = MacOSNotificationSink(
        center: center,
        compatibility: FakeCompatibilityNotificationClient()
    )

    #expect(await sink.requestAuthorization() == .compatibility)
    #expect(await sink.authorizationState() == .compatibility)
    await center.setCurrentState(.error)
    #expect(await sink.authorizationState() == .compatibility)
}

@Test func laterExplicitDenialStopsCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    await center.setCurrentState(.denied)
    #expect(await sink.authorizationState() == .denied)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func compatibilityCancellationStopsBeforeStartingAnotherDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = CancellingCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    let result = await sink.send(events: [
        .serverRecovered(server: notificationTestServer),
        .serverOffline(server: notificationTestServer, message: "offline"),
    ])

    #expect(await compatibility.callCount == 1)
    #expect(result.attemptedCount == 2)
    #expect(result.deliveredCount == 0)
    #expect(result.failures.map(\.messageIndex) == [0, 1])
}
```

- [ ] **Step 2: Run the app tests and verify RED**

Run:

```bash
swift run GPUMonitorAppTestsRunner
```

Expected: compilation fails because the injected compatibility initializer and routing behavior do not exist. This is the intended RED failure.

- [ ] **Step 3: Implement exact error matching and mode transitions**

In `MacOSNotificationSink`, add an internal delivery mode, inject the compatibility client, and replace the temporary OSLog diagnostic with exact routing:

```swift
private enum NotificationDeliveryMode: Equatable, Sendable {
    case native
    case compatibility
}

public actor MacOSNotificationSink: NotificationSink, NotificationAuthorizationProviding {
    private let center: any UserNotificationCenterClient
    private let compatibility: any CompatibilityNotificationClient
    private let formatter: NotificationFormatter
    private var deliveryMode: NotificationDeliveryMode = .native

    public init(formatter: NotificationFormatter = NotificationFormatter()) {
        self.center = LiveUserNotificationCenterClient()
        self.compatibility = AppleScriptNotificationClient()
        self.formatter = formatter
    }

    init(
        center: any UserNotificationCenterClient,
        compatibility: any CompatibilityNotificationClient = AppleScriptNotificationClient(),
        formatter: NotificationFormatter = NotificationFormatter()
    ) {
        self.center = center
        self.compatibility = compatibility
        self.formatter = formatter
    }

    public func requestAuthorization() async -> NotificationAuthorizationState {
        do {
            let state = try await center.requestAuthorization()
            return applyNativeState(state)
        } catch {
            guard Self.isNotificationsNotAllowed(error) else {
                deliveryMode = .native
                return .error
            }
            let currentState = await center.authorizationState()
            guard currentState != .denied else {
                deliveryMode = .native
                return .denied
            }
            if currentState == .authorized ||
                currentState == .provisional ||
                currentState == .ephemeral {
                deliveryMode = .native
                return currentState
            }
            deliveryMode = .compatibility
            return .compatibility
        }
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        let state = await center.authorizationState()
        switch state {
        case .authorized, .provisional, .ephemeral, .denied:
            deliveryMode = .native
            return state
        case .notDetermined, .error:
            return deliveryMode == .compatibility ? .compatibility : state
        case .compatibility:
            deliveryMode = .compatibility
            return .compatibility
        }
    }

    private func applyNativeState(
        _ state: NotificationAuthorizationState
    ) -> NotificationAuthorizationState {
        deliveryMode = state == .compatibility ? .compatibility : .native
        return state
    }

    private static func isNotificationsNotAllowed(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == UNErrorDomain &&
            error.code == UNError.Code.notificationsNotAllowed.rawValue
    }
}
```

Replace `send(events:)` with the exact routing and cancellation behavior:

```swift
public func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
    let messages = formatter.messages(for: events)
    var failures: [NotificationDeliveryFailure] = []

    for (index, message) in messages.enumerated() {
        if Task.isCancelled {
            failures.append(contentsOf: (index..<messages.count).map {
                NotificationDeliveryFailure(
                    messageIndex: $0,
                    reason: .schedulingFailed
                )
            })
            break
        }

        do {
            switch deliveryMode {
            case .native:
                try await center.add(MacOSNotificationRequest(
                    identifier: UUID().uuidString,
                    title: message.title,
                    body: message.body,
                    playsDefaultSound: true
                ))
            case .compatibility:
                try await compatibility.add(title: message.title, body: message.body)
            }
        } catch is CancellationError {
            failures.append(contentsOf: (index..<messages.count).map {
                NotificationDeliveryFailure(
                    messageIndex: $0,
                    reason: .schedulingFailed
                )
            })
            break
        } catch {
            failures.append(NotificationDeliveryFailure(
                messageIndex: index,
                reason: .schedulingFailed
            ))
        }
    }

    return NotificationDeliveryResult(
        attemptedCount: messages.count,
        deliveredCount: messages.count - failures.count,
        failures: failures
    )
}
```

- [ ] **Step 4: Run core and app tests and verify GREEN**

Run:

```bash
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
```

Expected: all core and app tests pass. The test output contains no underlying fake error text.

- [ ] **Step 5: Commit the router**

```bash
git add Sources/GPUMonitorNotifications/MacOSNotificationSink.swift Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift
git commit -m "feat: fall back when native notifications are unavailable"
```

---

### Task 4: Policy, Documentation, Packaging, and Real Acceptance

**Files:**
- Modify: `Tests/PackagingTests/package_scripts_test.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-24-gpu-monitor-design.md`

**Interfaces:**
- Consumes: all production behavior from Tasks 1–3.
- Produces: static security regression checks, accurate operator documentation, installed verified app.

- [ ] **Step 1: Add failing packaging-policy assertions**

Define the new source path and checks:

```zsh
compatibility_client="$project_dir/Sources/GPUMonitorNotifications/AppleScriptNotificationClient.swift"

check "compatibility notification client exists" test -f "$compatibility_client"
check "compatibility notifications use the absolute system osascript" file_contains "$compatibility_client" 'executable: "/usr/bin/osascript"'
check "compatibility notifications use argv terminator" file_contains "$compatibility_client" '"--", title, body'
check "compatibility notification text is read from argv" file_contains "$compatibility_client" 'display notification (item 2 of argv) with title "GPU Monitor" subtitle (item 1 of argv)'
check "compatibility notifications never invoke a shell" file_not_contains "$compatibility_client" '/bin/sh'
check "compatibility notifications never invoke zsh" file_not_contains "$compatibility_client" 'zsh -c'
check "compatibility notifications never use AppleScript shell execution" file_not_contains "$compatibility_client" 'do shell script'
check "README documents Script Editor compatibility branding" file_contains "$readme" '脚本编辑器'
```

- [ ] **Step 2: Run the policy test and verify RED**

Run:

```bash
zsh Tests/PackagingTests/package_scripts_test.sh
```

Expected: the README branding assertion fails before the documentation update.

- [ ] **Step 3: Update user and design documentation**

Add a README “通知模式” section that states:

```markdown
## 通知模式

应用优先使用 `UserNotifications` 发送来源为 GPU Monitor 的原生通知。ad-hoc 签名若被 macOS 以精确 `notificationsNotAllowed` 拒绝且当前状态不是 `denied`，应用会进入“通知：兼容模式”，通过固定的 `/usr/bin/osascript` 系统通道投递；通知标题仍为 GPU Monitor，系统显示的来源为“脚本编辑器”。标题和正文作为独立参数传入，不经过 Shell。用户若明确拒绝通知，应用不会启用兼容模式。有效 Apple 证书签名可能使系统允许原生通知，但只有实际观察到 `authorized`、`provisional` 或 `ephemeral` 后才恢复原生通道。
```

In the main design document, append this paragraph to `4.3 Notifier`:

```markdown
当前 ad-hoc 签名被系统以 `UNError.Code.notificationsNotAllowed` 拒绝且授权状态不是 `denied` 时，通知适配器切换到安全兼容模式：固定调用 `/usr/bin/osascript`，固定标题为“GPU Monitor”，把事件标题作为副标题、正文作为独立 argv 传入。菜单显示橙色“通知：兼容模式”，系统通知来源显示为“脚本编辑器”。原生权限以后可用时自动恢复原生通道；用户明确拒绝时绝不回退。
```

Replace the single error-handling bullet for notification denial with these exact bullets:

```markdown
- 通知权限明确被用户拒绝：菜单栏继续工作并显示“通知：未授权”，不得启用兼容通道。
- ad-hoc 签名触发精确的 `notificationsNotAllowed` 错误：启用兼容通道；其他授权错误显示“通知：状态错误”。
- 兼容通知启动失败、超时或非零退出：只把对应消息记为调度失败，不泄露命令 stderr 或通知正文。
```

Add these exact unit-test and installation-acceptance bullets:

```markdown
- 精确匹配 `notificationsNotAllowed`、明确拒绝不回退、原生权限恢复和兼容投递取消。
- 验证兼容通知固定使用 `/usr/bin/osascript`，动态内容只作为 argv，不能进入 AppleScript 源码或 Shell。
- 实机验收按运行时状态判断：原生授权可用时应由 GPU Monitor 原生投递；只有精确 `notificationsNotAllowed` 且不是 `denied` 时才应进入兼容模式。
- 2026-08-24 最终实机结果：原生 `com.yxy.gpumonitor` 离线通知展示一次且后续轮询未重复；本次未触发兼容模式，因此“脚本编辑器”来源的兼容投递未获本轮实机验证。
```

- [ ] **Step 4: Run all automated verification**

Run:

```bash
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/install_app_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
swift build --product GPUMonitor -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
```

Expected: every suite passes, strict concurrency produces no warning, and `git diff --check` is silent.

- [ ] **Step 5: Build and verify the release bundle**

Run:

```bash
./scripts/package_app.sh
/usr/bin/codesign --verify --deep --strict --verbose=2 "dist/GPU Monitor.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "dist/GPU Monitor.app/Contents/Info.plist"
```

Expected: package succeeds, signature verification succeeds, and the bundle identifier is `com.yxy.gpumonitor`.

- [ ] **Step 6: Commit policy and documentation**

```bash
git add Tests/PackagingTests/package_scripts_test.sh README.md docs/superpowers/specs/2026-08-24-gpu-monitor-design.md
git commit -m "docs: explain notification compatibility mode"
```

- [ ] **Step 7: Install and perform real acceptance**

Run:

```bash
./scripts/install_app.sh
/bin/sleep 40
/usr/bin/log show --style compact --last 2m --predicate 'process == "usernoted" AND (eventMessage CONTAINS "com.apple.ScriptEditor2" OR eventMessage CONTAINS "Presenting")'
```

Expected notification source is conditional: `authorized`, `provisional`, or `ephemeral` uses native `com.yxy.gpumonitor`; exact `notificationsNotAllowed` with a non-`denied` current state uses Script Editor compatibility delivery. In either route, the installed app starts, port 10122 continues returning seven GPUs, port 10165 reaches confirmed offline after three connectivity failures, and later 15-second polls do not generate repeated offline notifications.

Recorded final live result: native `com.yxy.gpumonitor` delivered the offline notification once without repetition; compatibility was not reproduced in that run.

Verify no login item was added:

```bash
if /usr/bin/sfltool dumpbtm | /usr/bin/grep -qi 'com.yxy.gpumonitor'; then
    print -u2 'Unexpected GPU Monitor login item'
    exit 1
fi
```

Expected: no GPU Monitor login-item record.

- [ ] **Step 8: Request final code review and run completion verification**

Review the complete range from `d92dfcf6f5846ac83177c49541f0624e146487e2` through `HEAD` for correctness, security, cancellation, test quality, and documentation accuracy. Resolve every Critical or Important finding with a new failing test before the final fix. Then rerun Step 4 and Step 5 from a clean worktree.
