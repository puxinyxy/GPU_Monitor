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

public struct NotificationDeliveryResult: Equatable, Sendable {
    public let attemptedCount: Int
    public let deliveredCount: Int
    public let failures: [NotificationDeliveryFailure]

    public init(
        attemptedCount: Int,
        deliveredCount: Int,
        failures: [NotificationDeliveryFailure]
    ) {
        self.attemptedCount = attemptedCount
        self.deliveredCount = deliveredCount
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
