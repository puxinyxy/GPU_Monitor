import Foundation
import Testing
import GPUMonitorCore

extension ControlledProbe: GPUProbing {
    func sample(server: ServerConfig) async throws -> ServerSnapshot {
        try await ContinuousClock().sleep(for: delay)
        return try results[server.id, default: .failure(TestError.unreachable)].get()
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
    let probe = ControlledProbe(results: [
        "server-10222": .success(.snapshot(.free, server: .server10222)),
        "server-10165": .failure(TestError.unreachable),
    ], delay: .milliseconds(150))
    let coordinator = MonitorCoordinator(servers: [.server10222, .server10165], probe: probe)
    let clock = ContinuousClock()

    let startedAt = clock.now
    let cycle = await coordinator.poll()
    let elapsed = startedAt.duration(to: clock.now)

    #expect(elapsed < .milliseconds(280))
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
