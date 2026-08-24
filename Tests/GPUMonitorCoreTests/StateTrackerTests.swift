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
    #expect((await tracker.recordSuccess(.snapshot(.busy))).events.isEmpty)

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

@Test func thirdFailureSendsOneOfflineEvent() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))

    let first = await tracker.recordFailure(server: .fixture, message: "timeout")
    let second = await tracker.recordFailure(server: .fixture, message: "timeout")
    let third = await tracker.recordFailure(server: .fixture, message: "timeout")

    #expect(first.health == .degraded(message: "timeout", consecutiveFailures: 1))
    #expect(second.health == .degraded(message: "timeout", consecutiveFailures: 2))
    #expect(third.health == .offline(message: "timeout"))
    #expect(third.stableSnapshot == .snapshot(.free))
    #expect(third.events == [.serverOffline(server: .fixture, message: "timeout")])
}

@Test func repeatedFailuresAfterOfflineAreSilent() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)

    _ = await tracker.recordFailure(server: .fixture, message: "timeout")
    _ = await tracker.recordFailure(server: .fixture, message: "timeout")
    _ = await tracker.recordFailure(server: .fixture, message: "timeout")
    let update = await tracker.recordFailure(server: .fixture, message: "still timeout")

    #expect(update.health == .offline(message: "still timeout"))
    #expect(update.stableSnapshot == nil)
    #expect(update.events.isEmpty)
}

@Test func recoveryAfterOfflineRebaselinesWithoutGPUChange() async {
    let tracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    _ = await tracker.recordSuccess(.snapshot(.free))
    _ = await tracker.recordFailure(server: .fixture, message: "timeout")
    _ = await tracker.recordFailure(server: .fixture, message: "timeout")
    _ = await tracker.recordFailure(server: .fixture, message: "timeout")

    let recovery = await tracker.recordSuccess(.snapshot(.busy))
    #expect(recovery.events == [.serverRecovered(server: .fixture)])

    #expect((await tracker.recordSuccess(.snapshot(.free))).events.isEmpty)
    let confirmedChange = await tracker.recordSuccess(.snapshot(.free))
    #expect(confirmedChange.events == [
        .gpuChanged(server: .fixture, gpu: .gpu(index: 0, .free), from: .busy, to: .free),
    ])
}
