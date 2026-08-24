import Foundation

public struct MonitorCycle: Sendable {
    public let snapshots: [String: ServerSnapshot]
    public let health: [String: ServerHealth]
    public let events: [MonitorEvent]
    public let completedAt: Date

    public init(
        snapshots: [String: ServerSnapshot],
        health: [String: ServerHealth],
        events: [MonitorEvent],
        completedAt: Date
    ) {
        self.snapshots = snapshots
        self.health = health
        self.events = events
        self.completedAt = completedAt
    }
}

public actor MonitorCoordinator {
    private struct ActivePoll {
        let generation: UInt64
        let task: Task<MonitorCycle, Never>
    }

    private let servers: [ServerConfig]
    private let probe: any GPUProbing
    private let tracker: StateTracker
    private var activePoll: ActivePoll?
    private var nextPollGeneration: UInt64 = 0

    public init(
        servers: [ServerConfig],
        probe: any GPUProbing,
        tracker: StateTracker = StateTracker(confirmationCount: 2, offlineFailureCount: 3)
    ) {
        self.servers = servers
        self.probe = probe
        self.tracker = tracker
    }

    public func poll() async -> MonitorCycle {
        let poll: ActivePoll
        if let activePoll {
            poll = activePoll
        } else {
            nextPollGeneration &+= 1
            let task = Task { [servers, probe, tracker] in
                await Self.runPoll(servers: servers, probe: probe, tracker: tracker)
            }
            poll = ActivePoll(generation: nextPollGeneration, task: task)
            activePoll = poll
        }

        let cycle = await poll.task.value
        if activePoll?.generation == poll.generation {
            activePoll = nil
        }
        return cycle
    }

    private static func runPoll(
        servers: [ServerConfig],
        probe: any GPUProbing,
        tracker: StateTracker
    ) async -> MonitorCycle {
        let outcomes = await withTaskGroup(
            of: ProbeOutcome.self,
            returning: [ProbeOutcome].self
        ) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    await ProbeOutcome.capture(index: index, server: server, probe: probe)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        var snapshots: [String: ServerSnapshot] = [:]
        var health: [String: ServerHealth] = [:]
        var events: [MonitorEvent] = []

        for outcome in outcomes.sorted(by: { $0.index < $1.index }) {
            let update: StateUpdate
            switch outcome.result {
            case let .success(snapshot):
                update = await tracker.recordSuccess(snapshot)
            case let .failure(message):
                update = await tracker.recordFailure(server: outcome.server, message: message)
            }

            if let stableSnapshot = update.stableSnapshot {
                snapshots[outcome.server.id] = stableSnapshot
            }
            health[outcome.server.id] = update.health
            events.append(contentsOf: update.events)
        }

        return MonitorCycle(
            snapshots: snapshots,
            health: health,
            events: events,
            completedAt: Date()
        )
    }
}

private struct ProbeOutcome: Sendable {
    enum Result: Sendable {
        case success(ServerSnapshot)
        case failure(String)
    }

    let index: Int
    let server: ServerConfig
    let result: Result

    static func capture(
        index: Int,
        server: ServerConfig,
        probe: any GPUProbing
    ) async -> ProbeOutcome {
        do {
            return ProbeOutcome(
                index: index,
                server: server,
                result: .success(try await probe.sample(server: server))
            )
        } catch {
            return ProbeOutcome(
                index: index,
                server: server,
                result: .failure(error.localizedDescription)
            )
        }
    }
}
