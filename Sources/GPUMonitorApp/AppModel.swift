import Foundation
import GPUMonitorCore
import GPUMonitorNotifications
import SwiftUI

public enum MenuStatus: Equatable, Sendable {
    case unknown
    case available
    case allBusy
    case warning
    case offline

    public var systemImage: String {
        switch self {
        case .unknown:
            "cpu"
        case .available:
            "cpu.fill"
        case .allBusy:
            "flame.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .offline:
            "wifi.slash"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public typealias Poll = @Sendable () async -> MonitorCycle
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    @Published public private(set) var snapshots: [String: ServerSnapshot] = [:]
    @Published public private(set) var health: [String: ServerHealth] = [:]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var startupError: String?
    @Published public private(set) var notificationAuthorization: NotificationAuthorizationState = .notDetermined
    @Published public private(set) var recentErrorSummary: String?

    public let servers: [ServerConfig]

    private let poll: Poll
    private let notifications: any NotificationSink
    private let authorizationProvider: any NotificationAuthorizationProviding
    private let sleep: Sleep
    private let pollInterval: Duration
    private var loopTask: Task<Void, Never>?

    public init(
        servers: [ServerConfig],
        startupError: String? = nil,
        poll: @escaping Poll,
        notifications: any NotificationSink,
        authorizationProvider: any NotificationAuthorizationProviding,
        pollInterval: Duration = .seconds(15),
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.servers = servers
        self.startupError = startupError
        self.recentErrorSummary = startupError
        self.poll = poll
        self.notifications = notifications
        self.authorizationProvider = authorizationProvider
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    public static func live(configurationStore: ConfigurationStore = ConfigurationStore()) -> AppModel {
        let servers: [ServerConfig]
        let startupError: String?
        do {
            servers = try configurationStore.loadOrCreate()
            startupError = nil
        } catch {
            servers = []
            startupError = "配置读取失败：\(error.localizedDescription)"
        }

        let probe = SSHGPUProbe()
        let coordinator = MonitorCoordinator(servers: servers, probe: probe)
        let notificationSink = MacOSNotificationSink()
        return AppModel(
            servers: servers,
            startupError: startupError,
            poll: { await coordinator.poll() },
            notifications: notificationSink,
            authorizationProvider: notificationSink
        )
    }

    public func start() async {
        guard loopTask == nil else { return }

        loopTask = Task { [weak self, sleep, pollInterval] in
            while !Task.isCancelled {
                do {
                    try await sleep(pollInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }

        notificationAuthorization = await authorizationProvider.requestAuthorization()
        if notificationAuthorization == .error {
            recentErrorSummary = "通知授权状态读取失败"
        }
        await refresh()
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let cycle = await poll()
        apply(cycle)
        let delivery = await notifications.send(events: cycle.events)
        if delivery.failedCount > 0 {
            recentErrorSummary = "通知发送失败：\(delivery.failedCount) 条"
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    public var menuTitle: String {
        let gpus = snapshots.values.flatMap(\.gpus)
        guard !gpus.isEmpty else { return "GPU —/—" }
        return "GPU \(gpus.filter { $0.occupancy == .free }.count)/\(gpus.count) 空闲"
    }

    public var menuStatus: MenuStatus {
        if health.values.contains(where: { value in
            if case .offline = value { return true }
            return false
        }) {
            return .offline
        }
        if health.values.contains(where: { value in
            if case .degraded = value { return true }
            return false
        }) {
            return .warning
        }
        guard servers.allSatisfy({ server in
            if case .online = health[server.id] { return true }
            return false
        }) else {
            return .unknown
        }

        let gpus = snapshots.values.flatMap(\.gpus)
        guard !gpus.isEmpty else { return .unknown }
        return gpus.contains(where: { $0.occupancy == .free }) ? .available : .allBusy
    }

    public var menuSystemImage: String { menuStatus.systemImage }

    func applyForTesting(_ cycle: MonitorCycle) {
        apply(cycle)
    }

    private func apply(_ cycle: MonitorCycle) {
        snapshots.merge(cycle.snapshots) { _, new in new }
        health = cycle.health
        lastUpdated = cycle.completedAt

        for server in servers {
            switch cycle.health[server.id] {
            case let .degraded(message, _), let .offline(message):
                recentErrorSummary = "服务器 \(server.label)：\(message)"
                return
            case .unknown, .online, .none:
                continue
            }
        }
    }

    deinit {
        loopTask?.cancel()
    }
}
