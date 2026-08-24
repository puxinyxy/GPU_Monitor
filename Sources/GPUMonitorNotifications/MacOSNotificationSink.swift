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

private struct NotificationDeliveryRoute: Equatable, Sendable {
    let mode: NotificationDeliveryMode
    let revision: UInt64
}

private enum NotificationRouteError: Error {
    case repeatedlyInvalidated
}

public actor MacOSNotificationSink: NotificationSink, NotificationAuthorizationProviding {
    private let center: any UserNotificationCenterClient
    private let compatibility: any CompatibilityNotificationClient
    private let formatter: NotificationFormatter
    private var deliveryMode: NotificationDeliveryMode = .native
    private var reportedAuthorizationState: NotificationAuthorizationState = .notDetermined
    private var authorizationRevision: UInt64 = 0
    private var latestConclusiveAuthorizationRevision: UInt64 = 0
    private var latestInconclusiveAuthorizationRevision: UInt64 = 0
    private var activeAuthorizationOperations: Set<UInt64> = []
    private var activeCompatibilityCommands: [UUID: Task<Void, Error>] = [:]
    private var isDrainingCompatibilityCommands = false
    private static let maximumCompatibilityRouteSelections = 3

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
        defer { finishAuthorizationOperation(revision) }
        do {
            let state = try await center.requestAuthorization()
            return recordNativeState(state, revision: revision)
        } catch {
            guard Self.isNotificationsNotAllowed(error) else {
                return recordNativeState(.error, revision: revision)
            }
            let currentState = await center.authorizationState()
            switch currentState {
            case .notDetermined, .error:
                return establishCompatibility(revision: revision)
            case .compatibility:
                return recordNativeState(.error, revision: revision)
            case .authorized, .provisional, .ephemeral, .denied:
                return recordNativeState(currentState, revision: revision)
            }
        }
    }

    public func authorizationState() async -> NotificationAuthorizationState {
        let revision = beginAuthorizationOperation()
        defer { finishAuthorizationOperation(revision) }
        let state = await center.authorizationState()
        return recordObservedNativeState(state, revision: revision)
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
                try await deliver(message)
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

        return try! NotificationDeliveryResult(
            attemptedCount: messages.count,
            failures: failures
        )
    }

    public func cancelAndDrainCompatibilityCommands() async {
        isDrainingCompatibilityCommands = true
        let commands = Array(activeCompatibilityCommands.values)
        for command in commands {
            command.cancel()
        }
        for command in commands {
            _ = try? await command.value
        }
    }

    private func beginAuthorizationOperation() -> UInt64 {
        authorizationRevision &+= 1
        let revision = authorizationRevision
        activeAuthorizationOperations.insert(revision)
        return revision
    }

    private func finishAuthorizationOperation(_ revision: UInt64) {
        activeAuthorizationOperations.remove(revision)
    }

    private func recordNativeState(
        _ state: NotificationAuthorizationState,
        revision: UInt64
    ) -> NotificationAuthorizationState {
        let safeState = state == .compatibility ? NotificationAuthorizationState.error : state
        switch safeState {
        case .authorized, .provisional, .ephemeral, .denied:
            guard revision >= latestConclusiveAuthorizationRevision else {
                return reportedAuthorizationState
            }
            latestConclusiveAuthorizationRevision = revision
            deliveryMode = .native
            reportedAuthorizationState = safeState
            return safeState
        case .notDetermined, .error:
            guard latestConclusiveAuthorizationRevision == 0,
                  revision >= latestInconclusiveAuthorizationRevision else {
                return reportedAuthorizationState
            }
            latestInconclusiveAuthorizationRevision = revision
            deliveryMode = .native
            reportedAuthorizationState = safeState
            return safeState
        case .compatibility:
            preconditionFailure("Compatibility is not a native authorization state")
        }
    }

    private func recordObservedNativeState(
        _ state: NotificationAuthorizationState,
        revision: UInt64
    ) -> NotificationAuthorizationState {
        switch state {
        case .authorized, .provisional, .ephemeral, .denied:
            return recordNativeState(state, revision: revision)
        case .notDetermined, .error:
            return recordNativeState(state, revision: revision)
        case .compatibility:
            return recordNativeState(.error, revision: revision)
        }
    }

    private func establishCompatibility(revision: UInt64) -> NotificationAuthorizationState {
        guard revision >= latestConclusiveAuthorizationRevision,
              reportedAuthorizationState != .denied else {
            return reportedAuthorizationState
        }
        latestConclusiveAuthorizationRevision = revision
        deliveryMode = .compatibility
        reportedAuthorizationState = .compatibility
        return .compatibility
    }

    private func selectDeliveryRoute() async -> NotificationDeliveryRoute {
        guard deliveryMode == .compatibility else {
            return NotificationDeliveryRoute(mode: .native, revision: authorizationRevision)
        }

        let revision = beginAuthorizationOperation()
        defer { finishAuthorizationOperation(revision) }
        let state = await center.authorizationState()
        _ = recordObservedNativeState(state, revision: revision)
        return NotificationDeliveryRoute(mode: deliveryMode, revision: revision)
    }

    private func deliver(_ message: NotificationMessage) async throws {
        for _ in 0..<Self.maximumCompatibilityRouteSelections {
            try Task.checkCancellation()
            let route = await selectDeliveryRoute()
            try Task.checkCancellation()

            switch route.mode {
            case .native:
                try await deliverNative(message)
                return
            case .compatibility:
                guard compatibilityRouteIsCurrent(route) else { continue }
                try await deliverCompatibility(message)
                return
            }
        }

        throw NotificationRouteError.repeatedlyInvalidated
    }

    private func compatibilityRouteIsCurrent(_ route: NotificationDeliveryRoute) -> Bool {
        route.mode == .compatibility &&
            deliveryMode == .compatibility &&
            route.revision == authorizationRevision &&
            activeAuthorizationOperations.isEmpty
    }

    private func deliverCompatibility(_ message: NotificationMessage) async throws {
        try Task.checkCancellation()
        guard !isDrainingCompatibilityCommands else { throw CancellationError() }

        let identifier = UUID()
        let command = Task { [compatibility] in
            try Task.checkCancellation()
            try await compatibility.add(title: message.title, body: message.body)
        }
        activeCompatibilityCommands[identifier] = command
        defer { activeCompatibilityCommands.removeValue(forKey: identifier) }

        try await withTaskCancellationHandler {
            try await command.value
        } onCancel: {
            command.cancel()
        }
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
