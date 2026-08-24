import Testing
import GPUMonitorCore

private actor WeChatStyleSink: NotificationSink {
    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        NotificationDeliveryResult(
            attemptedCount: events.count,
            deliveredCount: events.count,
            failures: []
        )
    }
}

private actor TestAuthorizationProvider: NotificationAuthorizationProviding {
    func requestAuthorization() async -> NotificationAuthorizationState {
        .denied
    }

    func authorizationState() async -> NotificationAuthorizationState {
        .notDetermined
    }
}

@Test func genericNotificationSinkDoesNotRequirePlatformAuthorization() async {
    let sink = WeChatStyleSink()

    let result = await sink.send(events: [.serverRecovered(server: .fixture)])

    #expect(result.attemptedCount == 1)
    #expect(result.deliveredCount == 1)
    #expect(result.failedCount == 0)
    #expect(result.isSuccess)
}

@Test func notificationAuthorizationIsAnIndependentCapability() async {
    let provider = TestAuthorizationProvider()

    #expect(await provider.authorizationState() == .notDetermined)
    #expect(await provider.requestAuthorization() == .denied)
}

@Test func deliveryResultReportsFailuresWithoutUnderlyingErrorDetails() {
    let result = NotificationDeliveryResult(
        attemptedCount: 3,
        deliveredCount: 1,
        failures: [
            NotificationDeliveryFailure(messageIndex: 0, reason: .schedulingFailed),
            NotificationDeliveryFailure(messageIndex: 2, reason: .schedulingFailed),
        ]
    )

    #expect(result.failedCount == 2)
    #expect(!result.isSuccess)
    #expect(result.failures.map(\.messageIndex) == [0, 2])
}
