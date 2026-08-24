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
    private var firstSampleStartedWaiter: CheckedContinuation<Void, Never>?
    private var firstSampleRelease: CheckedContinuation<Void, Never>?
    private var firstSampleHasStarted = false
    private(set) var sampleCount = 0

    func sample(server: ServerConfig) async -> ServerSnapshot {
        sampleCount += 1
        if sampleCount == 1 {
            firstSampleHasStarted = true
            firstSampleStartedWaiter?.resume()
            firstSampleStartedWaiter = nil
            await withCheckedContinuation { firstSampleRelease = $0 }
        }
        return .snapshot(.free, server: server)
    }

    func waitUntilFirstSampleStarts() async {
        guard !firstSampleHasStarted else { return }
        await withCheckedContinuation { firstSampleStartedWaiter = $0 }
    }

    func releaseFirstSample() {
        firstSampleRelease?.resume()
        firstSampleRelease = nil
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

@Test func waiterReturningFirstClearsTheCompletedPollBeforeStartingAnother() async {
    let probe = HandoffProbe()
    let coordinator = MonitorCoordinator(servers: [.server10222], probe: probe)
    let waiterStarted = OneShotSignal()
    let creator = Task.detached(priority: .background) {
        await coordinator.poll()
    }
    await probe.waitUntilFirstSampleStarts()

    let waiter = Task.detached(priority: .high) {
        await waiterStarted.signal()
        _ = await coordinator.poll()
        return await coordinator.poll()
    }
    await waiterStarted.wait()
    for _ in 0..<10 {
        await Task.yield()
    }
    await probe.releaseFirstSample()

    _ = await waiter.value
    _ = await creator.value
    #expect(await probe.sampleCount == 2)
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
