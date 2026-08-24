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
    let presentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(presentationOptions)
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

public actor MacOSNotificationSink: NotificationSink, NotificationAuthorizationProviding {
    private let center: any UserNotificationCenterClient
    private let formatter: NotificationFormatter

    public init(formatter: NotificationFormatter = NotificationFormatter()) {
        self.center = LiveUserNotificationCenterClient()
        self.formatter = formatter
    }

    init(
        center: any UserNotificationCenterClient,
        formatter: NotificationFormatter = NotificationFormatter()
    ) {
        self.center = center
        self.formatter = formatter
    }

    public func requestAuthorization() async -> NotificationAuthorizationState {
        do {
            return try await center.requestAuthorization()
        } catch {
            return .error
        }
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        await center.authorizationState()
    }

    public func send(events: [MonitorEvent]) async -> NotificationDeliveryResult {
        let messages = formatter.messages(for: events)
        var failures: [NotificationDeliveryFailure] = []

        for (index, message) in messages.enumerated() {
            let request = MacOSNotificationRequest(
                identifier: UUID().uuidString,
                title: message.title,
                body: message.body,
                playsDefaultSound: true
            )
            do {
                try await center.add(request)
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
}
