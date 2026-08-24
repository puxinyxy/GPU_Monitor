import Foundation
import GPUMonitorCore
import UserNotifications

struct MacOSNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let playsDefaultSound: Bool
}

protocol UserNotificationCenterClient: Sendable {
    func requestAuthorization() async throws -> NotificationAuthorizationState
    func authorizationState() async -> NotificationAuthorizationState
    func add(_ request: MacOSNotificationRequest) async throws
}

final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completeForegroundPresentation(using: completionHandler)
    }

    func completeForegroundPresentation(
        using completionHandler: (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

final class ForegroundNotificationDelegateInstallation: @unchecked Sendable {
    private let delegate: ForegroundNotificationDelegate

    init(
        delegate: ForegroundNotificationDelegate = ForegroundNotificationDelegate(),
        install: (ForegroundNotificationDelegate) -> Void
    ) {
        self.delegate = delegate
        install(delegate)
    }
}

actor LiveUserNotificationCenterClient: UserNotificationCenterClient {
    private let center: UNUserNotificationCenter
    private let foregroundDelegateInstallation: ForegroundNotificationDelegateInstallation

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        self.foregroundDelegateInstallation = ForegroundNotificationDelegateInstallation { delegate in
            center.delegate = delegate
        }
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .error
        }
    }

    func add(_ request: MacOSNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if request.playsDefaultSound {
            content.sound = .default
        }

        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        ))
    }
}

private enum NotificationDeliveryMode: Equatable, Sendable {
    case native
    case compatibility
}

public actor MacOSNotificationSink: NotificationSink, NotificationAuthorizationProviding {
    private let center: any UserNotificationCenterClient
    private let compatibility: any CompatibilityNotificationClient
    private let formatter: NotificationFormatter
    private var deliveryMode: NotificationDeliveryMode = .native
    private var reportedAuthorizationState: NotificationAuthorizationState = .notDetermined
    private var authorizationRevision: UInt64 = 0

    public init(formatter: NotificationFormatter = NotificationFormatter()) {
        self.center = LiveUserNotificationCenterClient()
        self.compatibility = AppleScriptNotificationClient()
        self.formatter = formatter
    }

    init(
        center: any UserNotificationCenterClient,
        compatibility: any CompatibilityNotificationClient = AppleScriptNotificationClient(),
        formatter: NotificationFormatter = NotificationFormatter()
    ) {
        self.center = center
        self.compatibility = compatibility
        self.formatter = formatter
    }

    public func requestAuthorization() async -> NotificationAuthorizationState {
        let revision = beginAuthorizationOperation()
        do {
            let state = try await center.requestAuthorization()
            guard revision == authorizationRevision else {
                return reportedAuthorizationState
            }
            return recordNativeState(state)
        } catch {
            guard revision == authorizationRevision else {
                return reportedAuthorizationState
            }
            guard Self.isNotificationsNotAllowed(error) else {
                return recordNativeState(.error)
            }
            let currentState = await center.authorizationState()
            guard revision == authorizationRevision else {
                return reportedAuthorizationState
            }
            switch currentState {
            case .notDetermined, .error:
                deliveryMode = .compatibility
                reportedAuthorizationState = .compatibility
                return .compatibility
            case .compatibility:
                return recordNativeState(.error)
            case .authorized, .provisional, .ephemeral, .denied:
                return recordNativeState(currentState)
            }
        }
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        let revision = beginAuthorizationOperation()
        let state = await center.authorizationState()
        guard revision == authorizationRevision else {
            return reportedAuthorizationState
        }
        return recordObservedNativeState(state)
    }

    public func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        let messages = formatter.messages(for: events)
        var failures: [NotificationDeliveryFailure] = []

        for (index, message) in messages.enumerated() {
            if Task.isCancelled {
                failures.append(contentsOf: (index..<messages.count).map {
                    NotificationDeliveryFailure(
                        messageIndex: $0,
                        reason: .schedulingFailed
                    )
                })
                break
            }

            do {
                switch deliveryMode {
                case .native:
                    try await deliverNative(message)
                case .compatibility:
                    let compatibilityIsAvailable = await revalidateCompatibilityDelivery()
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    if compatibilityIsAvailable {
                        try await compatibility.add(title: message.title, body: message.body)
                    } else {
                        try await deliverNative(message)
                    }
                }
            } catch is CancellationError {
                failures.append(contentsOf: (index..<messages.count).map {
                    NotificationDeliveryFailure(
                        messageIndex: $0,
                        reason: .schedulingFailed
                    )
                })
                break
            } catch {
                failures.append(NotificationDeliveryFailure(
                    messageIndex: index,
                    reason: .schedulingFailed
                ))
            }
        }

        return NotificationDeliveryResult(
            attemptedCount: messages.count,
            deliveredCount: messages.count - failures.count,
            failures: failures
        )
    }

    private func beginAuthorizationOperation() -> UInt64 {
        authorizationRevision &+= 1
        return authorizationRevision
    }

    private func recordNativeState(
        _ state: NotificationAuthorizationState
    ) -> NotificationAuthorizationState {
        let safeState = state == .compatibility ? NotificationAuthorizationState.error : state
        deliveryMode = .native
        reportedAuthorizationState = safeState
        return safeState
    }

    private func recordObservedNativeState(
        _ state: NotificationAuthorizationState
    ) -> NotificationAuthorizationState {
        switch state {
        case .authorized, .provisional, .ephemeral, .denied:
            return recordNativeState(state)
        case .notDetermined, .error:
            guard deliveryMode == .compatibility else {
                return recordNativeState(state)
            }
            reportedAuthorizationState = .compatibility
            return .compatibility
        case .compatibility:
            return recordNativeState(.error)
        }
    }

    private func revalidateCompatibilityDelivery() async -> Bool {
        let revision = beginAuthorizationOperation()
        let state = await center.authorizationState()
        guard revision == authorizationRevision else { return false }
        return recordObservedNativeState(state) == .compatibility
    }

    private func deliverNative(_ message: NotificationMessage) async throws {
        try await center.add(MacOSNotificationRequest(
            identifier: UUID().uuidString,
            title: message.title,
            body: message.body,
            playsDefaultSound: true
        ))
    }

    private static func isNotificationsNotAllowed(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == UNErrorDomain &&
            error.code == UNError.Code.notificationsNotAllowed.rawValue
    }
}
