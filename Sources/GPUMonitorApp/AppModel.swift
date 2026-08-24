import Foundation
import GPUMonitorCore
import GPUMonitorNotifications
import SwiftUI

public enum MenuStatus: Equatable, Sendable {
    case unknown
    case available
    case allBusy
    case warning
    case security
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
        case .security:
            "lock.trianglebadge.exclamationmark"
        case .offline:
            "wifi.slash"
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    public typealias Poll = @Sendable () async -> MonitorCycle
    public typealias CancelPoll = @Sendable () async -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct RefreshResult: Sendable {
        let cycle: MonitorCycle
        let delivery: NotificationDeliveryResult
    }

    private struct ActiveRefresh {
        let generation: UInt64
        let task: Task<RefreshResult?, Never>
    }

    private struct ActiveAuthorizationRefresh {
        let generation: UInt64
        let lifecycleGeneration: UInt64
        let task: Task<NotificationAuthorizationState, Never>
    }

    private enum LifecycleState {
        case idle
        case running
        case stopping
        case stopped
    }

    @Published public private(set) var snapshots: [String: ServerSnapshot] = [:]
    @Published public private(set) var health: [String: ServerHealth] = [:]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var startupError: String?
    @Published public private(set) var notificationAuthorization: NotificationAuthorizationState = .notDetermined
    @Published public private(set) var recentErrorSummary: String?

    public let servers: [ServerConfig]
    public static let emptyConfigurationGuidance = "修复配置后重启应用。"

    private let poll: Poll
    private let cancelPoll: CancelPoll
    private let notifications: any NotificationSink
    private let authorizationProvider: any NotificationAuthorizationProviding
    private let sleep: Sleep
    private let pollInterval: Duration
    private var lifecycleState: LifecycleState = .idle
    private var lifecycleGeneration: UInt64 = 0
    private var startupTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var nextRefreshGeneration: UInt64 = 0
    private var activeRefresh: ActiveRefresh?
    private var nextAuthorizationRefreshGeneration: UInt64 = 0
    private var activeAuthorizationRefresh: ActiveAuthorizationRefresh?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownGeneration: UInt64?

    public init(
        servers: [ServerConfig],
        startupError: String? = nil,
        poll: @escaping Poll,
        cancelPoll: @escaping CancelPoll = {},
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
        self.cancelPoll = cancelPoll
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
            cancelPoll: { await coordinator.cancelActivePoll() },
            notifications: notificationSink,
            authorizationProvider: notificationSink
        )
    }

    public func start() async {
        switch lifecycleState {
        case .stopping, .stopped:
            return
        case .running:
            if let startupTask { await startupTask.value }
            return
        case .idle:
            break
        }
        lifecycleState = .running
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runStartup(generation: generation)
        }
        startupTask = task

        await task.value
        if lifecycleGeneration == generation {
            startupTask = nil
        }
    }

    public func refresh() async {
        guard lifecycleState != .stopping, lifecycleState != .stopped else { return }
        await refreshNotificationAuthorization()
        guard lifecycleState != .stopping, lifecycleState != .stopped else { return }
        let refresh: ActiveRefresh
        if let activeRefresh {
            refresh = activeRefresh
        } else {
            nextRefreshGeneration &+= 1
            let generation = nextRefreshGeneration
            let task = Task<RefreshResult?, Never> { [poll, notifications] in
                guard !Task.isCancelled else { return nil }
                let cycle = await poll()
                guard !Task.isCancelled else { return nil }
                let delivery = await notifications.send(events: cycle.events)
                guard !Task.isCancelled else { return nil }
                return RefreshResult(cycle: cycle, delivery: delivery)
            }
            refresh = ActiveRefresh(generation: generation, task: task)
            activeRefresh = refresh
            isRefreshing = true
        }

        let result = await refresh.task.value
        guard activeRefresh?.generation == refresh.generation else { return }
        activeRefresh = nil
        isRefreshing = false
        if let result {
            apply(result.cycle)
            if result.delivery.failedCount > 0 {
                recentErrorSummary = "通知发送失败：\(result.delivery.failedCount) 条"
            }
        }
    }

    public func refreshNotificationAuthorization() async {
        guard lifecycleState != .stopping, lifecycleState != .stopped else { return }

        let refresh: ActiveAuthorizationRefresh
        if let activeAuthorizationRefresh {
            refresh = activeAuthorizationRefresh
        } else {
            nextAuthorizationRefreshGeneration &+= 1
            let generation = nextAuthorizationRefreshGeneration
            let lifecycleGeneration = lifecycleGeneration
            let task = Task<NotificationAuthorizationState, Never> { [authorizationProvider] in
                await authorizationProvider.authorizationState()
            }
            refresh = ActiveAuthorizationRefresh(
                generation: generation,
                lifecycleGeneration: lifecycleGeneration,
                task: task
            )
            activeAuthorizationRefresh = refresh
        }

        let authorization = await refresh.task.value
        guard activeAuthorizationRefresh?.generation == refresh.generation else { return }
        activeAuthorizationRefresh = nil
        guard lifecycleGeneration == refresh.lifecycleGeneration,
              lifecycleState != .stopping,
              lifecycleState != .stopped else {
            return
        }
        notificationAuthorization = authorization
        if authorization == .error {
            recentErrorSummary = "通知授权状态读取失败"
        }
    }

    public func stop() async {
        switch lifecycleState {
        case .stopped:
            return
        case .stopping:
            let shutdown = shutdownTask
            let generation = shutdownGeneration
            if let shutdown { await shutdown.value }
            completeShutdown(generation: generation)
            return
        case .idle, .running:
            break
        }

        lifecycleState = .stopping
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let startup = startupTask
        let loop = loopTask
        let refresh = activeRefresh
        let authorizationRefresh = activeAuthorizationRefresh
        startupTask = nil
        loopTask = nil
        activeAuthorizationRefresh = nil
        startup?.cancel()
        loop?.cancel()
        refresh?.task.cancel()
        authorizationRefresh?.task.cancel()

        let shutdown = Task<Void, Never> { [cancelPoll] in
            await cancelPoll()
        }
        shutdownGeneration = generation
        shutdownTask = shutdown
        await shutdown.value
        completeShutdown(generation: generation)
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
            if case .security = value { return true }
            return false
        }) {
            return .security
        }
        if health.values.contains(where: { value in
            switch value {
            case .degraded, .warning: true
            case .unknown, .online, .security, .offline: false
            }
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

    private func runStartup(generation: UInt64) async {
        let authorization = await authorizationProvider.requestAuthorization()
        guard isActiveLifecycle(generation) else { return }
        notificationAuthorization = authorization
        if authorization == .error {
            recentErrorSummary = "通知授权状态读取失败"
        }

        await refresh()
        guard isActiveLifecycle(generation) else { return }
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
    }

    private func isActiveLifecycle(_ generation: UInt64) -> Bool {
        lifecycleState == .running && lifecycleGeneration == generation && !Task.isCancelled
    }

    private func completeShutdown(generation: UInt64?) {
        guard lifecycleState == .stopping,
              let generation,
              shutdownGeneration == generation else {
            return
        }
        activeRefresh = nil
        isRefreshing = false
        shutdownTask = nil
        shutdownGeneration = nil
        lifecycleState = .stopped
    }

    private func apply(_ cycle: MonitorCycle) {
        snapshots.merge(cycle.snapshots) { _, new in new }
        health = cycle.health
        lastUpdated = cycle.completedAt

        for server in servers {
            switch cycle.health[server.id] {
            case let .degraded(message, _),
                 let .warning(message),
                 let .security(message),
                 let .offline(message):
                recentErrorSummary = "服务器 \(server.label)：\(message)"
                return
            case .unknown, .online, .none:
                continue
            }
        }
    }

    deinit {
        startupTask?.cancel()
        loopTask?.cancel()
        activeRefresh?.task.cancel()
        activeAuthorizationRefresh?.task.cancel()
        shutdownTask?.cancel()
    }
}
