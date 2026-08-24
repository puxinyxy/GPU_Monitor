import Testing
import GPUMonitorCore

private actor WeChatStyleSink: NotificationSink {
    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        try! NotificationDeliveryResult(
            attemptedCount: events.count,
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

@Test func deliveryResultReportsFailuresWithoutUnderlyingErrorDetails() throws {
    let result = try NotificationDeliveryResult(
        attemptedCount: 3,
        failures: [
            NotificationDeliveryFailure(messageIndex: 0, reason: .schedulingFailed),
            NotificationDeliveryFailure(messageIndex: 2, reason: .schedulingFailed),
        ]
    )

    #expect(result.failedCount == 2)
    #expect(!result.isSuccess)
    #expect(result.failures.map(\.messageIndex) == [0, 2])
}

@Test func deliveryResultDerivesDeliveredCountFromValidatedUniqueFailures() throws {
    let result = try NotificationDeliveryResult(
        attemptedCount: 4,
        failures: [
            NotificationDeliveryFailure(messageIndex: 1, reason: .schedulingFailed),
            NotificationDeliveryFailure(messageIndex: 3, reason: .schedulingFailed),
        ]
    )

    #expect(result.attemptedCount == 4)
    #expect(result.deliveredCount == 2)
    #expect(result.failedCount == 2)
}

@Test func deliveryResultRejectsNegativeAttemptedCount() {
    #expect(throws: NotificationDeliveryResultValidationError.negativeAttemptedCount) {
        try NotificationDeliveryResult(attemptedCount: -1, failures: [])
    }
}

@Test func deliveryResultRejectsOutOfRangeAndDuplicateFailureIndices() {
    #expect(throws: NotificationDeliveryResultValidationError.failureIndexOutOfRange(-1)) {
        try NotificationDeliveryResult(
            attemptedCount: 1,
            failures: [.init(messageIndex: -1, reason: .schedulingFailed)]
        )
    }
    #expect(throws: NotificationDeliveryResultValidationError.failureIndexOutOfRange(1)) {
        try NotificationDeliveryResult(
            attemptedCount: 1,
            failures: [.init(messageIndex: 1, reason: .schedulingFailed)]
        )
    }
    #expect(throws: NotificationDeliveryResultValidationError.duplicateFailureIndex(0)) {
        try NotificationDeliveryResult(
            attemptedCount: 2,
            failures: [
                .init(messageIndex: 0, reason: .schedulingFailed),
                .init(messageIndex: 0, reason: .schedulingFailed),
            ]
        )
    }
}
