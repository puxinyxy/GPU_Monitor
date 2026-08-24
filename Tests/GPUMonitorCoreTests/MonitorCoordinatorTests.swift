import Foundation
import Testing
import GPUMonitorCore

extension ControlledProbe: GPUProbing {
    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        try await ContinuousClock().sleep(for: delay)
        return try results[server.id, default: .failure(TestError.unreachable)].get()
    }
}

private actor ConcurrentBarrierProbe: GPUProbing {
    private let results: [String: Result<ServerSnapshot, Error>]
    private var blockedSample: CheckedContinuation<Void, Never>?
    private var activeSampleCount = 0
    private(set) var maximumConcurrentSampleCount = 0

    init(results: [String: Result<ServerSnapshot, Error>]) {
        self.results = results
    }

    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        activeSampleCount += 1
        maximumConcurrentSampleCount = max(maximumConcurrentSampleCount, activeSampleCount)

        if activeSampleCount == 1 {
            await withCheckedContinuation { blockedSample = $0 }
        } else {
            releaseBlockedSample()
        }

        activeSampleCount -= 1
        return try results[server.id, default: .failure(TestError.unreachable)].get()
    }

    func releaseBlockedSample() {
        blockedSample?.resume()
        blockedSample = nil
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
        let delay: Duration = server.id == ServerConfig.server10222.id
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
        guard sampleCount == 1 else { throw TestError.unreachable }
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

    func release(_ generation: Int, server: ServerConfig = .server10222) {
        releases.removeValue(forKey: generation)?.resume(returning: .snapshot(.free, server: server))
    }

    func cancel(_ generation: Int) {
        cancelledGenerations.append(generation)
        releases.removeValue(forKey: generation)?.resume(throwing: CancellationError())
    }
}

@Test func pollRunsServersConcurrentlyAndPreservesSuccessfulServer() async {
    let probe = ConcurrentBarrierProbe(results: [
        "server-10222": .success(.snapshot(.free, server: .server10222)),
        "server-10165": .failure(TestError.unreachable),
    ])
    let coordinator = MonitorCoordinator(servers: [.server10222, .server10165], probe: probe)
    let deadlockGuard = Task {
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        await probe.releaseBlockedSample()
    }

    let cycle = await coordinator.poll()
    deadlockGuard.cancel()
    await deadlockGuard.value

    #expect(await probe.maximumConcurrentSampleCount == 2)
    #expect(cycle.snapshots["server-10222"] != nil)
    #expect(cycle.health["server-10222"] == .online)
    #expect(cycle.health["server-10165"] != .online)
}

@Test func overlappingPollsShareTheActiveCycle() async {
    let probe = CountingProbe()
    let coordinator = MonitorCoordinator(servers: [.server10222], probe: probe)

    async let first = coordinator.poll()
    async let second = coordinator.poll()
    let cycles = await (first, second)

    #expect(await probe.sampleCount == 1)
    #expect(cycles.0.completedAt == cycles.1.completedAt)
    #expect(cycles.0.snapshots == cycles.1.snapshots)
}

@Test func cancellingActivePollWaitsForProbeAndDoesNotClearANewerGeneration() async {
    let probe = CancellationGateProbe()
    let coordinator = MonitorCoordinator(servers: [.server10222], probe: probe)
    let first = Task { await coordinator.poll() }
    await probe.waitUntilStarted(1)

    await coordinator.cancelActivePoll()
    _ = await first.value
    #expect(await probe.cancelledGenerations == [1])

    let second = Task { await coordinator.poll() }
    await probe.waitUntilStarted(2)
    let joiner = Task { await coordinator.poll() }
    for _ in 0..<100 { await Task.yield() }
    #expect(await probe.sampleCount == 2)
    await probe.release(2)

    _ = await second.value
    _ = await joiner.value
    #expect(await probe.sampleCount == 2)
}

@Test func waiterReturningFirstClearsTheCompletedPollBeforeStartingAnother() async {
    let probe = HandoffProbe()
    let coordinator = MonitorCoordinator(servers: [.server10222], probe: probe)
    let creatorReturned = OneShotSignal()
    let waiterStartedSecondPoll = OneShotSignal()
    let creatorStateAtSecondPoll = BooleanObservation()
    let creatorCaller = PollCallerHarness()
    let waiterCaller = WaiterCallerHarness()
    let joinerCaller = PollCallerHarness()
    let deadlockGuard = Task {
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        await probe.releaseAllAndExpireWaiters()
    }
    let creator = Task {
        let cycle = await creatorCaller.call(coordinator)
        await creatorReturned.signal()
        return cycle
    }
    #expect(await creatorCaller.waitUntilCallIsSuspended())
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
        servers: [.server10222, .server10165],
        probe: probe,
        tracker: tracker
    )
    _ = await coordinator.poll()

    let cycle = await coordinator.poll()

    #expect(cycle.events == [
        .gpuChanged(
            server: .server10222,
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
    let coordinator = MonitorCoordinator(servers: [.server10222], probe: FlakyProbe())
    let successfulCycle = await coordinator.poll()

    let failedCycle = await coordinator.poll()

    #expect(failedCycle.snapshots["server-10222"] == successfulCycle.snapshots["server-10222"])
    #expect(failedCycle.health["server-10222"] == .degraded(
        message: TestError.unreachable.localizedDescription,
        consecutiveFailures: 1
    ))
    #expect(failedCycle.events.isEmpty)
}
