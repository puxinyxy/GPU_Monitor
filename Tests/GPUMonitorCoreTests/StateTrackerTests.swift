import Testing
import GPUMonitorCore

@Test func firstSuccessEstablishesASilentBaseline() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)

    let update = await tracker.recordSuccess(.snapshot(.free))

    #expect(update.health == .online)
    #expect(update.stableSnapshot == .snapshot(.free))
    #expect(update.events.isEmpty)
}

@Test func secondMatchingObservationConfirmsGPUChange() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    let candidate = await tracker.recordSuccess(.snapshot(.busy))
    #expect(candidate.events.isEmpty)
    #expect(candidate.stableSnapshot == .snapshot(.free))

    let update = await tracker.recordSuccess(.snapshot(.busy))

    #expect(update.events == [
        .gpuChanged(server: .fixture, gpu: .gpu(index: 0, .busy), from: .free, to: .busy),
    ])
}

@Test func flappingObservationResetsGPUConfirmation() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    _ = await tracker.recordSuccess(.snapshot(.busy))
    _ = await tracker.recordSuccess(.snapshot(.free))
    #expect((await tracker.recordSuccess(.snapshot(.busy))).events.isEmpty)

    let update = await tracker.recordSuccess(.snapshot(.busy))

    #expect(update.events.count == 1)
}

@Test func singleCandidatesAndFlappingNeverLeakIntoTheConfirmedSnapshot() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    let baseline = ServerSnapshot(
        server: .fixture,
        gpus: [.gpu(index: 0, .free)],
        capturedAt: .distantPast
    )
    _ = await tracker.recordSuccess(baseline)

    let busyCandidate = GPUSnapshot(
        index: 0, uuid: "GPU-0", name: "changed", utilizationPercent: 99,
        usedMemoryMiB: 23_000, totalMemoryMiB: 24_564, temperatureCelsius: 80,
        processes: [.init(pid: 999, name: "candidate", usedMemoryMiB: 22_000)]
    )

    let firstBusy = await tracker.recordSuccess(ServerSnapshot(
        server: .fixture,
        gpus: [busyCandidate],
        capturedAt: .distantFuture
    ))
    let freeAgain = await tracker.recordSuccess(.snapshot(.free))
    let secondBusyCandidate = await tracker.recordSuccess(ServerSnapshot(
        server: .fixture,
        gpus: [busyCandidate],
        capturedAt: .distantFuture
    ))

    #expect(firstBusy.stableSnapshot == baseline)
    #expect(freeAgain.stableSnapshot?.gpus.map(\.occupancy) == [.free])
    #expect(secondBusyCandidate.stableSnapshot?.gpus.map(\.occupancy) == [.free])
    #expect(firstBusy.events.isEmpty)
    #expect(freeAgain.events.isEmpty)
    #expect(secondBusyCandidate.events.isEmpty)
}

@Test func matchingConfirmedObservationRefreshesMetricsAndProcesses() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    let original = GPUSnapshot(
        index: 0, uuid: "GPU-0", name: "GPU", utilizationPercent: 70,
        usedMemoryMiB: 1_000, totalMemoryMiB: 24_000, temperatureCelsius: 60,
        processes: [.init(pid: 10, name: "old", usedMemoryMiB: 900)]
    )
    let refreshed = GPUSnapshot(
        index: 0, uuid: "GPU-0", name: "GPU", utilizationPercent: 90,
        usedMemoryMiB: 2_000, totalMemoryMiB: 24_000, temperatureCelsius: 70,
        processes: [.init(pid: 20, name: "new", usedMemoryMiB: 1_800)]
    )
    _ = await tracker.recordSuccess(ServerSnapshot(server: .fixture, gpus: [original], capturedAt: .distantPast))

    let update = await tracker.recordSuccess(
        ServerSnapshot(server: .fixture, gpus: [refreshed], capturedAt: .distantFuture)
    )

    #expect(update.stableSnapshot?.gpus == [refreshed])
    #expect(update.stableSnapshot?.capturedAt == .distantFuture)
    #expect(update.events.isEmpty)
}

@Test func thirdFailureSendsOneOfflineEvent() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))

    let first = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    let second = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    let third = await tracker.recordFailure(server: .fixture, failure: .connectivity)

    #expect(first.health == .degraded(message: ProbeFailure.connectivity.localizedDescription, consecutiveFailures: 1))
    #expect(second.health == .degraded(message: ProbeFailure.connectivity.localizedDescription, consecutiveFailures: 2))
    #expect(third.health == .offline(message: ProbeFailure.connectivity.localizedDescription))
    #expect(third.stableSnapshot == .snapshot(.free))
    #expect(third.events == [
        .serverOffline(server: .fixture, message: ProbeFailure.connectivity.localizedDescription),
    ])
}

@Test func repeatedFailuresAfterOfflineAreSilent() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)

    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    let update = await tracker.recordFailure(server: .fixture, failure: .connectivity)

    #expect(update.health == .offline(message: ProbeFailure.connectivity.localizedDescription))
    #expect(update.stableSnapshot == nil)
    #expect(update.events.isEmpty)
}

@Test func recoveryAfterOfflineRebaselinesWithoutGPUChange() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)

    let recovery = await tracker.recordSuccess(.snapshot(.busy))
    #expect(recovery.events == [.serverRecovered(server: .fixture)])

    #expect((await tracker.recordSuccess(.snapshot(.free))).events.isEmpty)
    let confirmedChange = await tracker.recordSuccess(.snapshot(.free))
    #expect(confirmedChange.events == [
        .gpuChanged(server: .fixture, gpu: .gpu(index: 0, .free), from: .busy, to: .free),
    ])
}

@Test func nonConnectivityFailuresHaveIndependentHealthAndResetOfflineAccumulation() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)

    let authentication = await tracker.recordFailure(server: .fixture, failure: .authentication)
    #expect(authentication.health == .warning(message: ProbeFailure.authentication.localizedDescription))
    #expect(authentication.events.isEmpty)

    let firstAfterReset = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    let secondAfterReset = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    #expect(firstAfterReset.health == .degraded(
        message: ProbeFailure.connectivity.localizedDescription,
        consecutiveFailures: 1
    ))
    #expect(secondAfterReset.health == .degraded(
        message: ProbeFailure.connectivity.localizedDescription,
        consecutiveFailures: 2
    ))
    #expect(firstAfterReset.events.isEmpty)
    #expect(secondAfterReset.events.isEmpty)
}

@Test(arguments: [
    ProbeFailure.remoteCommand,
    ProbeFailure.invalidResponse,
    ProbeFailure.localLaunch,
])
func ordinaryProbeFailuresRemainWarningsWithoutOfflineEvents(_ failure: ProbeFailure) async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)

    for _ in 0..<4 {
        let update = await tracker.recordFailure(server: .fixture, failure: failure)
        #expect(update.health == .warning(message: failure.localizedDescription))
        #expect(update.events.isEmpty)
    }
}

@Test func hostKeyFailuresUseSecurityHealthWithoutOfflineEvents() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)

    for _ in 0..<4 {
        let update = await tracker.recordFailure(server: .fixture, failure: .hostKeySecurity)
        #expect(update.health == .security(message: ProbeFailure.hostKeySecurity.localizedDescription))
        #expect(update.events.isEmpty)
    }
}

@Test func warningAfterOfflineDoesNotAllowADuplicateOfflineEventBeforeRecovery() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    let firstOffline = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    #expect(firstOffline.events.count == 1)

    let warning = await tracker.recordFailure(server: .fixture, failure: .remoteCommand)
    #expect(warning.health == .warning(message: ProbeFailure.remoteCommand.localizedDescription))

    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    _ = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    let offlineAgain = await tracker.recordFailure(server: .fixture, failure: .connectivity)
    #expect(offlineAgain.health == .offline(message: ProbeFailure.connectivity.localizedDescription))
    #expect(offlineAgain.events.isEmpty)

    let recovery = await tracker.recordSuccess(.snapshot(.free))
    #expect(recovery.events == [.serverRecovered(server: .fixture)])
}

@Test func failureAfterCandidateRetainsTheConfirmedSnapshot() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    _ = await tracker.recordSuccess(.snapshot(.busy))

    let failed = await tracker.recordFailure(server: .fixture, failure: .connectivity)

    #expect(failed.stableSnapshot?.gpus.map(\.occupancy) == [.free])
}

@Test func rebaselineDefensivelyUniquesDuplicateGPUUUIDs() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    let duplicate = GPUSnapshot(
        index: 1, uuid: "GPU-0", name: "duplicate", utilizationPercent: 99,
        usedMemoryMiB: 999, totalMemoryMiB: 1_000, temperatureCelsius: 99, processes: []
    )
    let snapshot = ServerSnapshot(
        server: .fixture,
        gpus: [.gpu(index: 0, .free), duplicate],
        capturedAt: .distantPast
    )

    let update = await tracker.recordSuccess(snapshot)

    #expect(update.stableSnapshot?.gpus.count == 1)
    #expect(update.stableSnapshot?.gpus.first?.index == 0)
}
