# GPU Monitor Four-Server Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend GPU Monitor from two to four independently monitored GPU servers, label the existing servers as 3090 and the new eight-GPU servers as A100, keep the menu usable through scrolling, provision restricted SSH access, and reinstall a verified single app instance.

**Architecture:** Keep the existing generic `MonitorCoordinator`, `StateTracker`, `SSHGPUProbe`, and notification pipeline. Extend `ConfigurationStore` with an idempotent, non-destructive four-server migration; bound only the server section of the SwiftUI menu inside a vertical scroll view; and expand the explicit provisioning allowlist and its behavioral harness from two endpoint pairs to four. Deployment continues through the existing restricted-key provisioner and transactional installer.

**Tech Stack:** Swift 6.3 in Swift 5 language mode, Swift Package Manager, SwiftUI, AppKit, UserNotifications, Swift Testing, OpenSSH, zsh test harnesses, ad-hoc code signing, macOS 14 or later.

## Global Constraints

- Approved display order for a new or current standard configuration is exactly `3090 · 10122`, `3090 · 10165`, `A100 · 18200`, `A100 · 13000`.
- Approved endpoint pairs are exactly `122.207.108.8:10122`, `122.207.108.7:10165`, `js2.blockelite.cn:18200`, and `js2.blockelite.cn:13000`; never create a host/port Cartesian product.
- All four records use username `yanxiaoyang`; no password may enter source, configuration, arguments, environment variables, logs, tests, documentation, or the app bundle.
- Preserve custom records, labels, usernames, identity paths, and relative order. Add a missing A100 endpoint once, using a stable collision-safe ID when its approved ID is occupied.
- Poll all configured servers independently every 15 seconds. Keep the existing two-sample GPU confirmation, three-connectivity-failure offline threshold, recovery behavior, and last-successful-snapshot rules.
- GPU occupancy is determined only by the presence of compute processes; utilization, memory, and temperature remain display-only metrics.
- Keep macOS notifications and the existing `NotificationSink` boundary; do not implement WeChat delivery in this change.
- Do not add login items, LaunchAgents, launch-at-login code, remote shell access, process control, or GPU history persistence.
- Keep the dedicated Ed25519 identity, dedicated `known_hosts`, fixed read-only `nvidia-smi` forced command, forwarding/PTY restrictions, and fail-closed host-key behavior.
- Install only at `/Applications/GPU Monitor.app`; use the existing staging, signature, bundle-identity, backup, restore, and graceful-quit workflow.
- Keep all source and documentation under `/Users/yxy/Documents/workspace/gpu-monitor`.
- Use the custom Swift Testing executables: `swift run GPUMonitorCoreTestsRunner` and `swift run GPUMonitorAppTestsRunner`.

---

## Planned File Changes

```text
Sources/GPUMonitorCore/ConfigurationStore.swift
    Four approved defaults plus deterministic, idempotent migration.
Sources/GPUMonitorApp/MenuContentView.swift
    Bounded scrollable server list with the existing footer outside it.
Tests/GPUMonitorCoreTests/ConfigurationStoreTests.swift
    Defaults, standard migration, customization, collision, and no-rewrite tests.
Tests/GPUMonitorCoreTests/TestSupport.swift
    A100 server/GPU fixtures used by monitoring regression tests.
Tests/GPUMonitorCoreTests/MonitorCoordinatorTests.swift
    True four-way concurrency and one-server-failure isolation.
Tests/GPUMonitorCoreTests/StateTrackerTests.swift
    A100 busy/free double-confirmation regression.
Tests/GPUMonitorAppTests/AppModelTests.swift
    Four-server snapshot merge, ordering, summary, health, and event forwarding.
Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift
    Native A100 busy/free notification formatting and delivery.
Tests/GPUMonitorAppTests/MenuContentViewTests.swift
    Bounded vertical server-scroll policy and view shape.
scripts/provision_ssh.sh
    Four explicit approved host/port pairs.
Tests/PackagingTests/provisioning_behavior_test.sh
    Four host keys and exact 20-call SSH endpoint/option audit.
Tests/PackagingTests/package_scripts_test.sh
    Static policy checks for all four endpoint pairs and README commands.
README.md
    Four-server install, migration, security, and removal instructions.
```

`Package.swift`, `SSHGPUProbe.swift`, `MonitorCoordinator.swift`, `StateTracker.swift`, `AppModel.swift`, `scripts/package_app.sh`, `scripts/install_app.sh`, and `packaging/Info.plist` require no production changes unless a new regression test exposes a real defect.

---

### Task 1: Four-server defaults and lossless configuration migration

**Files:**
- Modify: `Tests/GPUMonitorCoreTests/ConfigurationStoreTests.swift`
- Modify: `Sources/GPUMonitorCore/ConfigurationStore.swift`

**Interfaces:**
- Consumes: `ServerConfig.init(id:label:host:port:username:identityFile:)`, `AppPaths.live().identityFileURL.path`.
- Produces: unchanged public signature `ConfigurationStore.loadOrCreate() throws -> [ServerConfig]`.
- Migration identity: same endpoint means equal `(host, port)`; stable fallback IDs are `<approved-id>-migrated`, then `<approved-id>-migrated-2`, `<approved-id>-migrated-3`, and so on.

- [ ] **Step 1: Replace the two configuration tests with a four-case RED suite**

Keep the imports and add these helpers and tests to `Tests/GPUMonitorCoreTests/ConfigurationStoreTests.swift`:

```swift
import Foundation
import Testing
import GPUMonitorCore

private func makeConfigurationRoot() throws -> (root: URL, config: URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, root.appending(path: "servers.json"))
}

private func writeServers(_ servers: [ServerConfig], to url: URL) throws {
    try JSONEncoder().encode(servers).write(to: url, options: .atomic)
}

@Test func loadOrCreateWritesFourApprovedServersWithoutPasswords() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let identity = AppPaths.live().identityFileURL.path

    let servers = try ConfigurationStore(configURL: paths.config).loadOrCreate()

    #expect(servers == [
        ServerConfig(id: "server-10122", label: "3090 · 10122", host: "122.207.108.8", port: 10122, username: "yanxiaoyang", identityFile: identity),
        ServerConfig(id: "server-10165", label: "3090 · 10165", host: "122.207.108.7", port: 10165, username: "yanxiaoyang", identityFile: identity),
        ServerConfig(id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200, username: "yanxiaoyang", identityFile: identity),
        ServerConfig(id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000, username: "yanxiaoyang", identityFile: identity),
    ])
    let text = String(decoding: try Data(contentsOf: paths.config), as: UTF8.self)
    #expect(!text.localizedCaseInsensitiveContains("password"))
}

@Test func standardTwoServerConfigurationMigratesToApprovedFourServerOrder() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try writeServers([
        ServerConfig(id: "server-10122", label: "10122", host: "122.207.108.8", port: 10122, username: "first-user", identityFile: "/custom/first-key"),
        ServerConfig(id: "server-10165", label: "10165", host: "122.207.108.7", port: 10165, username: "second-user", identityFile: "/custom/second-key"),
    ], to: paths.config)

    let loaded = try ConfigurationStore(configURL: paths.config).loadOrCreate()

    #expect(loaded.map(\.id) == ["server-10122", "server-10165", "server-a100-18200", "server-a100-13000"])
    #expect(loaded.map(\.label) == ["3090 · 10122", "3090 · 10165", "A100 · 18200", "A100 · 13000"])
    #expect(loaded.map { "\($0.host):\($0.port)" } == [
        "122.207.108.8:10122", "122.207.108.7:10165",
        "js2.blockelite.cn:18200", "js2.blockelite.cn:13000",
    ])
    #expect(loaded[0].username == "first-user")
    #expect(loaded[0].identityFile == "/custom/first-key")
    #expect(loaded[1].username == "second-user")
    #expect(loaded[1].identityFile == "/custom/second-key")
    let persisted = try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: paths.config))
    #expect(persisted == loaded)
}

@Test func migrationPreservesCustomRecordsAndDoesNotDuplicateAnExistingA100Endpoint() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let original = [
        ServerConfig(id: "server-10122", label: "实验室主机", host: "122.207.108.8", port: 10122, username: "custom-user", identityFile: "/custom/first-key"),
        ServerConfig(id: "custom-a100", label: "我的 A100", host: "js2.blockelite.cn", port: 18200, username: "custom-user", identityFile: "/custom/a100-key"),
        ServerConfig(id: "custom-server", label: "保留我", host: "example.invalid", port: 2200, username: "other-user", identityFile: "/custom/other-key"),
        ServerConfig(id: "server-10165", label: "第二台自定义", host: "122.207.108.8", port: 10165, username: "second-user", identityFile: "/custom/second-key"),
    ]
    try writeServers(original, to: paths.config)

    let loaded = try ConfigurationStore(configURL: paths.config).loadOrCreate()

    #expect(loaded[0] == original[0])
    #expect(loaded[1] == original[1])
    #expect(loaded[2] == original[2])
    #expect(loaded[3].host == "122.207.108.7")
    #expect(loaded[3].label == "第二台自定义")
    #expect(loaded.filter { $0.host == "js2.blockelite.cn" && $0.port == 18200 }.count == 1)
    #expect(loaded.last?.id == "server-a100-13000")
}

@Test func occupiedApprovedIDUsesStableFallbackAndSecondLoadDoesNotRewrite() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try writeServers([
        ServerConfig(id: "server-a100-18200", label: "占用批准 ID", host: "other.invalid", port: 22, username: "other", identityFile: "/other/key"),
        ServerConfig(id: "server-a100-18200-migrated", label: "占用首个回退 ID", host: "other.invalid", port: 23, username: "other", identityFile: "/other/key"),
    ], to: paths.config)

    let store = ConfigurationStore(configURL: paths.config)
    let first = try store.loadOrCreate()
    #expect(first.first { $0.host == "js2.blockelite.cn" && $0.port == 18200 }?.id == "server-a100-18200-migrated-2")
    #expect(first.filter { $0.host == "js2.blockelite.cn" && $0.port == 18200 }.count == 1)

    let sentinel = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: paths.config.path)
    let bytesBefore = try Data(contentsOf: paths.config)
    let second = try store.loadOrCreate()
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.config.path)
    let bytesAfter = try Data(contentsOf: paths.config)

    #expect(second == first)
    #expect(bytesAfter == bytesBefore)
    #expect(attributes[.modificationDate] as? Date == sentinel)
}
```

- [ ] **Step 2: Run the Core test runner and confirm RED**

Run:

```bash
swift run GPUMonitorCoreTestsRunner
```

Expected: the new default/migration assertions fail because only two numeric-label defaults exist and A100 endpoints are not appended.

- [ ] **Step 3: Replace `ConfigurationStore` migration and defaults with the minimal complete implementation**

Use this implementation in `Sources/GPUMonitorCore/ConfigurationStore.swift`:

```swift
import Foundation

public struct ConfigurationStore: Sendable {
    public let configURL: URL

    public init(configURL: URL = AppPaths.live().configURL) {
        self.configURL = configURL
    }

    public func loadOrCreate() throws -> [ServerConfig] {
        let fileManager = FileManager.default
        let identityFile = AppPaths.live().identityFileURL.path
        if fileManager.fileExists(atPath: configURL.path) {
            let servers = try JSONDecoder().decode(
                [ServerConfig].self,
                from: Data(contentsOf: configURL)
            )
            let migrated = migrateApprovedServers(in: servers, identityFile: identityFile)
            if migrated != servers {
                try write(migrated)
            }
            return migrated
        }

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let servers = approvedServers(identityFile: identityFile)
        try write(servers)
        return servers
    }

    private func migrateApprovedServers(
        in servers: [ServerConfig],
        identityFile: String
    ) -> [ServerConfig] {
        var migrated = servers.map(migrateLegacyServer)
        for approved in approvedServers(identityFile: identityFile).suffix(2) {
            let endpointExists = migrated.contains {
                $0.host == approved.host && $0.port == approved.port
            }
            guard !endpointExists else { continue }
            migrated.append(ServerConfig(
                id: availableID(preferred: approved.id, in: migrated),
                label: approved.label,
                host: approved.host,
                port: approved.port,
                username: approved.username,
                identityFile: approved.identityFile
            ))
        }
        return migrated
    }

    private func migrateLegacyServer(_ server: ServerConfig) -> ServerConfig {
        let host = server.id == "server-10165" &&
            server.host == "122.207.108.8" &&
            server.port == 10165
            ? "122.207.108.7"
            : server.host

        let label: String
        switch (server.id, host, server.port, server.label) {
        case ("server-10122", "122.207.108.8", 10122, "10122"):
            label = "3090 · 10122"
        case ("server-10165", "122.207.108.7", 10165, "10165"):
            label = "3090 · 10165"
        default:
            label = server.label
        }

        return ServerConfig(
            id: server.id,
            label: label,
            host: host,
            port: server.port,
            username: server.username,
            identityFile: server.identityFile
        )
    }

    private func availableID(preferred: String, in servers: [ServerConfig]) -> String {
        let used = Set(servers.map(\.id))
        guard used.contains(preferred) else { return preferred }
        let migrated = "\(preferred)-migrated"
        guard used.contains(migrated) else { return migrated }
        var suffix = 2
        while used.contains("\(migrated)-\(suffix)") {
            suffix += 1
        }
        return "\(migrated)-\(suffix)"
    }

    private func write(_ servers: [ServerConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: configURL, options: .atomic)
    }

    private func approvedServers(identityFile: String) -> [ServerConfig] {
        [
            ServerConfig(id: "server-10122", label: "3090 · 10122", host: "122.207.108.8", port: 10122, username: "yanxiaoyang", identityFile: identityFile),
            ServerConfig(id: "server-10165", label: "3090 · 10165", host: "122.207.108.7", port: 10165, username: "yanxiaoyang", identityFile: identityFile),
            ServerConfig(id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200, username: "yanxiaoyang", identityFile: identityFile),
            ServerConfig(id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000, username: "yanxiaoyang", identityFile: identityFile),
        ]
    }
}
```

- [ ] **Step 4: Run configuration tests twice and confirm GREEN plus idempotence**

Run:

```bash
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorCoreTestsRunner
git diff --check
```

Expected: both runs pass all Core tests; the second run reports no migration-specific failure; `git diff --check` prints nothing.

- [ ] **Step 5: Commit the configuration deliverable**

```bash
git add Sources/GPUMonitorCore/ConfigurationStore.swift Tests/GPUMonitorCoreTests/ConfigurationStoreTests.swift
git commit -m "feat: migrate GPU Monitor to four servers"
```

---

### Task 2: Four-server polling and A100 notification regressions

**Files:**
- Modify: `Tests/GPUMonitorCoreTests/TestSupport.swift`
- Modify: `Tests/GPUMonitorCoreTests/MonitorCoordinatorTests.swift`
- Modify: `Tests/GPUMonitorCoreTests/StateTrackerTests.swift`
- Modify: `Tests/GPUMonitorAppTests/AppModelTests.swift`
- Modify: `Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift`

**Interfaces:**
- Consumes: `MonitorCoordinator.init(servers:probe:tracker:)`, `StateTracker.recordSuccess(_:)`, `AppModel.refresh()`, and `MacOSNotificationSink.send(events:)`.
- Produces: regression proof only; the generic production coordinator, tracker, app model, and notification sink should remain unchanged.

- [ ] **Step 1: Add A100 fixtures and make the concurrency test barrier support all configured servers**

Append these two extension blocks to `Tests/GPUMonitorCoreTests/TestSupport.swift`:

```swift
extension ServerConfig {
    static let serverA10018200 = ServerConfig(
        id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200,
        username: "yanxiaoyang", identityFile: "/tmp/gpu_monitor_ed25519"
    )

    static let serverA10013000 = ServerConfig(
        id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000,
        username: "yanxiaoyang", identityFile: "/tmp/gpu_monitor_ed25519"
    )
}

extension GPUSnapshot {
    static func a100GPU(index: Int, _ occupancy: GPUOccupancy) -> GPUSnapshot {
        GPUSnapshot(
            index: index, uuid: "A100-GPU-\(index)", name: "NVIDIA A100-SXM4-80GB",
            utilizationPercent: occupancy == .free ? 0 : 92,
            usedMemoryMiB: occupancy == .free ? 0 : 40_960,
            totalMemoryMiB: 81_920, temperatureCelsius: occupancy == .free ? 34 : 71,
            processes: occupancy == .free ? [] : [.init(pid: 12345, name: "python", usedMemoryMiB: 40_000)]
        )
    }
}
```

Replace `ConcurrentBarrierProbe` in `Tests/GPUMonitorCoreTests/MonitorCoordinatorTests.swift` with an N-way barrier:

```swift
private actor ConcurrentBarrierProbe: GPUProbing {
    private let results: [String: Result<ServerSnapshot, Error>]
    private let participantCount: Int
    private var blockedSamples: [CheckedContinuation<Void, Never>] = []
    private var activeSampleCount = 0
    private var isReleased = false
    private(set) var maximumConcurrentSampleCount = 0

    init(results: [String: Result<ServerSnapshot, Error>], participantCount: Int) {
        precondition(participantCount > 0)
        self.results = results
        self.participantCount = participantCount
    }

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        activeSampleCount += 1
        maximumConcurrentSampleCount = max(maximumConcurrentSampleCount, activeSampleCount)
        if !isReleased {
            if activeSampleCount == participantCount {
                releaseBlockedSamples()
            } else {
                await withCheckedContinuation { blockedSamples.append($0) }
            }
        }
        activeSampleCount -= 1
        return try results[server.id, default: .failure(ProbeFailure.connectivity)].get()
    }

    func releaseBlockedSamples() {
        guard !isReleased else { return }
        isReleased = true
        let samples = blockedSamples
        blockedSamples.removeAll()
        samples.forEach { $0.resume() }
    }
}
```

Rename the existing deadlock-guard call from `releaseBlockedSample()` to `releaseBlockedSamples()`.

- [ ] **Step 2: Expand the coordinator test to four concurrent, isolated outcomes**

Replace `pollRunsServersConcurrentlyAndPreservesSuccessfulServer()` with:

```swift
@Test func pollRunsFourServersConcurrentlyAndIsolatesOneFailure() async {
    let servers: [ServerConfig] = [.server10122, .server10165, .serverA10018200, .serverA10013000]
    let probe = ConcurrentBarrierProbe(results: [
        ServerConfig.server10122.id: .success(.snapshot(.free, server: .server10122)),
        ServerConfig.server10165.id: .success(.snapshot(.busy, server: .server10165)),
        ServerConfig.serverA10018200.id: .success(ServerSnapshot(
            server: .serverA10018200,
            gpus: [.a100GPU(index: 0, .free)],
            capturedAt: .distantPast
        )),
        ServerConfig.serverA10013000.id: .failure(ProbeFailure.connectivity),
    ], participantCount: servers.count)
    let coordinator = MonitorCoordinator(servers: servers, probe: probe)
    let deadlockGuard = Task {
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        await probe.releaseBlockedSamples()
    }

    let cycle = await coordinator.poll()
    deadlockGuard.cancel()
    await deadlockGuard.value

    #expect(await probe.maximumConcurrentSampleCount == 4)
    #expect(cycle.snapshots.keys.sorted() == [
        "server-10122", "server-10165", "server-a100-18200",
    ])
    #expect(cycle.health["server-10122"] == .online)
    #expect(cycle.health["server-10165"] == .online)
    #expect(cycle.health["server-a100-18200"] == .online)
    #expect(cycle.health["server-a100-13000"] == .degraded(
        message: ProbeFailure.connectivity.localizedDescription,
        consecutiveFailures: 1
    ))
}
```

- [ ] **Step 3: Add an A100-specific double-confirmation tracker test**

Append to `Tests/GPUMonitorCoreTests/StateTrackerTests.swift`:

```swift
@Test func a100BusyAndFreeChangesRequireTwoSamplesAndStayServerScoped() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    func sample(_ occupancy: GPUOccupancy) -> ServerSnapshot {
        ServerSnapshot(
            server: .serverA10018200,
            gpus: [.a100GPU(index: 0, occupancy)],
            capturedAt: .distantPast
        )
    }

    _ = await tracker.recordSuccess(sample(.free))
    #expect((await tracker.recordSuccess(sample(.busy))).events.isEmpty)
    #expect((await tracker.recordSuccess(sample(.busy))).events == [
        .gpuChanged(server: .serverA10018200, gpu: .a100GPU(index: 0, .busy), from: .free, to: .busy),
    ])
    #expect((await tracker.recordSuccess(sample(.free))).events.isEmpty)
    #expect((await tracker.recordSuccess(sample(.free))).events == [
        .gpuChanged(server: .serverA10018200, gpu: .a100GPU(index: 0, .free), from: .busy, to: .free),
    ])
}
```

- [ ] **Step 4: Add a four-server AppModel merge and event-forwarding test**

Add `serverA10018200` and `serverA10013000` beside the existing AppModel test servers, then append:

```swift
@Test @MainActor
func fourServerRefreshRetainsFailedSnapshotAndForwardsConfirmedA100Events() async {
    let servers = [server10122, server10165, serverA10018200, serverA10013000]
    let initialSnapshots = Dictionary(uniqueKeysWithValues: servers.map {
        ($0.id, snapshot(server: $0, gpus: [gpu(index: 0, busy: false)]))
    })
    let busyA100 = gpu(index: 0, busy: true)
    let freeA100 = gpu(index: 0, busy: false)
    let events: [MonitorEvent] = [
        .gpuChanged(server: serverA10018200, gpu: freeA100, from: .busy, to: .free),
        .gpuChanged(server: serverA10013000, gpu: busyA100, from: .free, to: .busy),
    ]
    let source = CycleSource([
        cycle(
            snapshots: initialSnapshots,
            health: Dictionary(uniqueKeysWithValues: servers.map { ($0.id, ServerHealth.online) })
        ),
        cycle(
            snapshots: [
                server10122.id: initialSnapshots[server10122.id]!,
                serverA10018200.id: snapshot(server: serverA10018200, gpus: [freeA100]),
                serverA10013000.id: snapshot(server: serverA10013000, gpus: [busyA100]),
            ],
            health: [
                server10122.id: .online,
                server10165.id: .degraded(message: "timed out", consecutiveFailures: 1),
                serverA10018200.id: .online,
                serverA10013000.id: .online,
            ],
            events: events
        ),
    ])
    let notifications = FakeNotifications()
    let model = AppModel(
        servers: servers,
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    await model.refresh()
    await model.refresh()

    #expect(model.servers.map(\.id) == servers.map(\.id))
    #expect(model.snapshots.count == 4)
    #expect(model.snapshots[server10165.id] == initialSnapshots[server10165.id])
    #expect(model.health[server10165.id] == .degraded(message: "timed out", consecutiveFailures: 1))
    #expect(model.menuTitle == "GPU 3/4 空闲")
    #expect(await notifications.sentEvents == [[], events])
    await model.stop()
}
```

Define the two AppModel test fixtures exactly as:

```swift
private let serverA10018200 = ServerConfig(
    id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200,
    username: "tester", identityFile: "/tmp/test-key"
)
private let serverA10013000 = ServerConfig(
    id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000,
    username: "tester", identityFile: "/tmp/test-key"
)
```

- [ ] **Step 5: Add native macOS notification coverage for both A100 directions**

Append to `Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift`:

```swift
@Test func macOSSinkFormatsA100BusyAndFreeChangesWithConfiguredLabel() async {
    let center = FakeNotificationCenter()
    let sink = MacOSNotificationSink(center: center)
    let server = ServerConfig(
        id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn",
        port: 18200, username: "tester", identityFile: "/private/test-key"
    )
    let free = GPUSnapshot(
        index: 2, uuid: "GPU-A100", name: "NVIDIA A100-SXM4-80GB", utilizationPercent: 0,
        usedMemoryMiB: 0, totalMemoryMiB: 81_920, temperatureCelsius: 34, processes: []
    )
    let busy = GPUSnapshot(
        index: 2, uuid: "GPU-A100", name: "NVIDIA A100-SXM4-80GB", utilizationPercent: 92,
        usedMemoryMiB: 40_960, totalMemoryMiB: 81_920, temperatureCelsius: 71,
        processes: [.init(pid: 24680, name: "python", usedMemoryMiB: 40_000)]
    )

    let result = await sink.send(events: [
        .gpuChanged(server: server, gpu: busy, from: .free, to: .busy),
        .gpuChanged(server: server, gpu: free, from: .busy, to: .free),
    ])
    let requests = await center.recordedRequests

    #expect(result.isSuccess)
    #expect(requests.map(\.title) == ["GPU 开始占用", "GPU 已空闲"])
    #expect(requests.map(\.body) == [
        "服务器 A100 · 18200：GPU 2 开始占用（python，PID 24680）",
        "服务器 A100 · 18200：GPU 2 已空闲",
    ])
}
```

- [ ] **Step 6: Run both test runners and keep generic production code unchanged**

Run:

```bash
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
git diff --check
```

Expected: all tests pass. If the generic production types behave as mapped, only test files change in this task.

- [ ] **Step 7: Commit the four-server behavioral proof**

```bash
git add Tests/GPUMonitorCoreTests/TestSupport.swift Tests/GPUMonitorCoreTests/MonitorCoordinatorTests.swift Tests/GPUMonitorCoreTests/StateTrackerTests.swift Tests/GPUMonitorAppTests/AppModelTests.swift Tests/GPUMonitorAppTests/MacOSNotificationSinkTests.swift
git commit -m "test: cover four-server monitoring and alerts"
```

---

### Task 3: Scrollable server list with a fixed footer

**Files:**
- Create: `Tests/GPUMonitorAppTests/MenuContentViewTests.swift`
- Modify: `Sources/GPUMonitorApp/MenuContentView.swift`

**Interfaces:**
- Produces internal `MenuLayout.serverListMaxHeight: CGFloat` and `ScrollableServerList: View` for `@testable` inspection.
- Consumes: `[ServerConfig]`, `[String: ServerSnapshot]`, and `[String: ServerHealth]`; no new dependency.
- Automated coverage checks that the server component's body contains a `ScrollView` and that the explicit height policy remains `520`. Step 3 source review verifies that `.frame(maxHeight:)` consumes that policy and that the footer remains outside; Task 6 verifies both behaviors in the running app. The plan does not claim that Swift reflection proves modifier arguments or footer placement.

- [ ] **Step 1: Add a RED view-shape test for a bounded vertical scroll container**

Create `Tests/GPUMonitorAppTests/MenuContentViewTests.swift`:

```swift
import GPUMonitorCore
import SwiftUI
import Testing
@testable import GPUMonitorUI

@Test @MainActor
func fourServerListUsesABoundedVerticalScrollContainer() {
    let servers = [10122, 10165, 18200, 13000].map { port in
        ServerConfig(
            id: "server-\(port)", label: "server \(port)", host: "example.invalid",
            port: port, username: "tester", identityFile: "/tmp/test-key"
        )
    }
    let list = ScrollableServerList(servers: servers, snapshots: [:], health: [:])
    let bodyType = String(reflecting: type(of: list.body))

    #expect(bodyType.contains("SwiftUI.ScrollView"))
    #expect(MenuLayout.serverListMaxHeight == 520)
    #expect(MenuLayout.serverListMaxHeight < 600)
}
```

- [ ] **Step 2: Run App tests and confirm the new internal types are missing**

Run:

```bash
swift run GPUMonitorAppTestsRunner
```

Expected: compilation fails because `MenuLayout` and `ScrollableServerList` do not exist.

- [ ] **Step 3: Extract only the server area into a bounded scroll view**

Add before `MenuContentView` in `Sources/GPUMonitorApp/MenuContentView.swift`:

```swift
enum MenuLayout {
    static let serverListMaxHeight: CGFloat = 520
}

struct ScrollableServerList: View {
    let servers: [ServerConfig]
    let snapshots: [String: ServerSnapshot]
    let health: [String: ServerHealth]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { Divider() }
                    ServerSection(
                        server: server,
                        snapshot: snapshots[server.id],
                        health: health[server.id] ?? .unknown
                    )
                }
            }
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: MenuLayout.serverListMaxHeight)
    }
}
```

Replace only the non-empty branch in `MenuContentView.body`:

```swift
if model.servers.isEmpty {
    ContentUnavailableView(
        "没有可监控的服务器",
        systemImage: "server.rack",
        description: Text(AppModel.emptyConfigurationGuidance)
    )
    .frame(maxWidth: .infinity, minHeight: 120)
} else {
    ScrollableServerList(
        servers: model.servers,
        snapshots: model.snapshots,
        health: model.health
    )
}

Divider()
StatusFooter(model: model)
```

The divider and `StatusFooter` must remain after the `ScrollableServerList` call in the outer `VStack`; keep `.padding(14)`, `.frame(width: 540)`, GPU row rendering, refresh, and quit behavior unchanged.

- [ ] **Step 4: Run App tests and strict UI build**

Run:

```bash
swift run GPUMonitorAppTestsRunner
swift build --product GPUMonitor -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
```

Expected: all App tests pass and the executable builds with no warnings.

- [ ] **Step 5: Commit the menu layout deliverable**

```bash
git add Sources/GPUMonitorApp/MenuContentView.swift Tests/GPUMonitorAppTests/MenuContentViewTests.swift
git commit -m "feat: scroll four-server GPU menu"
```

---

### Task 4: Four-endpoint restricted SSH provisioning and operator documentation

**Files:**
- Modify: `Tests/PackagingTests/provisioning_behavior_test.sh`
- Modify: `Tests/PackagingTests/package_scripts_test.sh`
- Modify: `scripts/provision_ssh.sh`
- Modify: `README.md`

**Interfaces:**
- Keeps: `./scripts/provision_ssh.sh` accepts no arguments and prompts through system SSH.
- Produces: explicit ordered `endpoint_specs` with four entries and a harness that proves five correctly paired SSH calls per endpoint.

- [ ] **Step 1: Expand the offline SSH fixtures and exact call auditor before production code**

In `new_case()` inside `Tests/PackagingTests/provisioning_behavior_test.sh`, write four known-host entries:

```zsh
{
    print -r -- "[122.207.108.8]:10122 $host_type $host_blob"
    print -r -- "[122.207.108.7]:10165 $host_type $host_blob"
    print -r -- "[js2.blockelite.cn]:18200 $host_type $host_blob"
    print -r -- "[js2.blockelite.cn]:13000 $host_type $host_blob"
} > "$case_home/Library/Application Support/GPUMonitor/known_hosts"
```

Replace `logged_ssh_calls_use_quoted_known_hosts()` with this exact ordered-pair audit:

```zsh
logged_ssh_calls_use_quoted_known_hosts() {
    local expected="UserKnownHostsFile=\"$case_home/Library/Application Support/GPUMonitor/known_hosts\""
    /usr/bin/awk -v expected="$expected" '
        function finish_call( expected_port, expected_destination) {
            if (!in_call) { invalid = 1; return }
            calls++
            if (calls <= 5) {
                expected_port = "10122"
                expected_destination = "yanxiaoyang@122.207.108.8"
            } else if (calls <= 10) {
                expected_port = "10165"
                expected_destination = "yanxiaoyang@122.207.108.7"
            } else if (calls <= 15) {
                expected_port = "18200"
                expected_destination = "yanxiaoyang@js2.blockelite.cn"
            } else {
                expected_port = "13000"
                expected_destination = "yanxiaoyang@js2.blockelite.cn"
            }
            if (known_hosts_count != 1 || port != expected_port ||
                destination_count != 1 || destination != expected_destination) {
                invalid = 1
            }
            if (batch_mode == "no") initial_calls++
            else if (batch_mode == "yes") batch_calls++
            else invalid = 1
            in_call = 0
        }

        $0 == "__GPU_MONITOR_SSH_CALL__" {
            if (in_call) invalid = 1
            in_call = 1
            known_hosts_count = 0
            batch_mode = ""
            port = ""
            destination = ""
            destination_count = 0
            expecting_port = 0
            next
        }
        $0 == "__GPU_MONITOR_SSH_END__" { finish_call(); next }
        in_call && index($0, "ARG:") == 1 {
            argument = substr($0, 5)
            if (expecting_port) { port = argument; expecting_port = 0 }
            else if (argument == "-p") expecting_port = 1
            if (argument == expected) known_hosts_count++
            if (argument ~ /^yanxiaoyang@/) {
                destination_count++
                destination = argument
            }
            if (argument == "BatchMode=no") batch_mode = "no"
            if (argument == "BatchMode=yes") batch_mode = "yes"
            next
        }
        { invalid = 1 }
        END {
            if (in_call || calls != 20 || initial_calls != 4 || batch_calls != 16) invalid = 1
            exit invalid ? 1 : 0
        }
    ' "$ssh_log"
}
```

- [ ] **Step 2: Add four-endpoint static policy expectations**

Add these checks to `Tests/PackagingTests/package_scripts_test.sh` alongside the current endpoint checks:

```zsh
check "provisioner covers port 18200" file_contains "$provision_script" '18200'
check "provisioner covers port 13000" file_contains "$provision_script" '13000'
check "provisioner pairs the first A100 host and port" file_line_contains_both "$provision_script" 'js2.blockelite.cn' '18200'
check "provisioner pairs the second A100 host and port" file_line_contains_both "$provision_script" 'js2.blockelite.cn' '13000'
check "README documents all four approved ports" file_contains "$readme" '`10122`、`10165`、`18200` 和 `13000`'
check "README documents A100 port 18200" file_contains "$readme" 'ssh -p 18200 yanxiaoyang@js2.blockelite.cn'
check "README documents A100 port 13000" file_contains "$readme" 'ssh -p 13000 yanxiaoyang@js2.blockelite.cn'
```

Replace the old README exact-port check that expects only `` `10122` 和 `10165` `` with the new all-four check above; retain both original endpoint checks and the stale `10222` rejection.

- [ ] **Step 3: Run both shell suites and confirm RED**

Run:

```bash
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
```

Expected: provisioning call-count/pairing and static endpoint/documentation checks fail because production still names only two endpoints.

- [ ] **Step 4: Extend the production allowlist with two exact A100 endpoint pairs**

Change only `endpoint_specs` in `scripts/provision_ssh.sh`:

```zsh
endpoint_specs=(
    "122.207.108.8 10122"
    "122.207.108.7 10165"
    "js2.blockelite.cn 18200"
    "js2.blockelite.cn 13000"
)
```

Do not change the restricted authorized-key line, password-authentication handoff, `known_hosts` quoting, host-key policy, forwarding test, validation, or rollback logic.

- [ ] **Step 5: Update README with exact four-server operating instructions**

Replace the opening description with:

```markdown
GPU Monitor 是 macOS 14 及以上版本的原生菜单栏应用。它每 15 秒通过专用受限 SSH 密钥查询四台服务器的 GPU 状态，并在 GPU 占用状态或服务器在线状态稳定变化时发送系统通知。应用不配置开机自启，也不提供远程终端或进程控制能力。
```

In the installation section, use this exact endpoint sentence and table:

```markdown
SSH 配置会按顺序访问 `10122`、`10165`、`18200` 和 `13000`；需要认证时，密码只由系统 `ssh` 在交互式终端读取，不进入脚本、配置、日志或应用包。

| 显示名称 | SSH 端点 |
| --- | --- |
| `3090 · 10122` | `122.207.108.8:10122` |
| `3090 · 10165` | `122.207.108.7:10165` |
| `A100 · 18200` | `js2.blockelite.cn:18200` |
| `A100 · 13000` | `js2.blockelite.cn:13000` |
```

Replace the migration paragraph with:

```markdown
升级时，应用先纠正精确匹配的旧 `server-10165` 地址，再只更新仍使用旧数字标签的两台 3090 记录，并按批准顺序追加缺失的 A100 端点。自定义标签、记录、用户名、密钥路径和相对顺序会保留；同一主机名和端口不会重复添加，批准 ID 冲突时使用稳定回退 ID。只有配置实际变化时才原子写回。
```

Replace the two-server removal login block with all four explicit commands:

```bash
ssh -p 10122 yanxiaoyang@122.207.108.8
ssh -p 10165 yanxiaoyang@122.207.108.7
ssh -p 18200 yanxiaoyang@js2.blockelite.cn
ssh -p 13000 yanxiaoyang@js2.blockelite.cn
```

Keep the warning that local uninstall never edits remote `authorized_keys`, and do not add any credential value.

- [ ] **Step 6: Run shell syntax, provisioning behavior, policy, and installer regressions**

Run:

```bash
zsh -n scripts/provision_ssh.sh scripts/package_app.sh scripts/install_app.sh
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
zsh Tests/PackagingTests/install_app_behavior_test.sh
git diff --check
```

Expected: all three shell test suites print their final success line; syntax and diff checks print nothing.

- [ ] **Step 7: Commit provisioning and documentation**

```bash
git add scripts/provision_ssh.sh Tests/PackagingTests/provisioning_behavior_test.sh Tests/PackagingTests/package_scripts_test.sh README.md
git commit -m "feat: provision four GPU servers"
```

---

### Task 5: Full local quality gate and packaged-app verification

**Files:**
- Verify only: all files changed in Tasks 1–4
- Generated and replaced by packaging: `dist/GPU Monitor.app`

**Interfaces:**
- Consumes: both Swift test runners and all three shell test suites.
- Produces: a release bundle whose signature, plist, and executable match the tested source.

- [ ] **Step 1: Run the complete automated suite from a clean command prompt**

```bash
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/install_app_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
```

Expected: every test runner exits zero and each shell harness prints its final success line.

- [ ] **Step 2: Run the strict concurrency and warnings-as-errors build**

```bash
swift build --product GPUMonitor -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Expected: `Build complete!` with exit status zero and no warning promoted to an error.

- [ ] **Step 3: Build and verify the distributable app**

```bash
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 "dist/GPU Monitor.app"
plutil -lint "dist/GPU Monitor.app/Contents/Info.plist"
test -x "dist/GPU Monitor.app/Contents/MacOS/GPUMonitor"
```

Expected: signing verification succeeds, plist reports `OK`, and the executable check exits zero.

- [ ] **Step 4: Review the complete branch before touching live servers**

Run:

```bash
git status --short
git diff --check d044e43..HEAD
git log --oneline -5
```

Then invoke `superpowers:requesting-code-review` against the implementation range beginning after commit `d044e43`. Resolve every blocking finding with a focused test-first commit and rerun Steps 1–3. Expected final state: only the intentionally generated `dist` bundle may appear changed or untracked; source and test changes are committed and review has no blocking item.

---

### Task 6: Restricted-key provisioning, transactional reinstall, and live four-server acceptance

**Files and external state:**
- Remote: exact GPU Monitor restricted line in each server's `~/.ssh/authorized_keys`.
- Local: `~/.ssh/gpu_monitor_ed25519`, `~/Library/Application Support/GPUMonitor/known_hosts`, `~/Library/Application Support/GPUMonitor/servers.json`.
- Installed app: `/Applications/GPU Monitor.app`.

**Interfaces:**
- Uses interactive system SSH only for password entry.
- Uses the same public-key, host-key, no-forwarding, and timeout options as `SSHGPUProbe` for direct acceptance samples.

- [ ] **Step 1: Confirm DNS and TCP reachability without changing server state**

```zsh
(
set -uo pipefail
reachability_failed=0
if dscacheutil -q host -a name js2.blockelite.cn; then
  print -r -- "PASS DNS js2.blockelite.cn"
else
  print -u2 -- "FAIL DNS js2.blockelite.cn"
  reachability_failed=1
fi

endpoint_specs=(
  "122.207.108.8 10122"
  "122.207.108.7 10165"
  "js2.blockelite.cn 18200"
  "js2.blockelite.cn 13000"
)
for endpoint_spec in "${endpoint_specs[@]}"; do
  host="${endpoint_spec%% *}"
  port="${endpoint_spec##* }"
  if nc -vz -w 5 "$host" "$port"; then
    print -r -- "PASS TCP $host:$port"
  else
    print -u2 -- "FAIL TCP $host:$port"
    reachability_failed=1
  fi
done
(( reachability_failed == 0 ))
)
```

Expected: the DNS result and every endpoint receive an individual `PASS` or `FAIL` line, all four TCP checks run even when an earlier one fails, and the block exits nonzero if any check failed. Any failure is recorded as an external connectivity blocker; no endpoint is substituted.

- [ ] **Step 2: Provision and verify the restricted key on all four endpoints**

Run in a PTY:

```bash
./scripts/provision_ssh.sh
```

Enter the supplied login password only at each system SSH password prompt. Expected for every endpoint: a learned/pinned fingerprint, a valid restricted sample, forced-command proof, forwarding rejection, final validation, and `Restricted key and forced command verified`. If a host key changed, stop and verify it with the administrator; never delete or replace `known_hosts` automatically.

- [ ] **Step 3: Run the production probe and parser against all four servers**

Build a disposable verifier that links the already-tested `GPUMonitorCore` objects and calls the real `SSHGPUProbe.sample(server:)`. This reuses the production SSH argv, `CommandRunner` 30-second overall process deadline, failure classification, and full `NVIDIAOutputParser`; the independent OpenSSH `ConnectTimeout=8` remains unchanged. It prints only server labels, GPU counts, and A100 inventory results:

```zsh
(
set -euo pipefail
swift build --product GPUMonitor
verifier_root=$(/usr/bin/mktemp -d "${TMPDIR%/}/gpu-monitor-verifier.XXXXXX")
/bin/chmod 700 "$verifier_root"
cleanup_verifier() {
    [[ "$verifier_root" == "${TMPDIR%/}/gpu-monitor-verifier."* ]]
    /usr/bin/trash "$verifier_root"
}
trap cleanup_verifier EXIT
build_dir=$(swift build --show-bin-path)

/usr/bin/xcrun swiftc -parse-as-library \
    -I "$build_dir/Modules" \
    "$build_dir"/GPUMonitorCore.build/*.swift.o \
    -o "$verifier_root/live-verifier" - <<'SWIFT'
import Darwin
import Foundation
import GPUMonitorCore

@main
struct LiveVerifier {
    static func main() async {
        let identity = AppPaths.live().identityFileURL.path
        let servers = [
            ServerConfig(id: "server-10122", label: "3090 · 10122", host: "122.207.108.8", port: 10122, username: "yanxiaoyang", identityFile: identity),
            ServerConfig(id: "server-10165", label: "3090 · 10165", host: "122.207.108.7", port: 10165, username: "yanxiaoyang", identityFile: identity),
            ServerConfig(id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200, username: "yanxiaoyang", identityFile: identity),
            ServerConfig(id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000, username: "yanxiaoyang", identityFile: identity),
        ]
        let probe = SSHGPUProbe()
        var failed = false

        for server in servers {
            do {
                let snapshot = try await probe.sample(server: server)
                let isA100Endpoint = server.port == 18200 || server.port == 13000
                let hasApprovedA100Inventory = snapshot.gpus.count == 8 &&
                    snapshot.gpus.allSatisfy { $0.name.localizedCaseInsensitiveContains("A100") }
                if snapshot.gpus.isEmpty || (isA100Endpoint && !hasApprovedA100Inventory) {
                    failed = true
                }
                print("\(server.label): GPU count=\(snapshot.gpus.count), A100 inventory=\(isA100Endpoint ? hasApprovedA100Inventory : true)")
            } catch let failure as ProbeFailure {
                failed = true
                print("\(server.label): FAILED \(failure.localizedDescription)")
            } catch {
                failed = true
                print("\(server.label): FAILED unexpected local verification error")
            }
        }
        exit(failed ? 1 : 0)
    }
}
SWIFT

"$verifier_root/live-verifier"
)
```

Expected: four sanitized summary lines; every production probe parses successfully, and both A100 endpoints report `GPU count=8, A100 inventory=true`. No process name, PID, raw SSH stderr, host key, or credential is printed.

- [ ] **Step 4: Transactionally reinstall and launch the app**

```bash
./scripts/install_app.sh
```

Expected: the existing installed process exits gracefully, the candidate is staged and verified, the old bundle is guarded until replacement verification succeeds, the transaction directory is removed, and one installed copy opens.

- [ ] **Step 5: Verify installed identity, hash equality, one process, and no residue**

```zsh
(
set -euo pipefail
codesign --verify --deep --strict --verbose=2 "/Applications/GPU Monitor.app"
cmp -s \
  "dist/GPU Monitor.app/Contents/MacOS/GPUMonitor" \
  "/Applications/GPU Monitor.app/Contents/MacOS/GPUMonitor"
installed_executable="/Applications/GPU Monitor.app/Contents/MacOS/GPUMonitor"
current_uid=$(/usr/bin/id -u)
installed_pids() {
  /bin/ps -axo pid=,uid=,comm= | while read -r process_pid process_uid process_executable; do
    if [[ "$process_uid" == "$current_uid" && "$process_executable" == "$installed_executable" ]]; then
      print -r -- "$process_pid"
    fi
  done
}
process_count=0
for _ in {1..100}; do
  process_output=$(installed_pids)
  process_count=0
  if [[ -n "$process_output" ]]; then
    process_count=$(print -r -- "$process_output" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  fi
  (( process_count > 1 )) && {
    print -u2 -- "More than one installed GPU Monitor process is running"
    exit 1
  }
  (( process_count == 1 )) && break
  /bin/sleep 0.1
done
print -r -- "$process_count"
(( process_count == 1 ))
residue=$(/usr/bin/find /Applications -maxdepth 1 -name '.gpu-monitor-install.*' -print)
[[ -z "$residue" ]] || {
  print -u2 -- "Install transaction residue remains"
  exit 1
}
)
```

Expected: signature and `cmp` succeed, process count prints `1`, and `find` prints nothing.

- [ ] **Step 6: Verify the live migrated configuration and four pinned host keys**

```zsh
(
set -euo pipefail
export LC_ALL=C
config="$HOME/Library/Application Support/GPUMonitor/servers.json"
known_hosts="$HOME/Library/Application Support/GPUMonitor/known_hosts"
[[ -f "$config" && ! -L "$config" ]]
[[ -f "$known_hosts" && ! -L "$known_hosts" ]]
expected_ids=("server-10122" "server-10165" "server-a100-18200" "server-a100-13000")
expected_labels=("3090 · 10122" "3090 · 10165" "A100 · 18200" "A100 · 13000")
expected_hosts=("122.207.108.8" "122.207.108.7" "js2.blockelite.cn" "js2.blockelite.cn")
expected_ports=(10122 10165 18200 13000)

structure_check=$(
    /usr/bin/plutil -convert xml1 -o - "$config" |
        /usr/bin/xmllint --nonet --xpath \
            'name(/plist/*) = "array" and count(/plist/array/*) = 4' -
)
[[ "$structure_check" == true ]]

for index in 0 1 2 3; do
    expected_index=$((index + 1))
    actual=$(/usr/bin/plutil -extract "$index.id" raw -expect string -o - "$config")
    [[ "$actual" == "$expected_ids[$expected_index]" ]]
    actual=$(/usr/bin/plutil -extract "$index.label" raw -expect string -o - "$config")
    [[ "$actual" == "$expected_labels[$expected_index]" ]]
    actual=$(/usr/bin/plutil -extract "$index.host" raw -expect string -o - "$config")
    [[ "$actual" == "$expected_hosts[$expected_index]" ]]
    actual=$(/usr/bin/plutil -extract "$index.port" raw -expect integer -o - "$config")
    [[ "$actual" == "$expected_ports[$expected_index]" ]]
done
set +e
/usr/bin/grep -Fiq -- password "$config"
password_match_status=$?
set -e
(( password_match_status == 1 ))
/usr/bin/ssh-keygen -F '[122.207.108.8]:10122' -f "$known_hosts" >/dev/null
/usr/bin/ssh-keygen -F '[122.207.108.7]:10165' -f "$known_hosts" >/dev/null
/usr/bin/ssh-keygen -F '[js2.blockelite.cn]:18200' -f "$known_hosts" >/dev/null
/usr/bin/ssh-keygen -F '[js2.blockelite.cn]:13000' -f "$known_hosts" >/dev/null
)
```

Expected ID/label/host/port values appear in the approved order, the XML conversion plus XPath check confirms a top-level four-record array without modifying the JSON source, the password-field check succeeds silently, and all four host-key lookups exit zero.

- [ ] **Step 7: Exercise the running menu and observe exact app-owned SSH pairings**

Open the menu, confirm all four labeled sections appear, scroll through both eight-row A100 sections, and verify notification status, last update, `立即刷新`, and `退出` remain visible below the scroll area. Start the following observer in a terminal or background tool session. As soon as its `observer-ready` control message appears on stderr, open the menu and click `立即刷新` once within five seconds. The 80-second window covers a pre-existing 30-second outer-bound probe, the 15-second polling interval, and a further 30-second bounded automatic cycle, with a small synchronization margin; the block records only approved endpoint pairs rather than full SSH arguments:

```zsh
(
set -euo pipefail
installed_executable="/Applications/GPU Monitor.app/Contents/MacOS/GPUMonitor"
current_uid=$(/usr/bin/id -u)
app_pid=$(
    /bin/ps -axo pid=,uid=,comm= | while read -r process_pid process_uid process_executable; do
        if [[ "$process_uid" == "$current_uid" && "$process_executable" == "$installed_executable" ]]; then
            print -r -- "$process_pid"
        fi
    done
)
[[ "$app_pid" == <-> ]]
typeset -A seen_pairs
unexpected_pair=0
print -u2 -- "observer-ready"
end_at=$((SECONDS + 80))
while (( SECONDS < end_at )); do
    while read -r parent_pid command; do
        [[ "$parent_pid" == "$app_pid" && "$command" == /usr/bin/ssh\ * ]] || continue
        case "$command" in
            (*'-p 10122 '*yanxiaoyang@122.207.108.8*) observed_pair='122.207.108.8 10122'; seen_pairs[$observed_pair]=1 ;;
            (*'-p 10165 '*yanxiaoyang@122.207.108.7*) observed_pair='122.207.108.7 10165'; seen_pairs[$observed_pair]=1 ;;
            (*'-p 18200 '*yanxiaoyang@js2.blockelite.cn*) observed_pair='js2.blockelite.cn 18200'; seen_pairs[$observed_pair]=1 ;;
            (*'-p 13000 '*yanxiaoyang@js2.blockelite.cn*) observed_pair='js2.blockelite.cn 13000'; seen_pairs[$observed_pair]=1 ;;
            (*) unexpected_pair=1 ;;
        esac
    done < <(/bin/ps -axo ppid=,command=)
    /bin/sleep 0.01
done
observation_failed=0
for expected_pair in \
    '122.207.108.8 10122' \
    '122.207.108.7 10165' \
    'js2.blockelite.cn 18200' \
    'js2.blockelite.cn 13000'; do
    if [[ "${seen_pairs[$expected_pair]-}" == 1 ]]; then
        print -r -- "$expected_pair"
    else
        print -u2 -- "Missing app-owned SSH observation for $expected_pair"
        observation_failed=1
    fi
done
if (( unexpected_pair != 0 )); then
    print -u2 -- "Observed an unapproved app-owned SSH endpoint pairing"
    observation_failed=1
fi
for _ in {1..100}; do
    active_ssh_children=0
    while read -r parent_pid command; do
        if [[ "$parent_pid" == "$app_pid" && "$command" == /usr/bin/ssh\ * ]]; then
            active_ssh_children=$((active_ssh_children + 1))
        fi
    done < <(/bin/ps -axo ppid=,command=)
    (( active_ssh_children == 0 )) && break
    /bin/sleep 0.1
done
if (( active_ssh_children != 0 )); then
    print -u2 -- "App-owned SSH process remained after the bounded drain wait"
    observation_failed=1
fi
(( observation_failed == 0 ))
)
```

Expected output is exactly these four pairs:

```text
122.207.108.8 10122
122.207.108.7 10165
js2.blockelite.cn 18200
js2.blockelite.cn 13000
```

No `122.207.108.8:10165`, no stale `10222`, and no cross-paired `js2.blockelite.cn` port may appear. After the cycle, no SSH child should remain stuck. `ps` sampling is corroborating runtime evidence rather than a deterministic exec audit: if an expected short-lived process is missed, rerun this observer once with the synchronized refresh before diagnosing the app; the exact production probe verifier in Step 3, live configuration in Step 6, and visible four-server data remain mandatory independent gates.

- [ ] **Step 8: Confirm no autostart was added and close the verification gate**

```zsh
(
set -euo pipefail

set +e
rg -n 'ServiceManagement|SMAppService|LaunchAgent|LSSharedFileList' Sources scripts packaging
source_status=$?
set -e
(( source_status == 1 ))

launch_dirs=()
[[ -d "$HOME/Library/LaunchAgents" ]] && launch_dirs+=("$HOME/Library/LaunchAgents")
[[ -d /Library/LaunchAgents ]] && launch_dirs+=(/Library/LaunchAgents)
if (( ${#launch_dirs[@]} > 0 )); then
  set +e
  rg -il 'GPU Monitor|com\.yxy\.gpumonitor' "${launch_dirs[@]}"
  launch_status=$?
  set -e
  (( launch_status == 1 ))
fi

login_items=$(/usr/bin/osascript -e 'tell application "System Events" to get the name of every login item')
set +e
print -r -- "$login_items" | rg -qi '(^|, )GPU Monitor(,|$)|com\.yxy\.gpumonitor'
login_status=$?
set -e
(( login_status == 1 ))

repository_status=$(git status --short --untracked-files=all)
[[ -z "$repository_status" ]] || {
  print -u2 -- "Repository has unintended changes after installation acceptance"
  print -u2 -- "$repository_status"
  exit 1
}
)
```

Expected: source and LaunchAgent checks find no autostart integration; the validated System Events query has no GPU Monitor login item; repository status is exactly empty (ignored `.build` and `dist` artifacts do not appear). Exit status `1` from each `rg` is the required “no match” result, while status `0` (match) and status `2+` (read/search error) both fail the gate. Invoke `superpowers:verification-before-completion`, repeat any check it requires, and report each endpoint separately. Full live acceptance is complete only if all four endpoints pass; otherwise identify the unreachable endpoint as an external connectivity blocker without hiding the successful ones.
