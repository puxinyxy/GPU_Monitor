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
        var confirmed: GPUSnapshot
        var candidate: GPUOccupancy?
        var candidateCount = 0
    }

    private struct ServerRecord {
        var connectivityFailures = 0
        var connectivityOffline = false
        var recoveryEventPending = false
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
        let recoveredFromOffline = record.recoveryEventPending

        record.connectivityFailures = 0
        record.connectivityOffline = false
        record.recoveryEventPending = false

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
        var nextGPURecords: [String: GPURecord] = [:]
        var confirmedGPUs: [GPUSnapshot] = []
        var confirmedSnapshotChanged = false
        for gpu in Self.uniqueGPUs(snapshot.gpus) {
            guard var gpuRecord = record.gpus[gpu.uuid] else {
                let newRecord = GPURecord(confirmed: gpu)
                nextGPURecords[gpu.uuid] = newRecord
                confirmedGPUs.append(newRecord.confirmed)
                confirmedSnapshotChanged = true
                continue
            }

            let observed = gpu.occupancy
            guard observed != gpuRecord.confirmed.occupancy else {
                gpuRecord.confirmed = gpu
                gpuRecord.candidate = nil
                gpuRecord.candidateCount = 0
                nextGPURecords[gpu.uuid] = gpuRecord
                confirmedGPUs.append(gpuRecord.confirmed)
                confirmedSnapshotChanged = true
                continue
            }

            if gpuRecord.candidate == observed {
                gpuRecord.candidateCount += 1
            } else {
                gpuRecord.candidate = observed
                gpuRecord.candidateCount = 1
            }

            if gpuRecord.candidateCount >= confirmationCount {
                let previous = gpuRecord.confirmed.occupancy
                gpuRecord.confirmed = gpu
                gpuRecord.candidate = nil
                gpuRecord.candidateCount = 0
                events.append(.gpuChanged(server: snapshot.server, gpu: gpu, from: previous, to: observed))
                confirmedSnapshotChanged = true
            }

            nextGPURecords[gpu.uuid] = gpuRecord
            confirmedGPUs.append(gpuRecord.confirmed)
        }

        record.gpus = nextGPURecords
        if confirmedSnapshotChanged {
            record.lastSnapshot = ServerSnapshot(
                server: snapshot.server,
                gpus: confirmedGPUs,
                capturedAt: snapshot.capturedAt
            )
        }
        servers[snapshot.server.id] = record
        return StateUpdate(health: .online, stableSnapshot: record.lastSnapshot, events: events)
    }

    public func recordFailure(server: ServerConfig, failure: ProbeFailure) -> StateUpdate {
        var record = servers[server.id] ?? ServerRecord()
        let message = failure.localizedDescription

        let events: [MonitorEvent]
        let health: ServerHealth
        switch failure {
        case .connectivity:
            record.connectivityFailures += 1
            if record.connectivityOffline {
                events = []
                health = .offline(message: message)
            } else if record.connectivityFailures >= offlineFailureCount {
                record.connectivityOffline = true
                let shouldNotify = !record.recoveryEventPending
                record.recoveryEventPending = true
                events = shouldNotify ? [.serverOffline(server: server, message: message)] : []
                health = .offline(message: message)
            } else {
                events = []
                health = .degraded(
                    message: message,
                    consecutiveFailures: record.connectivityFailures
                )
            }
        case .hostKeySecurity:
            record.connectivityFailures = 0
            record.connectivityOffline = false
            events = []
            health = .security(message: message)
        case .authentication, .remoteCommand, .invalidResponse, .localLaunch:
            record.connectivityFailures = 0
            record.connectivityOffline = false
            events = []
            health = .warning(message: message)
        }

        servers[server.id] = record
        return StateUpdate(health: health, stableSnapshot: record.lastSnapshot, events: events)
    }

    private func rebaseline(_ record: inout ServerRecord, with snapshot: ServerSnapshot) {
        let uniqueGPUs = Self.uniqueGPUs(snapshot.gpus)
        record.lastSnapshot = ServerSnapshot(
            server: snapshot.server,
            gpus: uniqueGPUs,
            capturedAt: snapshot.capturedAt
        )
        record.gpus = uniqueGPUs.reduce(into: [:]) { records, gpu in
            records[gpu.uuid] = GPURecord(confirmed: gpu)
        }
    }

    private static func uniqueGPUs(_ gpus: [GPUSnapshot]) -> [GPUSnapshot] {
        var seenUUIDs: Set<String> = []
        return gpus.filter { seenUUIDs.insert($0.uuid).inserted }
    }
}
