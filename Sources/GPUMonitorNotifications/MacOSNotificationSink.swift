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
        do {
            let state = try await center.requestAuthorization()
            return applyNativeState(state)
        } catch {
            guard Self.isNotificationsNotAllowed(error) else {
                deliveryMode = .native
                return .error
            }
            let currentState = await center.authorizationState()
            guard currentState != .denied else {
                deliveryMode = .native
                return .denied
            }
            if currentState == .authorized ||
                currentState == .provisional ||
                currentState == .ephemeral {
                deliveryMode = .native
                return currentState
            }
            deliveryMode = .compatibility
            return .compatibility
        }
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        let state = await center.authorizationState()
        switch state {
        case .authorized, .provisional, .ephemeral, .denied:
            deliveryMode = .native
            return state
        case .notDetermined, .error:
            return deliveryMode == .compatibility ? .compatibility : state
        case .compatibility:
            deliveryMode = .compatibility
            return .compatibility
        }
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
                    try await center.add(MacOSNotificationRequest(
                        identifier: UUID().uuidString,
                        title: message.title,
                        body: message.body,
                        playsDefaultSound: true
                    ))
                case .compatibility:
                    try await compatibility.add(title: message.title, body: message.body)
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

    private func applyNativeState(
        _ state: NotificationAuthorizationState
    ) -> NotificationAuthorizationState {
        deliveryMode = state == .compatibility ? .compatibility : .native
        return state
    }

    private static func isNotificationsNotAllowed(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == UNErrorDomain &&
            error.code == UNError.Code.notificationsNotAllowed.rawValue
    }
}
