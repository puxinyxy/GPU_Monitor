import Foundation

public struct ServerConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let host: String
    public let port: Int
    public let username: String
    public let identityFile: String

    public init(id: String, label: String, host: String, port: Int, username: String, identityFile: String) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
    }
}

public enum GPUOccupancy: String, Codable, Sendable {
    case free
    case busy
}

public struct GPUProcessInfo: Equatable, Sendable {
    public let pid: Int
    public let name: String
    public let usedMemoryMiB: Int

    public init(pid: Int, name: String, usedMemoryMiB: Int) {
        self.pid = pid
        self.name = name
        self.usedMemoryMiB = usedMemoryMiB
    }
}

public struct GPUSnapshot: Identifiable, Equatable, Sendable {
    public var id: String { uuid }
    public let index: Int
    public let uuid: String
    public let name: String
    public let utilizationPercent: Int
    public let usedMemoryMiB: Int
    public let totalMemoryMiB: Int
    public let temperatureCelsius: Int
    public let processes: [GPUProcessInfo]

    public init(
        index: Int,
        uuid: String,
        name: String,
        utilizationPercent: Int,
        usedMemoryMiB: Int,
        totalMemoryMiB: Int,
        temperatureCelsius: Int,
        processes: [GPUProcessInfo]
    ) {
        self.index = index
        self.uuid = uuid
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.usedMemoryMiB = usedMemoryMiB
        self.totalMemoryMiB = totalMemoryMiB
        self.temperatureCelsius = temperatureCelsius
        self.processes = processes
    }

    public var occupancy: GPUOccupancy { processes.isEmpty ? .free : .busy }
}

public struct ServerSnapshot: Equatable, Sendable {
    public let server: ServerConfig
    public let gpus: [GPUSnapshot]
    public let capturedAt: Date

    public init(server: ServerConfig, gpus: [GPUSnapshot], capturedAt: Date) {
        self.server = server
        self.gpus = gpus
        self.capturedAt = capturedAt
    }
}

public enum ServerHealth: Equatable, Sendable {
    case unknown
    case online
    case degraded(message: String, consecutiveFailures: Int)
    case warning(message: String)
    case security(message: String)
    case offline(message: String)
}

public enum MonitorEvent: Equatable, Sendable {
    case gpuChanged(server: ServerConfig, gpu: GPUSnapshot, from: GPUOccupancy, to: GPUOccupancy)
    case serverOffline(server: ServerConfig, message: String)
    case serverRecovered(server: ServerConfig)
}
