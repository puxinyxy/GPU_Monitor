public enum NotificationDeliveryFailureReason: Equatable, Sendable {
    case schedulingFailed
}

public struct NotificationDeliveryFailure: Equatable, Sendable {
    public let messageIndex: Int
    public let reason: NotificationDeliveryFailureReason

    public init(messageIndex: Int, reason: NotificationDeliveryFailureReason) {
        self.messageIndex = messageIndex
        self.reason = reason
    }
}

public enum NotificationDeliveryResultValidationError: Error, Equatable, Sendable {
    case negativeAttemptedCount
    case failureIndexOutOfRange(Int)
    case duplicateFailureIndex(Int)
}

public struct NotificationDeliveryResult: Equatable, Sendable {
    public let attemptedCount: Int
    public let deliveredCount: Int
    public let failures: [NotificationDeliveryFailure]

    public init(
        attemptedCount: Int,
        failures: [NotificationDeliveryFailure]
    ) throws {
        guard attemptedCount >= 0 else {
            throw NotificationDeliveryResultValidationError.negativeAttemptedCount
        }
        var seenFailureIndices: Set<Int> = []
        for failure in failures {
            guard (0..<attemptedCount).contains(failure.messageIndex) else {
                throw NotificationDeliveryResultValidationError.failureIndexOutOfRange(
                    failure.messageIndex
                )
            }
            guard seenFailureIndices.insert(failure.messageIndex).inserted else {
                throw NotificationDeliveryResultValidationError.duplicateFailureIndex(
                    failure.messageIndex
                )
            }
        }

        self.attemptedCount = attemptedCount
        self.deliveredCount = attemptedCount - failures.count
        self.failures = failures
    }

    public var failedCount: Int { failures.count }
    public var isSuccess: Bool { failures.isEmpty }
}

public protocol NotificationSink: Sendable {
    func send(events: [MonitorEvent]) async -> NotificationDeliveryResult
}

public enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
    case compatibility
    case error
}

public protocol NotificationAuthorizationProviding: Sendable {
    func requestAuthorization() async -> NotificationAuthorizationState
    func authorizationState() async -> NotificationAuthorizationState
}
