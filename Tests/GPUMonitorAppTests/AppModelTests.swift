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
        deliveryResult: NotificationDeliveryResult = try! .init(
            attemptedCount: 0,
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

private actor MutableAuthorizationProvider: NotificationAuthorizationProviding {
    private var state: NotificationAuthorizationState
    private(set) var stateReads = 0

    init(state: NotificationAuthorizationState) {
        self.state = state
    }

    func requestAuthorization() async -> NotificationAuthorizationState { state }

    func authorizationState() async -> NotificationAuthorizationState {
        stateReads += 1
        return state
    }

    func setState(_ newState: NotificationAuthorizationState) {
        state = newState
    }
}

private actor ControlledAuthorizationStateProvider: NotificationAuthorizationProviding {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var stateContinuation: CheckedContinuation<NotificationAuthorizationState, Never>?
    private var started = false
    private(set) var stateReads = 0

    func requestAuthorization() async -> NotificationAuthorizationState { .notDetermined }

    func authorizationState() async -> NotificationAuthorizationState {
        stateReads += 1
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        return await withCheckedContinuation { stateContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release(_ state: NotificationAuthorizationState) {
        stateContinuation?.resume(returning: state)
        stateContinuation = nil
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
        return cycle(snapshots: [:], health: [server10122.id: .unknown])
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
        try! .init(attemptedCount: 0, failures: [])
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
        try! .init(attemptedCount: 0, failures: [])
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

private actor NonCooperativeAuthorizationNotifications: NotificationSink, NotificationAuthorizationProviding {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var authorizationContinuation: CheckedContinuation<NotificationAuthorizationState, Never>?
    private var started = false

    func requestAuthorization() async -> NotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func authorizationState() async -> NotificationAuthorizationState { .notDetermined }

    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        try! .init(attemptedCount: 0, failures: [])
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        authorizationContinuation?.resume(returning: .authorized)
        authorizationContinuation = nil
    }
}

private actor NonCooperativeDeliveryNotifications: NotificationSink, NotificationAuthorizationProviding {
    private var deliveryStartedWaiter: CheckedContinuation<Void, Never>?
    private var deliveryContinuation: CheckedContinuation<NotificationDeliveryResult, Never>?
    private var deliveryStarted = false

    func requestAuthorization() async -> NotificationAuthorizationState { .authorized }

    func authorizationState() async -> NotificationAuthorizationState { .authorized }

    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        deliveryStarted = true
        deliveryStartedWaiter?.resume()
        deliveryStartedWaiter = nil
        return await withCheckedContinuation { deliveryContinuation = $0 }
    }

    func waitUntilDeliveryStarts() async {
        guard !deliveryStarted else { return }
        await withCheckedContinuation { deliveryStartedWaiter = $0 }
    }

    func release() {
        deliveryContinuation?.resume(returning: try! .init(
            attemptedCount: 0,
            failures: []
        ))
        deliveryContinuation = nil
    }
}

private actor CompletionFlag {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}

private actor ControlledNotificationDrain {
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func drain() async {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ShutdownGatePoll {
    private var pollStartedWaiter: CheckedContinuation<Void, Never>?
    private var pollContinuation: CheckedContinuation<MonitorCycle, Never>?
    private var cancellationStartedWaiter: CheckedContinuation<Void, Never>?
    private var cancellationReleases: [CheckedContinuation<Void, Never>] = []
    private(set) var pollCalls = 0
    private(set) var cancellationRequests = 0

    func poll() async -> MonitorCycle {
        pollCalls += 1
        pollStartedWaiter?.resume()
        pollStartedWaiter = nil
        return await withCheckedContinuation { pollContinuation = $0 }
    }

    func cancelActivePoll() async {
        cancellationRequests += 1
        cancellationStartedWaiter?.resume()
        cancellationStartedWaiter = nil
        await withCheckedContinuation { cancellationReleases.append($0) }
        pollContinuation?.resume(returning: cycle(snapshots: [:], health: [:]))
        pollContinuation = nil
    }

    func waitUntilPollStarts() async {
        guard pollCalls == 0 else { return }
        await withCheckedContinuation { pollStartedWaiter = $0 }
    }

    func waitUntilCancellationStarts() async {
        guard cancellationRequests == 0 else { return }
        await withCheckedContinuation { cancellationStartedWaiter = $0 }
    }

    func releaseCancellation() {
        let releases = cancellationReleases
        cancellationReleases.removeAll()
        releases.forEach { $0.resume() }
    }
}

private actor PreRegistrationPollGate {
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func pause() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AppCountingProbe: GPUProbing {
    private(set) var sampleCount = 0

    func sample(server: ServerConfig) async -> ServerSnapshot {
        sampleCount += 1
        return snapshot(server: server, gpus: [gpu(index: 0, busy: false)])
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

private let server10122 = ServerConfig(
    id: "server-10122",
    label: "10122",
    host: "example.invalid",
    port: 10122,
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

private let serverA10018200 = ServerConfig(
    id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200,
    username: "tester", identityFile: "/tmp/test-key"
)
private let serverA10013000 = ServerConfig(
    id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000,
    username: "tester", identityFile: "/tmp/test-key"
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
func refreshReReadsNotificationAuthorizationAfterSettingsChange() async {
    let notifications = FakeNotifications()
    let authorization = MutableAuthorizationProvider(state: .authorized)
    let model = AppModel(
        servers: [server10122],
        poll: { cycle(snapshots: [:], health: [server10122.id: .online]) },
        notifications: notifications,
        authorizationProvider: authorization,
        sleep: { _ in throw CancellationError() }
    )

    await model.refresh()
    #expect(model.notificationAuthorization == .authorized)

    await authorization.setState(.denied)
    await model.refresh()

    #expect(model.notificationAuthorization == .denied)
    #expect(await authorization.stateReads == 2)
    await model.stop()
}

@Test @MainActor
func overlappingAuthorizationRefreshesShareOneProviderRead() async {
    let notifications = FakeNotifications()
    let authorization = ControlledAuthorizationStateProvider()
    let model = AppModel(
        servers: [server10122],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: authorization,
        sleep: { _ in throw CancellationError() }
    )

    let first = Task { await model.refreshNotificationAuthorization() }
    await authorization.waitUntilStarted()
    let second = Task { await model.refreshNotificationAuthorization() }
    for _ in 0..<100 { await Task.yield() }

    #expect(await authorization.stateReads == 1)
    await authorization.release(.provisional)
    await first.value
    await second.value
    #expect(model.notificationAuthorization == .provisional)
    await model.stop()
}

@Test @MainActor
func stoppedModelDiscardsLateAuthorizationState() async {
    let notifications = FakeNotifications()
    let authorization = ControlledAuthorizationStateProvider()
    let model = AppModel(
        servers: [server10122],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: authorization,
        sleep: { _ in throw CancellationError() }
    )
    let refresh = Task { await model.refreshNotificationAuthorization() }
    await authorization.waitUntilStarted()

    await model.stop()
    await authorization.release(.denied)
    await refresh.value

    #expect(model.notificationAuthorization == .notDetermined)
}

@Test @MainActor
func stopDoesNotWaitForNonCooperativeAuthorizationStateRead() async {
    let notifications = FakeNotifications()
    let authorization = ControlledAuthorizationStateProvider()
    let model = AppModel(
        servers: [server10122],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: authorization,
        sleep: { _ in throw CancellationError() }
    )
    let refresh = Task { await model.refreshNotificationAuthorization() }
    await authorization.waitUntilStarted()
    let stopFinished = CompletionFlag()
    let stop = Task {
        await model.stop()
        await stopFinished.markCompleted()
    }

    for _ in 0..<200 where !(await stopFinished.completed) {
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    #expect(await stopFinished.completed)

    await authorization.release(.authorized)
    await stop.value
    await refresh.value
    #expect(model.notificationAuthorization == .notDetermined)
}

@Test @MainActor
func startRequestsAuthorizationAndPollsExactlyOnceAcrossRepeatedCalls() async {
    let firstCycle = cycle(
        snapshots: [server10122.id: snapshot(server: server10122, gpus: [gpu(index: 0, busy: false)])],
        health: [server10122.id: .online]
    )
    let source = CycleSource([firstCycle])
    let notifications = FakeNotifications(requestedState: .denied)
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10122],
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
        servers: [server10122],
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
    let firstCycle = cycle(snapshots: [:], health: [server10122.id: .unknown])
    let source = CycleSource([firstCycle])
    let notifications = FakeNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10122],
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
    let previous = snapshot(server: server10122, gpus: [gpu(index: 0, busy: false)])
    let updated = snapshot(server: server10165, gpus: [gpu(index: 1, busy: true)])
    let event = MonitorEvent.serverOffline(server: server10122, message: "timed out")
    let source = CycleSource([
        cycle(snapshots: [server10122.id: previous], health: [server10122.id: .online]),
        cycle(
            snapshots: [server10165.id: updated],
            health: [server10122.id: .degraded(message: "timed out", consecutiveFailures: 1), server10165.id: .online],
            events: [event]
        ),
    ])
    let notifications = FakeNotifications(deliveryResult: try! .init(
        attemptedCount: 1,
        failures: [.init(messageIndex: 0, reason: .schedulingFailed)]
    ))
    let model = AppModel(
        servers: [server10122, server10165],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    await model.refresh()
    await model.refresh()

    #expect(model.servers.map(\.id) == [server10122.id, server10165.id])
    #expect(model.snapshots[server10122.id] == previous)
    #expect(model.snapshots[server10165.id] == updated)
    #expect(model.recentErrorSummary == "通知发送失败：1 条")
    #expect(await notifications.sentEvents.last == [event])
}

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

@Test @MainActor
func summaryAndColorRepresentUnknownWarningOfflineFreeAndBusyStates() async {
    let notifications = FakeNotifications()
    let model = AppModel(
        servers: [server10122, server10165],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    #expect(model.menuTitle == "GPU —/—")
    #expect(model.menuStatus == .unknown)

    model.applyForTesting(cycle(
        snapshots: [
            server10122.id: snapshot(server: server10122, gpus: [gpu(index: 0, busy: false)]),
            server10165.id: snapshot(server: server10165, gpus: [gpu(index: 1, busy: true)]),
        ],
        health: [server10122.id: .online, server10165.id: .online]
    ))
    #expect(model.menuTitle == "GPU 1/2 空闲")
    #expect(model.menuStatus == .available)

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .online, server10165.id: .unknown]
    ))
    #expect(model.menuStatus == .unknown)

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .degraded(message: "timeout", consecutiveFailures: 1), server10165.id: .online]
    ))
    #expect(model.menuStatus == .warning)
    #expect(model.recentErrorSummary == "服务器 10122：timeout")

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .warning(message: "authentication failed"), server10165.id: .online]
    ))
    #expect(model.menuStatus == .warning)
    #expect(model.recentErrorSummary == "服务器 10122：authentication failed")

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .security(message: "host key mismatch"), server10165.id: .online]
    ))
    #expect(model.menuStatus == .security)
    #expect(model.recentErrorSummary == "服务器 10122：host key mismatch")

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .offline(message: "unreachable"), server10165.id: .online]
    ))
    #expect(model.menuStatus == .offline)
}

@Test @MainActor
func healthyCycleClearsPreviouslyDisplayedServerWarning() async {
    let notifications = FakeNotifications()
    let model = AppModel(
        servers: [server10122, server10165],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [
            server10122.id: .warning(message: "timeout"),
            server10165.id: .online,
        ]
    ))
    #expect(model.recentErrorSummary == "服务器 10122：timeout")

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .online, server10165.id: .online]
    ))

    #expect(model.recentErrorSummary == nil)
}

@Test @MainActor
func healthyCyclePreservesNotificationAuthorizationErrorThatReplacedServerWarning() async {
    let notifications = FakeNotifications()
    let authorization = MutableAuthorizationProvider(state: .error)
    let model = AppModel(
        servers: [server10122, server10165],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: authorization,
        sleep: { _ in throw CancellationError() }
    )

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [
            server10122.id: .warning(message: "timeout"),
            server10165.id: .online,
        ]
    ))
    await model.refreshNotificationAuthorization()
    #expect(model.recentErrorSummary == "通知授权状态读取失败")

    model.applyForTesting(cycle(
        snapshots: [:],
        health: [server10122.id: .online, server10165.id: .online]
    ))

    #expect(model.recentErrorSummary == "通知授权状态读取失败")
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
        servers: [server10122],
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
func stopWaitsForInjectedProductionNotificationDrain() async {
    let notifications = FakeNotifications()
    let drain = ControlledNotificationDrain()
    let model = AppModel(
        servers: [server10122],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: notifications,
        notificationDrain: { await drain.drain() },
        notificationDrainTimeout: .seconds(5),
        sleep: { _ in throw CancellationError() }
    )
    let stopped = CompletionFlag()
    let stopTask = Task {
        await model.stop()
        await stopped.markCompleted()
    }

    await drain.waitUntilStarted()
    for _ in 0..<100 { await Task.yield() }
    #expect(!(await stopped.completed))

    await drain.release()
    await stopTask.value
    #expect(await stopped.completed)
}

@Test @MainActor
func stopBoundsANonCooperativeNotificationDrain() async {
    let notifications = FakeNotifications()
    let drain = ControlledNotificationDrain()
    let model = AppModel(
        servers: [server10122],
        poll: { cycle(snapshots: [:], health: [:]) },
        notifications: notifications,
        authorizationProvider: notifications,
        notificationDrain: { await drain.drain() },
        notificationDrainTimeout: .milliseconds(10),
        sleep: { _ in throw CancellationError() }
    )
    let stopped = CompletionFlag()
    let stopTask = Task {
        await model.stop()
        await stopped.markCompleted()
    }

    await drain.waitUntilStarted()
    for _ in 0..<500 where !(await stopped.completed) {
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    #expect(await stopped.completed)

    await drain.release()
    await stopTask.value
}

@Test @MainActor
func stopCancelsStartupBeforeItCanPollOrInstallTheTimer() async {
    let source = CycleSource([cycle(snapshots: [:], health: [:])])
    let notifications = CancellationAwareAuthorizationNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10122],
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
func stopIsTerminalAndSharesShutdownAcrossReentrantLifecycleCalls() async {
    let poll = ShutdownGatePoll()
    let notifications = FakeNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10122],
        poll: { await poll.poll() },
        cancelPoll: { await poll.cancelActivePoll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )
    let refreshTask = Task { await model.refresh() }
    await poll.waitUntilPollStarts()
    let firstStopFinished = CompletionFlag()
    let firstStop = Task {
        await model.stop()
        await firstStopFinished.markCompleted()
    }
    await poll.waitUntilCancellationStarts()

    let reentrantStartFinished = CompletionFlag()
    let reentrantStart = Task {
        await model.start()
        await reentrantStartFinished.markCompleted()
    }
    let reentrantRefreshFinished = CompletionFlag()
    let reentrantRefresh = Task {
        await model.refresh()
        await reentrantRefreshFinished.markCompleted()
    }
    let secondStopFinished = CompletionFlag()
    let secondStop = Task {
        await model.stop()
        await secondStopFinished.markCompleted()
    }
    for _ in 0..<100 { await Task.yield() }

    #expect(await reentrantStartFinished.completed)
    #expect(await reentrantRefreshFinished.completed)
    #expect(!(await firstStopFinished.completed))
    #expect(!(await secondStopFinished.completed))
    #expect(await poll.pollCalls == 1)
    #expect(await poll.cancellationRequests == 1)

    await poll.releaseCancellation()
    await firstStop.value
    await secondStop.value
    await refreshTask.value
    await reentrantStart.value
    await reentrantRefresh.value
    #expect(await sleeper.requestedDurations.isEmpty)
}

@Test @MainActor
func completedStopPermanentlyRejectsStartAndRefresh() async {
    let source = CycleSource([cycle(snapshots: [:], health: [:])])
    let notifications = FakeNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10122],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )

    await model.stop()
    await model.start()
    await model.refresh()

    #expect(await source.calls == 0)
    #expect(await sleeper.requestedDurations.isEmpty)
    await model.stop()
}

@Test @MainActor
func stopDoesNotWaitForNonCooperativeAuthorization() async {
    let source = CycleSource([cycle(snapshots: [:], health: [:])])
    let notifications = NonCooperativeAuthorizationNotifications()
    let sleeper = ControlledSleeper()
    let model = AppModel(
        servers: [server10122],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { try await sleeper.sleep(for: $0) }
    )
    let startTask = Task { await model.start() }
    await notifications.waitUntilStarted()
    let stopFinished = CompletionFlag()
    let stopTask = Task {
        await model.stop()
        await stopFinished.markCompleted()
    }

    for _ in 0..<200 where !(await stopFinished.completed) {
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    #expect(await stopFinished.completed)
    #expect(await source.calls == 0)
    #expect(await sleeper.requestedDurations.isEmpty)

    await notifications.release()
    await stopTask.value
    await startTask.value
    #expect(await source.calls == 0)
    #expect(await sleeper.requestedDurations.isEmpty)
}

@Test @MainActor
func stopDoesNotWaitForNonCooperativeNotificationDeliveryOrApplyItsLateResult() async {
    let completedCycle = cycle(
        snapshots: [server10122.id: snapshot(server: server10122, gpus: [gpu(index: 0, busy: false)])],
        health: [server10122.id: .online]
    )
    let source = CycleSource([completedCycle])
    let notifications = NonCooperativeDeliveryNotifications()
    let model = AppModel(
        servers: [server10122],
        poll: { await source.poll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )
    let refreshTask = Task { await model.refresh() }
    await notifications.waitUntilDeliveryStarts()
    let stopFinished = CompletionFlag()
    let stopTask = Task {
        await model.stop()
        await stopFinished.markCompleted()
    }

    for _ in 0..<200 where !(await stopFinished.completed) {
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    #expect(await stopFinished.completed)
    #expect(await source.calls == 1)
    #expect(model.snapshots.isEmpty)

    await model.start()
    await model.refresh()
    #expect(await source.calls == 1)

    await notifications.release()
    await stopTask.value
    await refreshTask.value
    #expect(model.snapshots.isEmpty)
}

@Test @MainActor
func stopBeforeCoordinatorRegistrationPreventsTheCancelledRefreshFromStartingAProbe() async {
    let gate = PreRegistrationPollGate()
    let probe = AppCountingProbe()
    let coordinator = MonitorCoordinator(servers: [server10122], probe: probe)
    let notifications = FakeNotifications()
    let model = AppModel(
        servers: [server10122],
        poll: {
            await gate.pause()
            return await coordinator.poll()
        },
        cancelPoll: { await coordinator.cancelActivePoll() },
        notifications: notifications,
        authorizationProvider: notifications,
        sleep: { _ in throw CancellationError() }
    )
    let refresh = Task { await model.refresh() }
    await gate.waitUntilEntered()

    await model.stop()
    #expect(await probe.sampleCount == 0)
    await gate.release()
    await refresh.value

    #expect(await probe.sampleCount == 0)
    #expect(model.snapshots.isEmpty)
    #expect(model.health.isEmpty)
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
func serverDisplayDistinguishesUnknownOnlineConnectivityWarningSecurityAndOffline() {
    #expect(ServerHealthDisplay(.unknown).label == "未知")
    #expect(ServerHealthDisplay(.online).label == "在线")
    #expect(ServerHealthDisplay(.degraded(message: "SSH connection timed out", consecutiveFailures: 2)).label == "查询失败（2/3）")
    #expect(ServerHealthDisplay(.degraded(message: "SSH connection timed out", consecutiveFailures: 2)).detail == "SSH connection timed out")
    #expect(ServerHealthDisplay(.warning(message: "Public-key authentication failed")).label == "查询警告")
    #expect(ServerHealthDisplay(.warning(message: "Public-key authentication failed")).detail == "Public-key authentication failed")
    #expect(ServerHealthDisplay(.security(message: "Host key verification failed")).label == "安全错误")
    #expect(ServerHealthDisplay(.security(message: "Host key verification failed")).detail == "Host key verification failed")
    #expect(ServerHealthDisplay(.offline(message: "Host unreachable")).label == "离线")
    #expect(ServerHealthDisplay(.offline(message: "Host unreachable")).detail == "Host unreachable")
}
