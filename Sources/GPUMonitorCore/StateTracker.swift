public struct StateUpdate: Equatable, Sendable {
    public let health: ServerHealth
    public let stableSnapshot: ServerSnapshot?
    public let events: [MonitorEvent]

    public init(health: ServerHealth, stableSnapshot: ServerSnapshot?, events: [MonitorEvent]) {
        self.health = health
        self.stableSnapshot = stableSnapshot
        self.events = events
    }
}

public actor StateTracker {
    private struct GPURecord {
        var stable: GPUOccupancy
        var candidate: GPUOccupancy?
        var candidateCount = 0
    }

    private struct ServerRecord {
        var failures = 0
        var offline = false
        var lastSnapshot: ServerSnapshot?
        var gpus: [String: GPURecord] = [:]
    }

    private let confirmationCount: Int
    private let offlineFailureCount: Int
    private var servers: [String: ServerRecord] = [:]

    public init(confirmationCount: Int, offlineFailureCount: Int) {
        precondition(confirmationCount > 0)
        precondition(offlineFailureCount > 0)
        self.confirmationCount = confirmationCount
        self.offlineFailureCount = offlineFailureCount
    }

    public func recordSuccess(_ snapshot: ServerSnapshot) -> StateUpdate {
        var record = servers[snapshot.server.id] ?? ServerRecord()
        let recoveredFromOffline = record.offline

        record.failures = 0
        record.offline = false

        if recoveredFromOffline {
            rebaseline(&record, with: snapshot)
            servers[snapshot.server.id] = record
            return StateUpdate(
                health: .online,
                stableSnapshot: record.lastSnapshot,
                events: [.serverRecovered(server: snapshot.server)]
            )
        }

        if record.lastSnapshot == nil {
            rebaseline(&record, with: snapshot)
            servers[snapshot.server.id] = record
            return StateUpdate(health: .online, stableSnapshot: record.lastSnapshot, events: [])
        }

        var events: [MonitorEvent] = []
        for gpu in snapshot.gpus {
            guard var gpuRecord = record.gpus[gpu.uuid] else {
                record.gpus[gpu.uuid] = GPURecord(stable: gpu.occupancy)
                continue
            }

            let observed = gpu.occupancy
            guard observed != gpuRecord.stable else {
                gpuRecord.candidate = nil
                gpuRecord.candidateCount = 0
                record.gpus[gpu.uuid] = gpuRecord
                continue
            }

            if gpuRecord.candidate == observed {
                gpuRecord.candidateCount += 1
            } else {
                gpuRecord.candidate = observed
                gpuRecord.candidateCount = 1
            }

            if gpuRecord.candidateCount >= confirmationCount {
                let previous = gpuRecord.stable
                gpuRecord.stable = observed
                gpuRecord.candidate = nil
                gpuRecord.candidateCount = 0
                events.append(.gpuChanged(server: snapshot.server, gpu: gpu, from: previous, to: observed))
            }

            record.gpus[gpu.uuid] = gpuRecord
        }

        record.lastSnapshot = snapshot
        servers[snapshot.server.id] = record
        return StateUpdate(health: .online, stableSnapshot: record.lastSnapshot, events: events)
    }

    public func recordFailure(server: ServerConfig, message: String) -> StateUpdate {
        var record = servers[server.id] ?? ServerRecord()
        record.failures += 1

        let events: [MonitorEvent]
        let health: ServerHealth
        if record.offline {
            events = []
            health = .offline(message: message)
        } else if record.failures >= offlineFailureCount {
            record.offline = true
            events = [.serverOffline(server: server, message: message)]
            health = .offline(message: message)
        } else {
            events = []
            health = .degraded(message: message, consecutiveFailures: record.failures)
        }

        servers[server.id] = record
        return StateUpdate(health: health, stableSnapshot: record.lastSnapshot, events: events)
    }

    private func rebaseline(_ record: inout ServerRecord, with snapshot: ServerSnapshot) {
        record.lastSnapshot = snapshot
        record.gpus = Dictionary(
            uniqueKeysWithValues: snapshot.gpus.map { ($0.uuid, GPURecord(stable: $0.occupancy)) }
        )
    }
}
