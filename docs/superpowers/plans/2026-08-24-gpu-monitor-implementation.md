# GPU Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and install a native macOS menu-bar app that polls two NVIDIA GPU servers over restricted SSH every 15 seconds, displays per-GPU status, and sends debounced macOS notifications for occupancy and connectivity changes.

**Architecture:** A Swift Package contains a platform-neutral `GPUMonitorCore` library and a SwiftUI/AppKit `GPUMonitor` executable. The core owns configuration, NVIDIA output parsing, state confirmation, SSH execution, and concurrent polling; the app owns the menu-bar UI and `UserNotifications` adapter. A dedicated restricted SSH key permits only the fixed `nvidia-smi` probe.

**Tech Stack:** Swift 6.3 in Swift 5 language mode, Swift Package Manager, SwiftUI, AppKit, UserNotifications, Foundation `Process`, Swift Testing, OpenSSH, shell packaging scripts, ad-hoc code signing.

## Global Constraints

- Target macOS 14.0 or later on the current Apple Silicon Mac.
- Poll both servers concurrently every 15 seconds; SSH query timeout is 8 seconds.
- A GPU is free only when its UUID has no compute process in `nvidia-smi --query-compute-apps` output.
- Confirm a GPU state only after two consecutive identical observations; the first successful sample is a silent baseline.
- Notify once after three consecutive connectivity failures and once after successful recovery; host-key, authentication, remote-command, invalid-response, and local-launch failures never count toward offline.
- Store no password in source, configuration, logs, shell scripts, or the app bundle.
- Do not add login-item or launch-at-login behavior.
- Use a dedicated no-passphrase Ed25519 key whose remote authorization forces the fixed GPU query and disables forwarding and PTY allocation.
- Use macOS system notifications in v1 and keep notification delivery behind a `NotificationSink` interface for later WeChat integration.
- Keep source, design, plan, and documentation under `/Users/yxy/Documents/workspace/gpu-monitor`.
- Use Swift Testing rather than XCTest because this Mac has Command Line Tools without `XCTest.framework`; the test target must add `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` as both a framework search path and runtime rpath.
- Execute tests with the `GPUMonitorCoreTestsRunner` executable target because Command Line Tools cannot run SwiftPM's generated `MH_BUNDLE`; `swift run GPUMonitorCoreTestsRunner` must print and execute the real test count.

---

## Planned File Structure

```text
gpu-monitor/
├── Package.swift
├── Sources/
│   ├── GPUMonitorCore/
│   │   ├── Models.swift                 # Shared value types and monitoring events
│   │   ├── AppPaths.swift               # Application Support, key, and known-host paths
│   │   ├── ConfigurationStore.swift     # Load/create servers.json
│   │   ├── NVIDIAOutputParser.swift     # Parse fixed nvidia-smi output
│   │   ├── StateTracker.swift           # Two-sample GPU confirmation and failure thresholds
│   │   ├── CommandRunner.swift          # Timeout-aware Foundation.Process wrapper
│   │   ├── SSHGPUProbe.swift            # Restricted SSH argument construction and sampling
│   │   ├── MonitorCoordinator.swift     # Concurrent server polling and event production
│   │   └── NotificationFormatter.swift  # Human-readable, aggregated event text
│   ├── GPUMonitorNotifications/
│   │   └── MacOSNotificationSink.swift  # UserNotifications delivery and foreground delegate
│   └── GPUMonitorApp/
│       ├── GPUMonitorApp.swift          # MenuBarExtra entry point
│       ├── AppLifecycleDelegate.swift   # AppKit activation and graceful termination bridge
│       ├── AppModel.swift               # App lifecycle, 15-second loop, published UI state
│       └── MenuContentView.swift        # Server/GPU rows and controls
├── Tests/GPUMonitorCoreTests/
│   ├── ConfigurationStoreTests.swift
│   ├── TestSupport.swift
│   ├── Runner.swift
│   ├── NVIDIAOutputParserTests.swift
│   ├── StateTrackerTests.swift
│   ├── CommandRunnerTests.swift
│   ├── SSHGPUProbeTests.swift
│   ├── MonitorCoordinatorTests.swift
│   └── NotificationFormatterTests.swift
├── packaging/Info.plist
├── scripts/package_app.sh
├── scripts/install_app.sh
├── scripts/provision_ssh.sh
├── README.md
└── docs/superpowers/
    ├── specs/2026-08-24-gpu-monitor-design.md
    └── plans/2026-08-24-gpu-monitor-implementation.md
```

---

### Task 1: Swift package, models, paths, and configuration

**Files:**
- Create: `Package.swift`
- Create: `Sources/GPUMonitorCore/Models.swift`
- Create: `Sources/GPUMonitorCore/AppPaths.swift`
- Create: `Sources/GPUMonitorCore/ConfigurationStore.swift`
- Create: `Sources/GPUMonitorApp/GPUMonitorApp.swift`
- Test: `Tests/GPUMonitorCoreTests/ConfigurationStoreTests.swift`
- Test support: `Tests/GPUMonitorCoreTests/TestSupport.swift`
- Test runner: `Tests/GPUMonitorCoreTests/Runner.swift`

**Interfaces:**
- Produces: `ServerConfig`, `GPUProcessInfo`, `GPUSnapshot`, `ServerSnapshot`, `GPUOccupancy`, `ServerHealth`, `MonitorEvent`, `AppPaths`, and `ConfigurationStore.loadOrCreate()`.
- Consumes: Foundation only.

- [ ] **Step 1: Add the package manifest and a minimal app entry point**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let developerFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let developerLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "GPUMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GPUMonitorCore", targets: ["GPUMonitorCore"]),
        .executable(name: "GPUMonitor", targets: ["GPUMonitorApp"]),
        .executable(name: "GPUMonitorCoreTestsRunner", targets: ["GPUMonitorCoreTestsRunner"]),
    ],
    targets: [
        .target(name: "GPUMonitorCore"),
        .executableTarget(name: "GPUMonitorApp", dependencies: ["GPUMonitorCore"]),
        .executableTarget(
            name: "GPUMonitorCoreTestsRunner",
            dependencies: ["GPUMonitorCore"],
            path: "Tests/GPUMonitorCoreTests",
            swiftSettings: [.unsafeFlags(["-F", developerFrameworks])],
            linkerSettings: [.unsafeFlags([
                "-F", developerFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", developerFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", developerLibraries,
            ])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
```

```swift
// Sources/GPUMonitorApp/GPUMonitorApp.swift
import SwiftUI

@main
struct GPUMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("GPU —/—", systemImage: "cpu") {
            Text("GPU Monitor is starting…")
        }
    }
}
```

- [ ] **Step 2: Write the failing configuration test**

```swift
@Test func loadOrCreateWritesTheTwoApprovedServersWithoutPasswords() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ConfigurationStore(configURL: root.appending(path: "servers.json"))
    let servers = try store.loadOrCreate()

    #expect(servers.map(\.port) == [10222, 10165])
    #expect(Set(servers.map(\.host)) == ["122.207.108.8"])
    #expect(Set(servers.map(\.username)) == ["yanxiaoyang"])
    let data = try Data(contentsOf: root.appending(path: "servers.json"))
    #expect(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("password"))
}
```

- [ ] **Step 3: Run the test and verify the missing types fail compilation**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: FAIL with unresolved identifiers `ConfigurationStore` and `ServerConfig`.

- [ ] **Step 4: Implement the shared models, paths, and configuration store**

```swift
public struct ServerConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let host: String
    public let port: Int
    public let username: String
    public let identityFile: String
}

public enum GPUOccupancy: String, Codable, Sendable { case free, busy }

public struct GPUProcessInfo: Equatable, Sendable {
    public let pid: Int
    public let name: String
    public let usedMemoryMiB: Int
}

public struct GPUSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { uuid }
    public let index: Int
    public let uuid: String
    public let name: String
    public let utilizationPercent: Int
    public let usedMemoryMiB: Int
    public let totalMemoryMiB: Int
    public let temperatureCelsius: Int
    public let processes: [GPUProcessInfo]
    public var occupancy: GPUOccupancy { processes.isEmpty ? .free : .busy }
}

public struct ServerSnapshot: Equatable, Sendable {
    public let server: ServerConfig
    public let gpus: [GPUSnapshot]
    public let capturedAt: Date
}

public enum ServerHealth: Equatable, Sendable {
    case unknown
    case online
    case degraded(message: String, consecutiveFailures: Int)
    case warning(message: String)
    case security(message: String)
    case offline(message: String)
}

public enum MonitorEvent: Equatable, Sendable {
    case gpuChanged(server: ServerConfig, gpu: GPUSnapshot, from: GPUOccupancy, to: GPUOccupancy)
    case serverOffline(server: ServerConfig, message: String)
    case serverRecovered(server: ServerConfig)
}
```

`AppPaths.live()` resolves `~/Library/Application Support/GPUMonitor/servers.json`, `known_hosts`, and `~/.ssh/gpu_monitor_ed25519`. `ConfigurationStore.loadOrCreate()` creates parent directories, writes indented/sorted JSON atomically on first run, and returns the two server records in the approved order.

`TestSupport.swift` defines the exact reusable fixtures used by later tasks: `ServerConfig.fixture`, `.server10222`, `.server10165`, `ServerSnapshot.snapshot(_:)`, `GPUSnapshot.gpu(index:_:)`, `GPUSnapshot.busyGPU(index:pid:name:)`, `validNVIDIAOutput`, `RecordingRunner`, `ControlledProbe`, and `TestError.unreachable`. Keeping these definitions in one file prevents later tests from inventing incompatible fixture types.

- [ ] **Step 5: Run the focused test and full build**

Run: `swift run GPUMonitorCoreTestsRunner && swift build`

Expected: PASS and `Build complete!`.

- [ ] **Step 6: Commit the independently testable configuration foundation**

```bash
git add Package.swift Sources Tests/GPUMonitorCoreTests/ConfigurationStoreTests.swift
git commit -m "feat: add GPU Monitor configuration foundation"
```

---

### Task 2: NVIDIA output parsing

**Files:**
- Create: `Sources/GPUMonitorCore/NVIDIAOutputParser.swift`
- Test: `Tests/GPUMonitorCoreTests/NVIDIAOutputParserTests.swift`

**Interfaces:**
- Consumes: `ServerConfig`, `GPUProcessInfo`, `GPUSnapshot`, `ServerSnapshot`.
- Produces: `NVIDIAOutputParser.parse(_ output: String, server: ServerConfig, capturedAt: Date) throws -> ServerSnapshot` and `NVIDIAParseError`.

- [ ] **Step 1: Write parser tests for free, busy, multi-GPU, and malformed output**

```swift
let sample = """
0, GPU-a, NVIDIA RTX 4090, 0, 120, 24564, 35
1, GPU-b, NVIDIA RTX 4090, 92, 18432, 24564, 71
__GPU_MONITOR_PROCESSES__
GPU-b, 12345, python, 18100
"""

@Test func parseAssociatesProcessesByGPUUUID() throws {
    let result = try NVIDIAOutputParser().parse(sample, server: .fixture, capturedAt: .distantPast)
    #expect(result.gpus.count == 2)
    #expect(result.gpus[0].occupancy == .free)
    #expect(result.gpus[1].processes == [.init(pid: 12345, name: "python", usedMemoryMiB: 18100)])
}

@Test func parseRejectsMissingMarker() {
    #expect(throws: (any Error).self) {
        try NVIDIAOutputParser().parse("0, GPU-a", server: .fixture, capturedAt: .distantPast)
    }
}
```

- [ ] **Step 2: Run the parser tests and verify failure**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: FAIL because `NVIDIAOutputParser` does not exist.

- [ ] **Step 3: Implement strict two-section CSV parsing**

Implement these exact rules:

```swift
public struct NVIDIAOutputParser: Sendable {
    public static let marker = "__GPU_MONITOR_PROCESSES__"

    public func parse(_ output: String, server: ServerConfig, capturedAt: Date) throws -> ServerSnapshot {
        let sections = output.components(separatedBy: Self.marker)
        guard sections.count == 2 else { throw NVIDIAParseError.missingMarker }
        let processes = try parseProcesses(sections[1])
        let gpus = try sections[0].split(whereSeparator: \.isNewline).map {
            try parseGPU(String($0), processesByUUID: processes)
        }.sorted { $0.index < $1.index }
        guard !gpus.isEmpty else { throw NVIDIAParseError.noGPUs }
        return ServerSnapshot(server: server, gpus: gpus, capturedAt: capturedAt)
    }
}
```

Trim every CSV field. GPU rows require exactly seven fields, non-empty UUID/name, unique UUID/index, and numeric index/utilization/memory/temperature. Process rows require exactly four fields, non-empty GPU UUID/name, and a GPU UUID present in the GPU section; an empty process section and the literal `No running processes found` both mean no processes. Any malformed non-empty row fails the whole sample.

- [ ] **Step 4: Run parser tests and the full suite**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: all tests PASS.

- [ ] **Step 5: Commit the parser**

```bash
git add Sources/GPUMonitorCore/NVIDIAOutputParser.swift Tests/GPUMonitorCoreTests/NVIDIAOutputParserTests.swift
git commit -m "feat: parse NVIDIA GPU and process snapshots"
```

---

### Task 3: Debounced GPU state and server health tracking

**Files:**
- Create: `Sources/GPUMonitorCore/StateTracker.swift`
- Test: `Tests/GPUMonitorCoreTests/StateTrackerTests.swift`

**Interfaces:**
- Consumes: `ServerConfig`, `ServerSnapshot`, `GPUOccupancy`, `MonitorEvent`, `ServerHealth`.
- Produces: actor methods `recordSuccess(_:) -> StateUpdate` and `recordFailure(server:failure:) -> StateUpdate`.

- [ ] **Step 1: Write state transition tests**

```swift
@Test func firstSuccessIsSilentAndSecondMatchingChangeNotifies() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    #expect(await tracker.recordSuccess(.snapshot(.free)).events.isEmpty)
    #expect(await tracker.recordSuccess(.snapshot(.busy)).events.isEmpty)
    let update = await tracker.recordSuccess(.snapshot(.busy))
    #expect(update.events.count == 1)
}

@Test func threeFailuresNotifyOnceAndRecoveryRebaselinesWithoutGPUChange() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    #expect(await tracker.recordFailure(server: .fixture, failure: .connectivity).events.isEmpty)
    #expect(await tracker.recordFailure(server: .fixture, failure: .connectivity).events.isEmpty)
    #expect(await tracker.recordFailure(server: .fixture, failure: .connectivity).events ==
            [.serverOffline(server: .fixture, message: ProbeFailure.connectivity.localizedDescription)])
    #expect(await tracker.recordSuccess(.snapshot(.busy)).events ==
            [.serverRecovered(server: .fixture)])
}
```

- [ ] **Step 2: Run the state tests and verify failure**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: FAIL because `StateTracker` and `StateUpdate` do not exist.

- [ ] **Step 3: Implement per-GPU candidate state and per-server failure records**

```swift
public struct StateUpdate: Equatable, Sendable {
    public let health: ServerHealth
    public let stableSnapshot: ServerSnapshot?
    public let events: [MonitorEvent]
}

public actor StateTracker {
    private struct GPURecord {
        var confirmed: GPUSnapshot
        var candidate: GPUOccupancy?
        var candidateCount = 0
    }
    private struct ServerRecord {
        var connectivityFailures = 0
        var connectivityOffline = false
        var lastSnapshot: ServerSnapshot?
        var gpus: [String: GPURecord] = [:]
    }
    // recordSuccess and recordFailure update only the addressed server record.
}
```

Only consecutive `.connectivity` failures advance the offline threshold. Host-key failures become security health; authentication, remote-command, invalid-response, and local-launch failures become warning health and reset connectivity accumulation. A first opposite candidate leaves `stableSnapshot` unchanged; confirmed observations refresh the stored full GPU metrics/processes. On recovery after a confirmed offline state, emit only `.serverRecovered`, defensively unique direct-input UUIDs, replace all GPU baselines with the recovered snapshot, and suppress stale GPU-change events.

- [ ] **Step 4: Run transition tests and the full suite**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: all tests PASS.

- [ ] **Step 5: Commit the tracker**

```bash
git add Sources/GPUMonitorCore/StateTracker.swift Tests/GPUMonitorCoreTests/StateTrackerTests.swift
git commit -m "feat: track confirmed GPU and server state changes"
```

---

### Task 4: Timeout-aware command execution and SSH GPU probe

**Files:**
- Create: `Sources/GPUMonitorCore/CommandRunner.swift`
- Create: `Sources/GPUMonitorCore/SSHGPUProbe.swift`
- Test: `Tests/GPUMonitorCoreTests/CommandRunnerTests.swift`
- Test: `Tests/GPUMonitorCoreTests/SSHGPUProbeTests.swift`

**Interfaces:**
- Produces: `CommandRunning.run(executable:arguments:timeout:) async throws -> CommandResult`, `GPUProbing.sample(server:) async throws -> ServerSnapshot`, and `SSHGPUProbe`.
- Consumes: `NVIDIAOutputParser`, `ServerConfig`, `AppPaths.knownHostsURL`.

- [ ] **Step 1: Write command-runner timeout and output tests**

```swift
@Test func commandRunnerCapturesOutput() async throws {
    let result = try await CommandRunner().run(
        executable: "/bin/echo", arguments: ["hello"], timeout: .seconds(1))
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func commandRunnerTerminatesAfterTimeout() async {
    await #expect(throws: (any Error).self) {
        try await CommandRunner().run(
            executable: "/bin/sleep", arguments: ["2"], timeout: .milliseconds(100))
    }
}
```

- [ ] **Step 2: Write an SSH argument-construction test using a fake runner**

```swift
@Test func probeUsesPinnedKnownHostsBatchModeAndNoRemoteCommand() async throws {
    let runner = RecordingRunner(stdout: validNVIDIAOutput)
    let probe = SSHGPUProbe(runner: runner, knownHostsURL: URL(fileURLWithPath: "/tmp/known_hosts"))
    _ = try await probe.sample(server: .fixture)
    let call = await runner.onlyCall
    #expect(call.executable == "/usr/bin/ssh")
    #expect(call.arguments.contains("BatchMode=yes"))
    #expect(call.arguments.contains("StrictHostKeyChecking=yes"))
    #expect(call.arguments.contains("UserKnownHostsFile=/tmp/known_hosts"))
    #expect(call.arguments.last == "yanxiaoyang@122.207.108.8")
}
```

- [ ] **Step 3: Run both focused test groups and verify failure**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: FAIL because the runner and probe types do not exist.

- [ ] **Step 4: Implement the process wrapper**

`CommandRunner` starts a `Foundation.Process` with stdout/stderr pipes inside a detached task. A synchronized process box permits the timeout task to call `terminate()`. When timeout wins, terminate the process, wait for exit, and throw `CommandError.timedOut`; nonzero exit becomes `CommandError.nonZeroExit(code:stderr:)`. Never log arguments or environment values.

```swift
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult
}
```

- [ ] **Step 5: Implement the restricted SSH probe**

Construct exactly these arguments before the `user@host` destination:

```swift
[
    "-T", "-F", "/dev/null", "-i", expandedIdentityPath,
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
    "\(server.username)@\(server.host)"
]
```

Pass `.seconds(8)` to the runner, parse stdout with `NVIDIAOutputParser`, and map failures to the sanitized `ProbeFailure` cases connectivity, host-key/security, authentication, remote-command, invalid-response, and local-launch. Fixed user-readable messages must not include stderr, host, user, identity path, or credentials. OpenSSH `Network is unreachable` and `Connection refused` diagnostics are connectivity.

- [ ] **Step 6: Run focused and full tests**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: all tests PASS.

- [ ] **Step 7: Commit the command and probe boundary**

```bash
git add Sources/GPUMonitorCore/CommandRunner.swift Sources/GPUMonitorCore/SSHGPUProbe.swift Tests/GPUMonitorCoreTests/CommandRunnerTests.swift Tests/GPUMonitorCoreTests/SSHGPUProbeTests.swift
git commit -m "feat: query GPU snapshots over restricted SSH"
```

---

### Task 5: Concurrent monitor coordinator

**Files:**
- Create: `Sources/GPUMonitorCore/MonitorCoordinator.swift`
- Test: `Tests/GPUMonitorCoreTests/MonitorCoordinatorTests.swift`

**Interfaces:**
- Consumes: `[ServerConfig]`, `GPUProbing`, `StateTracker`.
- Produces: actor `MonitorCoordinator.poll() async -> MonitorCycle`.

- [ ] **Step 1: Write a concurrency and partial-failure test**

```swift
@Test func pollRunsServersConcurrentlyAndPreservesSuccessfulServer() async {
    let probe = ControlledProbe(results: [
        "server-10222": .success(.snapshot(.free)),
        "server-10165": .failure(TestError.unreachable),
    ], delay: .milliseconds(150))
    let coordinator = MonitorCoordinator(servers: [.server10222, .server10165], probe: probe)
    let clock = ContinuousClock()
    let elapsed = await clock.measure { _ = await coordinator.poll() }
    let cycle = await coordinator.poll()

    #expect(elapsed < .milliseconds(280))
    #expect(cycle.snapshots["server-10222"] != nil)
    #expect(cycle.health["server-10165"] != .online)
}
```

- [ ] **Step 2: Run the coordinator tests and verify failure**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: FAIL because `MonitorCoordinator` and `MonitorCycle` do not exist.

- [ ] **Step 3: Implement task-group polling**

```swift
public struct MonitorCycle: Sendable {
    public let snapshots: [String: ServerSnapshot]
    public let health: [String: ServerHealth]
    public let events: [MonitorEvent]
    public let completedAt: Date
}

public actor MonitorCoordinator {
    public func poll() async -> MonitorCycle {
        let results = await withTaskGroup(of: ProbeOutcome.self, returning: [ProbeOutcome].self) { group in
            for server in servers {
                group.addTask { await ProbeOutcome.capture(server: server, probe: self.probe) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        // Sort by configured server order, then feed each outcome into StateTracker.
    }
}
```

Serialize overlapping manual/timer refreshes inside the actor by returning the active poll task rather than launching a duplicate.

- [ ] **Step 4: Run coordinator and full tests**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: all tests PASS.

- [ ] **Step 5: Commit concurrent monitoring**

```bash
git add Sources/GPUMonitorCore/MonitorCoordinator.swift Tests/GPUMonitorCoreTests/MonitorCoordinatorTests.swift
git commit -m "feat: coordinate concurrent GPU server polling"
```

---

### Task 6: Notification formatting and macOS delivery

**Files:**
- Create: `Sources/GPUMonitorCore/NotificationFormatter.swift`
- Create: `Sources/GPUMonitorNotifications/MacOSNotificationSink.swift`
- Test: `Tests/GPUMonitorCoreTests/NotificationFormatterTests.swift`

**Interfaces:**
- Produces: `NotificationSink.send(events:) async`, `NotificationMessage`, and `NotificationFormatter.messages(for:)`.
- Consumes: `[MonitorEvent]`.

- [ ] **Step 1: Write aggregation tests**

```swift
@Test func formatterAggregatesFreeGPUsOnTheSameServer() {
    let messages = NotificationFormatter().messages(for: [
        .gpuChanged(server: .server10222, gpu: .gpu(index: 0, .free), from: .busy, to: .free),
        .gpuChanged(server: .server10222, gpu: .gpu(index: 2, .free), from: .busy, to: .free),
    ])
    #expect(messages == [
        NotificationMessage(title: "GPU 已空闲", body: "服务器 10222：GPU 0、GPU 2 已空闲")
    ])
}

@Test func formatterIncludesProcessForBusyGPU() {
    let messages = NotificationFormatter().messages(for: [
        .gpuChanged(server: .server10165, gpu: .busyGPU(index: 1, pid: 12345, name: "python"), from: .free, to: .busy)
    ])
    #expect(messages[0].body == "服务器 10165：GPU 1 开始占用（python，PID 12345）")
}
```

- [ ] **Step 2: Run formatting tests and verify failure**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: FAIL because the formatter types do not exist.

- [ ] **Step 3: Implement deterministic per-server aggregation**

```swift
public struct NotificationMessage: Equatable, Sendable {
    public let title: String
    public let body: String
}

public protocol NotificationSink {
    func requestAuthorization() async
    func send(events: [MonitorEvent]) async
}
```

Sort GPU indices numerically. Produce separate free and busy messages per server, plus one offline/recovered message for each connectivity event. `MacOSNotificationSink` requests `.alert` and `.sound` authorization, converts each message to `UNMutableNotificationContent`, and schedules it with a UUID identifier. Install and strongly retain a `UNUserNotificationCenterDelegate` before startup so foreground notifications use `.banner`, `.list`, and `.sound`.

- [ ] **Step 4: Run tests and compile the app target**

Run: `swift run GPUMonitorCoreTestsRunner && swift build --product GPUMonitor`

Expected: all tests PASS and app target builds.

- [ ] **Step 5: Commit notification delivery**

```bash
git add Sources/GPUMonitorCore/NotificationFormatter.swift Sources/GPUMonitorNotifications/MacOSNotificationSink.swift Tests/GPUMonitorCoreTests/NotificationFormatterTests.swift
git commit -m "feat: deliver aggregated GPU status notifications"
```

---

### Task 7: Menu-bar application model and UI

**Files:**
- Modify: `Sources/GPUMonitorApp/GPUMonitorApp.swift`
- Create: `Sources/GPUMonitorApp/AppLifecycleDelegate.swift`
- Create: `Sources/GPUMonitorApp/AppModel.swift`
- Create: `Sources/GPUMonitorApp/MenuContentView.swift`

**Interfaces:**
- Consumes: `ConfigurationStore`, `SSHGPUProbe`, `MonitorCoordinator`, `MonitorCycle`, `NotificationSink`.
- Produces: `AppModel.start()`, `AppModel.refresh()`, menu title/color, server sections, manual refresh, and quit action.

- [ ] **Step 1: Implement the main-actor application model**

```swift
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshots: [String: ServerSnapshot] = [:]
    @Published private(set) var health: [String: ServerHealth] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var startupError: String?

    private var loopTask: Task<Void, Never>?

    func start() async {
        guard loopTask == nil else { return }
        await notifications.requestAuthorization()
        await refresh()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let cycle = await coordinator.poll()
        snapshots.merge(cycle.snapshots) { _, new in new }
        health = cycle.health
        lastUpdated = cycle.completedAt
        await notifications.send(events: cycle.events)
    }
}
```

Load configuration during initialization. If loading fails, set `startupError` and keep the menu usable. Cancel `loopTask` when the app model is deallocated.

- [ ] **Step 2: Implement the menu-bar scene and content**

```swift
@main
struct GPUMonitorApp: App {
    @StateObject private var model: AppModel

    init() {
        let liveModel = AppModel.live()
        _model = StateObject(wrappedValue: liveModel)
        Task { @MainActor in await liveModel.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView().environmentObject(model)
        } label: {
            Label(model.menuTitle, systemImage: model.menuSystemImage)
        }
        .menuBarExtraStyle(.window)
    }
}
```

`MenuContentView` renders servers in configuration order. Each GPU row displays occupancy, utilization, `used / total` memory in MiB or GiB, temperature, and the first process name/PID when busy. It renders `unknown`, short failure, and offline states distinctly. The footer contains the last-updated time, a disabled-while-running “立即刷新” button, and an “退出” button calling `NSApplication.shared.terminate(nil)`.

`AppModel.live()` creates the configuration store, probe, coordinator, and notification sink but does not create a second timer. `GPUMonitorApp.init()` installs an `@NSApplicationDelegateAdaptor`, configures it with the live model, then starts the model exactly once, independently of whether the menu is opened. Manual and periodic refreshes re-read notification authorization; application activation triggers the same coalesced read. Cancellation or a non-cooperative authorization provider cannot delay `stop()`, and late results after a lifecycle-generation change are discarded.

`AppLifecycleDelegate.applicationShouldTerminate` returns `.terminateLater`, awaits one shared `model.stop()`, then calls `reply(toApplicationShouldTerminate: true)`. Repeated termination requests do not duplicate shutdown. The menu's “退出” action only calls `NSApplication.shared.terminate(nil)` so all normal quit paths share the AppKit bridge.

- [ ] **Step 3: Build and run a local development smoke test**

Run: `swift build --product GPUMonitor && .build/debug/GPUMonitor`

Expected: a `GPU —/—` menu item appears; configuration/SSH errors are visible without a crash. Quit it from the menu before continuing.

- [ ] **Step 4: Run the entire unit suite**

Run: `swift run GPUMonitorCoreTestsRunner`

Expected: all tests PASS.

- [ ] **Step 5: Commit the native UI**

```bash
git add Sources/GPUMonitorApp
git commit -m "feat: add native GPU Monitor menu-bar interface"
```

---

### Task 8: App packaging, SSH provisioning, and documentation

**Files:**
- Create: `packaging/Info.plist`
- Create: `scripts/package_app.sh`
- Create: `scripts/install_app.sh`
- Create: `scripts/provision_ssh.sh`
- Create: `README.md`

**Interfaces:**
- Produces: `dist/GPU Monitor.app`, `/Applications/GPU Monitor.app`, restricted SSH key installation, and operator instructions.
- Consumes: release `GPUMonitor` executable and approved server configuration.

- [ ] **Step 1: Add the background-app Info.plist**

Include these exact keys: `CFBundleIdentifier=com.yxy.gpumonitor`, `CFBundleExecutable=GPUMonitor`, `CFBundleName=GPU Monitor`, `CFBundleDisplayName=GPU Monitor`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=1.0.0`, `CFBundleVersion=1`, `LSMinimumSystemVersion=14.0`, `LSUIElement=true`, and `NSHighResolutionCapable=true`.

- [ ] **Step 2: Add deterministic package and install scripts**

`scripts/package_app.sh` must:

```bash
#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
swift build -c release --package-path "$project_dir" --product GPUMonitor
app_dir="$project_dir/dist/GPU Monitor.app"
[[ "$app_dir" == "$project_dir/dist/GPU Monitor.app" ]] || exit 2
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
ditto "$project_dir/.build/release/GPUMonitor" "$app_dir/Contents/MacOS/GPUMonitor"
ditto "$project_dir/packaging/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
```

`scripts/install_app.sh` first detects only the current user's process whose executable path exactly equals `/Applications/GPU Monitor.app/Contents/MacOS/GPUMonitor`. When present it requests graceful quit through `/usr/bin/osascript` using the fixed bundle identifier, waits boundedly for that exact process to disappear, and fails closed if the Apple event fails or the app remains alive. It never sends SIGTERM/SIGKILL. It then replaces only `/Applications/GPU Monitor.app` with the freshly packaged app using `ditto`, verifies the installed signature, and opens it. It must never touch other applications.

- [ ] **Step 3: Add an interactive password-free-source SSH provisioning script**

The script creates `~/.ssh/gpu_monitor_ed25519` if absent, creates the dedicated known-hosts file, then loops over ports `10222` and `10165`. Each initial `ssh` command uses `StrictHostKeyChecking=accept-new`, displays the learned fingerprint, and prompts interactively for the server password.

Build an authorized-key line with the public key and these restrictions:

```text
no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding,command="nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits && printf '\n__GPU_MONITOR_PROCESSES__\n' && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits"
```

The two queries and marker are chained with `&&`: a nonzero GPU or compute query makes the SSH sample fail. The offline behavior harness must cover each nonzero query independently, plus the successful empty compute-output case.

Append only when the public-key blob is absent. After installation, run a `BatchMode=yes` sample and a second attempt containing `echo SHOULD_NOT_RUN`; fail provisioning if the latter text appears, proving the forced command prevented the requested shell command.

The script contains no password literal and does not accept a password command-line argument.

- [ ] **Step 4: Document install, status meanings, privacy, editing servers, and uninstall**

README commands must be exact:

```bash
cd /Users/yxy/Documents/workspace/gpu-monitor
./scripts/provision_ssh.sh
swift run GPUMonitorCoreTestsRunner
./scripts/package_app.sh
./scripts/install_app.sh
```

Uninstall removes `/Applications/GPU Monitor.app` and optionally the dedicated local key/config after an explicit user choice. Removing remote key lines is documented as a separate explicit command; no uninstall script automatically edits the servers.

- [ ] **Step 5: Verify shell syntax, package, signature, and unit tests**

Run:

```bash
zsh -n scripts/package_app.sh scripts/install_app.sh scripts/provision_ssh.sh
swift run GPUMonitorCoreTestsRunner
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 "dist/GPU Monitor.app"
plutil -lint "dist/GPU Monitor.app/Contents/Info.plist"
```

Expected: shell syntax clean, all tests PASS, code signature valid, and plist reports `OK`.

- [ ] **Step 6: Commit packaging and operator documentation**

```bash
git add packaging scripts README.md
git commit -m "feat: package and provision GPU Monitor"
```

---

### Task 9: Real-server provisioning, installation, and acceptance

**Files:**
- Modify only if evidence reveals a defect: files identified by the failing test or runtime error.
- Generate locally: `~/Library/Application Support/GPUMonitor/servers.json`
- Generate locally: `~/Library/Application Support/GPUMonitor/known_hosts`
- Generate locally: `~/.ssh/gpu_monitor_ed25519` and `.pub`
- Install: `/Applications/GPU Monitor.app`

**Interfaces:**
- Consumes: all preceding tasks.
- Produces: a working installed monitor against both approved servers.

- [ ] **Step 1: Run all automated verification before touching remote state**

Run: `swift run GPUMonitorCoreTestsRunner && ./scripts/package_app.sh`

Expected: all tests PASS and the app bundle signature verifies.

- [ ] **Step 2: Provision the restricted key interactively**

Run: `./scripts/provision_ssh.sh`

Expected for both ports: host fingerprint shown, password accepted, key appended once, valid GPU sample returned, and attempted `echo SHOULD_NOT_RUN` absent from output.

- [ ] **Step 3: Capture and validate real GPU samples**

Run the exact `BatchMode=yes` SSH command for each configured port and save output only under a temporary directory created by `mktemp -d`. Feed each output through a temporary executable integration harness or the app's probe path. Confirm at least one GPU row per reachable server and no parse errors. Delete the temporary directory after validation.

- [ ] **Step 4: Install and launch the app**

Run: `./scripts/install_app.sh`

Expected: `/Applications/GPU Monitor.app` launches with no Dock icon and a menu-bar item appears.

- [ ] **Step 5: Verify runtime behavior**

Verify these acceptance checks:

1. Both server sections reach `online` independently.
2. GPU counts match direct `nvidia-smi` output on each server.
3. Utilization, memory, temperature, and process status update after a manual refresh.
4. The timer produces a new last-updated time after 15 seconds.
5. Notification permission is present in macOS settings or the UI reports denial clearly.
6. No login item named GPU Monitor exists.
7. `ps` shows only the app and short-lived SSH processes, with no stuck SSH process after 30 seconds.

- [ ] **Step 6: Run final regression verification**

Run:

```bash
swift run GPUMonitorCoreTestsRunner
git status --short
codesign --verify --deep --strict --verbose=2 "/Applications/GPU Monitor.app"
plutil -p "/Applications/GPU Monitor.app/Contents/Info.plist" | grep 'LSUIElement.*1'
```

Expected: all tests PASS; only documented generated artifacts are untracked; installed signature verifies; `LSUIElement` equals `1`.

- [ ] **Step 7: Commit any evidence-driven fixes, then tag the local release**

If no fix was needed, skip the fix commit. After a clean final verification:

```bash
git tag -a v1.0.0 -m "GPU Monitor v1.0.0"
```

Do not push or publish the repository.
