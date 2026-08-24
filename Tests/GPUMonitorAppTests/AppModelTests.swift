import Foundation
import GPUMonitorCore
@testable import GPUMonitorUI
import Testing

private actor FakeNotifications: NotificationSink, NotificationAuthorizationProviding {
    private let requestedState: NotificationAuthorizationState
    private let deliveryResult: NotificationDeliveryResult
    private(set) var authorizationRequests = 0
    private(set) var sentEvents: [[MonitorEvent]] = []

    init(
        requestedState: NotificationAuthorizationState = .authorized,
        deliveryResult: NotificationDeliveryResult = .init(
            attemptedCount: 0,
            deliveredCount: 0,
            failures: []
        )
    ) {
        self.requestedState = requestedState
        self.deliveryResult = deliveryResult
    }

    func requestAuthorization() async -> NotificationAuthorizationState {
        authorizationRequests += 1
        return requestedState
    }

    func authorizationState() async -> NotificationAuthorizationState { requestedState }

    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        sentEvents.append(events)
        return deliveryResult
    }
}

private actor CycleSource {
    private let cycles: [MonitorCycle]
    private(set) var calls = 0

    init(_ cycles: [MonitorCycle]) {
        self.cycles = cycles
    }

    func poll() -> MonitorCycle {
        defer { calls += 1 }
        return cycles[min(calls, cycles.count - 1)]
    }
}

private actor ControlledCycleSource {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func poll() async -> MonitorCycle {
        calls += 1
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseContinuation = $0 }
        return cycle(snapshots: [:], health: [server10222.id: .unknown])
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func cancelPending() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private actor ControlledAuthorizationNotifications: NotificationSink, NotificationAuthorizationProviding {
    private var authorizationStartedWaiter: CheckedContinuation<Void, Never>?
    private var authorizationRelease: CheckedContinuation<Void, Never>?
    private var authorizationStarted = false

    func requestAuthorization() async -> NotificationAuthorizationState {
        authorizationStarted = true
        authorizationStartedWaiter?.resume()
        authorizationStartedWaiter = nil
        await withCheckedContinuation { authorizationRelease = $0 }
        return .authorized
    }

    func authorizationState() async -> NotificationAuthorizationState { .notDetermined }

    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        .init(attemptedCount: 0, deliveredCount: 0, failures: [])
    }

    func waitUntilAuthorizationStarts() async {
        guard !authorizationStarted else { return }
        await withCheckedContinuation { authorizationStartedWaiter = $0 }
    }

    func releaseAuthorization() {
        authorizationRelease?.resume()
        authorizationRelease = nil
    }
}

private actor CancellationAwareAuthorizationNotifications: NotificationSink, NotificationAuthorizationProviding {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var authorizationContinuation: CheckedContinuation<NotificationAuthorizationState, Never>?
    private var started = false
    private(set) var observedCancellation = false

    func requestAuthorization() async -> NotificationAuthorizationState {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                started = true
                startedWaiter?.resume()
                startedWaiter = nil
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func authorizationState() async -> NotificationAuthorizationState { .notDetermined }

    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        .init(attemptedCount: 0, deliveredCount: 0, failures: [])
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func cancel() {
        observedCancellation = true
        authorizationContinuation?.resume(returning: .error)
        authorizationContinuation = nil
    }
}

private actor CancellationControlledPoll {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<MonitorCycle, Never>?
    private(set) var started = false
    private(set) var observedCancellation = false
    private(set) var cancelRequests = 0

    func poll() async -> MonitorCycle {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { resultContinuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func cancel() {
        observedCancellation = true
        release()
    }

    func cancelActivePoll() {
        cancelRequests += 1
        cancel()
    }

    func release() {
        resultContinuation?.resume(returning: cycle(snapshots: [:], health: [:]))
        resultContinuation = nil
    }
}

private let server10222 = ServerConfig(
    id: "server-10222",
    label: "10222",
    host: "example.invalid",
    port: 10222,
    username: "tester",
    identityFile: "/tmp/test-key"
)

private let server10165 = ServerConfig(
    id: "server-10165",
    label: "10165",
    host: "example.invalid",
    port: 10165,
    username: "tester",
    identityFile: "/tmp/test-key"
)

private func gpu(index: Int, busy: Bool) -> GPUSnapshot {
    GPUSnapshot(
        index: index,
        uuid: "GPU-\(index)",
        name: "Test GPU",
        utilizationPercent: busy ? 87 : 0,
        usedMemoryMiB: busy ? 12_288 : 128,
        totalMemoryMiB: 24_576,
        temperatureCelsius: busy ? 70 : 34,
        processes: busy ? [.init(pid: 12345, name: "python", usedMemoryMiB: 12_000)] : []
    )
}

private func snapshot(server: ServerConfig, gpus: [GPUSnapshot]) -> ServerSnapshot {
    ServerSnapshot(server: server, gpus: gpus, capturedAt: Date(timeIntervalSince1970: 100))
}

private func cycle(
    snapshots: [String: ServerSnapshot],
    health: [String: ServerHealth],
    events: [MonitorEvent] = [],
    completedAt: Date = Date(timeIntervalSince1970: 200)
) -> MonitorCycle {
    MonitorCycle(snapshots: snapshots, health: health, events: events, completedAt: completedAt)
}

@Test @MainActor
func startRequestsAuthorizationAndPollsExactlyOnceAcrossRepeatedCalls() async {
    let firstCycle = cycle(
        snapshots: [server10222.id: snapshot(server: server10222, gpus: [gpu(index: 0, busy: false)])],
        health: [server10222.id: .online]
    )
    let source = CycleSource([firstCycle])
    let notifications = FakeNotifications(requestedState: .denied)
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10222],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )

    await model.start()
    await model.start()

    #expect(await source.calls == 1)
    #expect(await notifications.authorizationRequests == 1)
    #expect(model.notificationAuthorization == .denied)
    #expect(model.lastUpdated == firstCycle.completedAt)
    #expect(await sleeper.requestedDurations == [.seconds(15)])
    await model.stop()
}

@Test @MainActor
func timerDoesNotStartUntilAuthorizationAndInitialRefreshFinish() async {
    let source = ControlledCycleSource()
    let notifications = ControlledAuthorizationNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10222],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )
    let startTask = Task { await model.start() }

    await notifications.waitUntilAuthorizationStarts()
    for _ in 0..<100 { await Task.yield() }
    #expect(await source.calls == 0)
    #expect(await sleeper.requestedDurations.isEmpty)

    await notifications.releaseAuthorization()
    await source.waitUntilStarted()
    #expect(await sleeper.requestedDurations.isEmpty)
    await source.release()
    await startTask.value
    for _ in 0..<100 where await sleeper.requestedDurations.isEmpty {
        await Task.yield()
    }
    #expect(await source.calls == 1)
    #expect(await sleeper.requestedDurations == [.seconds(15)])
    await model.stop()
}

@Test @MainActor
func timerUsesOneFifteenSecondLoopAndStopPreventsAnotherPoll() async {
    let firstCycle = cycle(snapshots: [:], health: [server10222.id: .unknown])
    let source = CycleSource([firstCycle])
    let notifications = FakeNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10222],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )

    await model.start()
    await sleeper.resumeNext()
    for _ in 0..<100 where await source.calls < 2 {
        await Task.yield()
    }
    #expect(await source.calls == 2)

    await model.stop()
    await sleeper.resumeNext()
    await Task.yield()
    #expect(await source.calls == 2)
}

@Test @MainActor
func refreshMergesSnapshotsPreservesOrderAndReportsDeliveryFailure() async {
    let previous = snapshot(server: server10222, gpus: [gpu(index: 0, busy: false)])
    let updated = snapshot(server: server10165, gpus: [gpu(index: 1, busy: true)])
    let event = MonitorEvent.serverOffline(server: server10222, message: "timed out")
    let source = CycleSource([
        cycle(snapshots: [server10222.id: previous], health: [server10222.id: .online]),
        cycle(
            snapshots: [server10165.id: updated],
            health: [server10222.id: .degraded(message: "timed out", consecutiveFailures: 1), server10165.id: .online],
            events: [event]
        ),
    ])
    let notifications = FakeNotifications(deliveryResult: .init(
        attemptedCount: 1,
        deliveredCount: 0,
        failures: [.init(messageIndex: 0, reason: .schedulingFailed)]
    ))
    let model = AppModel(
        servers: [server10222, server10165],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    await model.refresh()
    await model.refresh()

    #expect(model.servers.map(\.id) == [server10222.id, server10165.id])
    #expect(model.snapshots[server10222.id] == previous)
    #expect(model.snapshots[server10165.id] == updated)
    #expect(model.recentErrorSummary == "通知发送失败：1 条")
    #expect(await notifications.sentEvents.last == [event])
}

@Test @MainActor
func summaryAndColorRepresentUnknownWarningOfflineFreeAndBusyStates() async {
    let notifications = FakeNotifications()
    let model = AppModel(
        servers: [server10222, server10165],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    #expect(model.menuTitle == "GPU —/—")
    #expect(model.menuStatus == .unknown)

    model.applyForTesting(cycle(
        snapshots: [
            server10222.id: snapshot(server: server10222, gpus: [gpu(index: 0, busy: false)]),
            server10165.id: snapshot(server: server10165, gpus: [gpu(index: 1, busy: true)]),
        ],
        health: [server10222.id: .online, server10165.id: .online]
    ))
    #expect(model.menuTitle == "GPU 1/2 空闲")
    #expect(model.menuStatus == .available)

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10222.id: .online, server10165.id: .unknown]
    ))
    #expect(model.menuStatus == .unknown)

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10222.id: .degraded(message: "timeout", consecutiveFailures: 1), server10165.id: .online]
    ))
    #expect(model.menuStatus == .warning)
    #expect(model.recentErrorSummary == "服务器 10222：timeout")

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10222.id: .offline(message: "unreachable"), server10165.id: .online]
    ))
    #expect(model.menuStatus == .offline)
}

@Test @MainActor
func startupConfigurationErrorRemainsVisibleAndMenuUsable() async {
    let notifications = FakeNotifications(requestedState: .error)
    let model = AppModel(
        servers: [],
        startupError: "配置读取失败：格式错误",
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    await model.start()

    #expect(model.startupError == "配置读取失败：格式错误")
    #expect(model.notificationAuthorization == .error)
    #expect(model.menuTitle == "GPU —/—")
    await model.stop()
}

@Test @MainActor
func stopCancelsAndWaitsForAnActiveRefresh() async {
    let poll = CancellationControlledPoll()
    let notifications = FakeNotifications()
    let model = AppModel(
        servers: [server10222],
        poll: { await poll.poll() },
        cancelPoll: { await poll.cancelActivePoll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )
    let refreshTask = Task { await model.refresh() }
    await poll.waitUntilStarted()

    await model.stop()

    #expect(await poll.observedCancellation)
    #expect(await poll.cancelRequests == 1)
    #expect(!model.isRefreshing)
    await poll.release()
    await refreshTask.value
}

@Test @MainActor
func stopCancelsStartupBeforeItCanPollOrInstallTheTimer() async {
    let source = CycleSource([cycle(snapshots: [:], health: [:])])
    let notifications = CancellationAwareAuthorizationNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10222],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )
    let startTask = Task { await model.start() }
    await notifications.waitUntilStarted()

    await model.stop()
    await startTask.value

    #expect(await notifications.observedCancellation)
    #expect(await source.calls == 0)
    #expect(await sleeper.requestedDurations.isEmpty)
    #expect(!model.isRefreshing)
}

@Test @MainActor
func emptyConfigurationGuidanceRequiresRestart() {
    #expect(AppModel.emptyConfigurationGuidance == "修复配置后重启应用。")
}

@Test
func gpuDisplayIncludesOccupancyMetricsMemoryTemperatureAndFirstProcess() {
    let free = GPUDisplayText(gpu: gpu(index: 0, busy: false))
    #expect(free.occupancy == "空闲")
    #expect(free.metrics == "0% · 128 MiB / 24 GiB · 34°C")
    #expect(free.process == nil)

    let busy = GPUDisplayText(gpu: gpu(index: 1, busy: true))
    #expect(busy.occupancy == "占用")
    #expect(busy.metrics == "87% · 12 GiB / 24 GiB · 70°C")
    #expect(busy.process == "python · PID 12345")
}

@Test
func serverDisplayDistinguishesUnknownOnlineShortFailureAndOffline() {
    #expect(ServerHealthDisplay(.unknown).label == "未知")
    #expect(ServerHealthDisplay(.online).label == "在线")
    #expect(ServerHealthDisplay(.degraded(message: "SSH connection timed out", consecutiveFailures: 2)).label == "查询失败（2/3）")
    #expect(ServerHealthDisplay(.degraded(message: "SSH connection timed out", consecutiveFailures: 2)).detail == "SSH connection timed out")
    #expect(ServerHealthDisplay(.offline(message: "Host unreachable")).label == "离线")
    #expect(ServerHealthDisplay(.offline(message: "Host unreachable")).detail == "Host unreachable")
}
