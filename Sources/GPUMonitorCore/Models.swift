import Foundation

public struct ServerConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let host: String
    public let port: Int
    public let username: String
    public let identityFile: String
}

public enum GPUOccupancy: String, Codable, Sendable {
    case free
    case busy
}

public struct GPUProcessInfo: Equatable, Sendable {
    public let pid: Int
    public let name: String
    public let usedMemoryMiB: Int
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

    public var occupancy: GPUOccupancy { processes.isEmpty ? .free : .busy }
}

public struct ServerSnapshot: Equatable, Sendable {
    public let server: ServerConfig
    public let gpus: [GPUSnapshot]
    public let capturedAt: Date
}

public enum ServerHealth: Equatable, Sendable {
    case unknown
    case online
    case degraded(message: String, consecutiveFailures: Int)
    case offline(message: String)
}

public enum MonitorEvent: Equatable, Sendable {
    case gpuChanged(server: ServerConfig, gpu: GPUSnapshot, from: GPUOccupancy, to: GPUOccupancy)
    case serverOffline(server: ServerConfig, message: String)
    case serverRecovered(server: ServerConfig)
}
