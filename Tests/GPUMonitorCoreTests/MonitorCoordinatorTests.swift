import Foundation
import Testing
@_spi(Testing) import GPUMonitorCore

extension ControlledProbe: GPUProbing {
    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        try await ContinuousClock().sleep(for: delay)
        return try results[server.id, default: .failure(ProbeFailure.connectivity)].get()
    }
}

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

private actor HandoffProbe: GPUProbing {
    private var sampleStartedWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var sampleReleases: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var sampleCount = 0

    func sample(server: ServerConfig) async -> ServerSnapshot {
        sampleCount += 1
        let generation = sampleCount
        sampleStartedWaiters.removeValue(forKey: generation)?.resume(returning: true)
        if generation <= 2 {
            await withCheckedContinuation { sampleReleases[generation] = $0 }
        }
        return .snapshot(.free, server: server)
    }

    func waitUntilSampleStarts(_ generation: Int) async -> Bool {
        guard sampleCount < generation else { return true }
        return await withCheckedContinuation { sampleStartedWaiters[generation] = $0 }
    }

    func releaseSample(_ generation: Int) {
        sampleReleases.removeValue(forKey: generation)?.resume()
    }

    func releaseAllAndExpireWaiters() {
        let releases = sampleReleases.values
        let waiters = sampleStartedWaiters.values
        sampleReleases.removeAll()
        sampleStartedWaiters.removeAll()
        for release in releases {
            release.resume()
        }
        for waiter in waiters {
            waiter.resume(returning: false)
        }
    }
}

private actor OneShotSignal {
    private var waiter: CheckedContinuation<Void, Never>?
    private var signalled = false

    func signal() {
        signalled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    var hasSignalled: Bool { signalled }
}

private actor BooleanObservation {
    private var value: Bool?

    func record(_ newValue: Bool) {
        precondition(value == nil)
        value = newValue
    }

    var recordedValue: Bool? { value }
}

private actor CancellationCleanupGate {
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

private actor PollCallerHarness {
    private var callStarted = false
    private var callCompleted = false
    private var callStartedWaiter: CheckedContinuation<Void, Never>?

    func call(_ coordinator: MonitorCoordinator) async -> MonitorCycle {
        callStarted = true
        callStartedWaiter?.resume()
        callStartedWaiter = nil
        let cycle = await coordinator.poll()
        callCompleted = true
        return cycle
    }

    func waitUntilCallIsSuspended() async -> Bool {
        if !callStarted {
            await withCheckedContinuation { callStartedWaiter = $0 }
        }
        return !callCompleted
    }
}

private actor WaiterCallerHarness {
    private var firstCallStarted = false
    private var firstCallCompleted = false
    private var firstCallStartedWaiter: CheckedContinuation<Void, Never>?

    func callTwice(
        _ coordinator: MonitorCoordinator,
        creatorReturned: OneShotSignal,
        creatorStateAtSecondPoll: BooleanObservation,
        secondPollStarted: OneShotSignal
    ) async -> MonitorCycle {
        firstCallStarted = true
        firstCallStartedWaiter?.resume()
        firstCallStartedWaiter = nil
        _ = await coordinator.poll()
        firstCallCompleted = true
        await creatorStateAtSecondPoll.record(await creatorReturned.hasSignalled)
        await secondPollStarted.signal()
        return await coordinator.poll()
    }

    func waitUntilFirstCallIsSuspended() async -> Bool {
        if !firstCallStarted {
            await withCheckedContinuation { firstCallStartedWaiter = $0 }
        }
        return !firstCallCompleted
    }
}

private actor CountingProbe: GPUProbing {
    private(set) var sampleCount = 0

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        sampleCount += 1
        try await ContinuousClock().sleep(for: .milliseconds(100))
        return .snapshot(.free, server: server)
    }
}

private actor SequencedProbe: GPUProbing {
    private var sampleCounts: [String: Int] = [:]

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        sampleCounts[server.id, default: 0] += 1
        let sampleCount = sampleCounts[server.id, default: 0]
        let delay: Duration = server.id == ServerConfig.server10122.id
            ? .milliseconds(80)
            : .milliseconds(5)
        try await ContinuousClock().sleep(for: delay)
        return .snapshot(sampleCount == 1 ? .free : .busy, server: server)
    }
}

private actor FlakyProbe: GPUProbing {
    private var sampleCount = 0

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        sampleCount += 1
        guard sampleCount == 1 else { throw ProbeFailure.connectivity }
        return .snapshot(.free, server: server)
    }
}

private actor CancellationGateProbe: GPUProbing {
    private var startedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releases: [Int: CheckedContinuation<ServerSnapshot, Error>] = [:]
    private(set) var sampleCount = 0
    private(set) var cancelledGenerations: [Int] = []

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        sampleCount += 1
        let generation = sampleCount
        startedWaiters.removeValue(forKey: generation)?.resume()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { releases[generation] = $0 }
        } onCancel: {
            Task { await self.cancel(generation) }
        }
    }

    func waitUntilStarted(_ generation: Int) async {
        guard sampleCount < generation else { return }
        await withCheckedContinuation { startedWaiters[generation] = $0 }
    }

    func release(_ generation: Int, server: ServerConfig = .server10122) {
        releases.removeValue(forKey: generation)?.resume(returning: .snapshot(.free, server: server))
    }

    func cancel(_ generation: Int) {
        cancelledGenerations.append(generation)
        releases.removeValue(forKey: generation)?.resume(throwing: CancellationError())
    }

    func releaseAllAndExpireWaiters(server: ServerConfig = .server10122) {
        let pendingReleases = releases.values
        let pendingWaiters = startedWaiters.values
        releases.removeAll()
        startedWaiters.removeAll()
        for release in pendingReleases {
            release.resume(returning: .snapshot(.free, server: server))
        }
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private actor CancellationThenFailureProbe: GPUProbing {
    private var firstStartedWaiter: CheckedContinuation<Void, Never>?
    private var firstContinuation: CheckedContinuation<ServerSnapshot, Error>?
    private(set) var sampleCount = 0

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        sampleCount += 1
        guard sampleCount == 1 else { throw ProbeFailure.connectivity }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
                firstStartedWaiter?.resume()
                firstStartedWaiter = nil
            }
        } onCancel: {
            Task { await self.releaseCancellation() }
        }
    }

    func waitUntilFirstStarts() async {
        guard sampleCount == 0 else { return }
        await withCheckedContinuation { firstStartedWaiter = $0 }
    }

    func releaseCancellation() {
        firstContinuation?.resume(throwing: CancellationError())
        firstContinuation = nil
    }
}

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

@Test func overlappingPollsShareTheActiveCycle() async {
    let probe = CountingProbe()
    let coordinator = MonitorCoordinator(servers: [.server10122], probe: probe)

    async let first = coordinator.poll()
    async let second = coordinator.poll()
    let cycles = await (first, second)

    #expect(await probe.sampleCount == 1)
    #expect(cycles.0.completedAt == cycles.1.completedAt)
    #expect(cycles.0.snapshots == cycles.1.snapshots)
}

@Test func pollCancelledBeforeCoordinatorEntryDoesNotStartAProbe() async {
    let probe = CountingProbe()
    let coordinator = MonitorCoordinator(servers: [.server10122], probe: probe)
    let entryGate = CancellationCleanupGate()
    let poll = Task {
        await entryGate.pause()
        return await coordinator.poll()
    }
    await entryGate.waitUntilEntered()

    poll.cancel()
    await entryGate.release()
    let cycle = await poll.value

    #expect(await probe.sampleCount == 0)
    #expect(cycle.snapshots.isEmpty)
    #expect(cycle.health.isEmpty)
    #expect(cycle.events.isEmpty)
}

@Test func cancellingActivePollWaitsForProbeAndDoesNotClearANewerGeneration() async {
    let probe = CancellationGateProbe()
    let cleanupGate = CancellationCleanupGate()
    let coordinator = MonitorCoordinator(
        servers: [.server10122],
        probe: probe,
        beforeCancellationCleanup: { await cleanupGate.pause() }
    )
    let cancelReturned = OneShotSignal()
    let secondPollStarted = OneShotSignal()
    let cancelStateAtSecondPoll = BooleanObservation()
    let waiterCaller = WaiterCallerHarness()
    let joinerCaller = PollCallerHarness()
    let deadlockGuard = Task {
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        await probe.releaseAllAndExpireWaiters()
        await secondPollStarted.signal()
        await cancelReturned.signal()
    }
    let waiter = Task {
        await waiterCaller.callTwice(
            coordinator,
            creatorReturned: cancelReturned,
            creatorStateAtSecondPoll: cancelStateAtSecondPoll,
            secondPollStarted: secondPollStarted
        )
    }
    #expect(await waiterCaller.waitUntilFirstCallIsSuspended())
    await probe.waitUntilStarted(1)

    let cancellation = Task {
        await coordinator.cancelActivePoll()
        await cancelReturned.signal()
    }
    await cleanupGate.waitUntilEntered()
    await secondPollStarted.wait()
    #expect(await cancelStateAtSecondPoll.recordedValue == false)
    await probe.waitUntilStarted(2)
    #expect(await probe.cancelledGenerations == [1])

    await cleanupGate.release()
    await cancelReturned.wait()
    #expect(await probe.sampleCount == 2)

    let joiner = Task { await joinerCaller.call(coordinator) }
    #expect(await joinerCaller.waitUntilCallIsSuspended())
    #expect(await probe.sampleCount == 2)
    await probe.release(2)

    _ = await waiter.value
    _ = await joiner.value
    await cancellation.value
    #expect(await probe.sampleCount == 2)
    deadlockGuard.cancel()
    await deadlockGuard.value
}

@Test func cancelledProbeDoesNotIncrementServerFailureState() async {
    let probe = CancellationThenFailureProbe()
    let coordinator = MonitorCoordinator(servers: [.server10122], probe: probe)
    let cancelledPoll = Task { await coordinator.poll() }
    await probe.waitUntilFirstStarts()

    await coordinator.cancelActivePoll()
    _ = await cancelledPoll.value
    let failedCycle = await coordinator.poll()

    #expect(await probe.sampleCount == 2)
    #expect(failedCycle.health[ServerConfig.server10122.id] == .degraded(
        message: ProbeFailure.connectivity.localizedDescription,
        consecutiveFailures: 1
    ))
}

@Test func waiterReturningFirstClearsTheCompletedPollBeforeStartingAnother() async {
    let probe = HandoffProbe()
    let coordinator = MonitorCoordinator(servers: [.server10122], probe: probe)
    let creatorCleanupGate = CancellationCleanupGate()
    let creatorReturned = OneShotSignal()
    let waiterStartedSecondPoll = OneShotSignal()
    let creatorStateAtSecondPoll = BooleanObservation()
    let waiterCaller = WaiterCallerHarness()
    let joinerCaller = PollCallerHarness()
    let deadlockGuard = Task {
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        await probe.releaseAllAndExpireWaiters()
        await creatorCleanupGate.release()
    }
    let creator = Task {
        let cycle = await coordinator.poll(beforeCleanup: { await creatorCleanupGate.pause() })
        await creatorReturned.signal()
        return cycle
    }
    #expect(await probe.waitUntilSampleStarts(1))

    let waiter = Task {
        await waiterCaller.callTwice(
            coordinator,
            creatorReturned: creatorReturned,
            creatorStateAtSecondPoll: creatorStateAtSecondPoll,
            secondPollStarted: waiterStartedSecondPoll
        )
    }
    #expect(await waiterCaller.waitUntilFirstCallIsSuspended())
    await probe.releaseSample(1)
    await creatorCleanupGate.waitUntilEntered()
    await waiterStartedSecondPoll.wait()
    #expect(await creatorStateAtSecondPoll.recordedValue == false)
    guard await probe.waitUntilSampleStarts(2) else {
        Issue.record("The waiter did not start a second poll")
        _ = await waiter.value
        _ = await creator.value
        deadlockGuard.cancel()
        await deadlockGuard.value
        return
    }
    await creatorCleanupGate.release()
    await creatorReturned.wait()

    let joiner = Task {
        await joinerCaller.call(coordinator)
    }
    #expect(await joinerCaller.waitUntilCallIsSuspended())
    #expect(await probe.sampleCount == 2)
    await probe.releaseSample(2)

    _ = await joiner.value
    _ = await waiter.value
    _ = await creator.value
    #expect(await probe.sampleCount == 2)
    deadlockGuard.cancel()
    await deadlockGuard.value
}

@Test func eventsFollowConfiguredServerOrderRatherThanCompletionOrder() async {
    let probe = SequencedProbe()
    let tracker = StateTracker(confirmationCount: 1, offlineFailureCount: 3)
    let coordinator = MonitorCoordinator(
        servers: [.server10122, .server10165],
        probe: probe,
        tracker: tracker
    )
    _ = await coordinator.poll()

    let cycle = await coordinator.poll()

    #expect(cycle.events == [
        .gpuChanged(
            server: .server10122,
            gpu: .gpu(index: 0, .busy),
            from: .free,
            to: .busy
        ),
        .gpuChanged(
            server: .server10165,
            gpu: .gpu(index: 0, .busy),
            from: .free,
            to: .busy
        ),
    ])
}

@Test func failedPollRetainsTheLastSuccessfulSnapshot() async {
    let coordinator = MonitorCoordinator(servers: [.server10122], probe: FlakyProbe())
    let successfulCycle = await coordinator.poll()

    let failedCycle = await coordinator.poll()

    #expect(failedCycle.snapshots["server-10122"] == successfulCycle.snapshots["server-10122"])
    #expect(failedCycle.health["server-10122"] == .degraded(
        message: ProbeFailure.connectivity.localizedDescription,
        consecutiveFailures: 1
    ))
    #expect(failedCycle.events.isEmpty)
}

@Test func coordinatorPreservesStructuredNonConnectivityFailureHealth() async {
    let authenticationProbe = ControlledProbe(
        results: ["server-10122": .failure(ProbeFailure.authentication)],
        delay: .zero
    )
    let securityProbe = ControlledProbe(
        results: ["server-10122": .failure(ProbeFailure.hostKeySecurity)],
        delay: .zero
    )
    let authenticationCoordinator = MonitorCoordinator(servers: [.server10122], probe: authenticationProbe)
    let securityCoordinator = MonitorCoordinator(servers: [.server10122], probe: securityProbe)

    let authentication = await authenticationCoordinator.poll()
    let security = await securityCoordinator.poll()

    #expect(authentication.health["server-10122"] == .warning(
        message: ProbeFailure.authentication.localizedDescription
    ))
    #expect(security.health["server-10122"] == .security(
        message: ProbeFailure.hostKeySecurity.localizedDescription
    ))
    #expect(authentication.events.isEmpty)
    #expect(security.events.isEmpty)
}
