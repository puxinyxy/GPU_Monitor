public struct NotificationMessage: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public protocol NotificationSink: Sendable {
    func requestAuthorization() async
    func send(events: [MonitorEvent]) async
}

public struct NotificationFormatter: Sendable {
    private enum MessageSlot {
        case free(serverID: String)
        case busy(serverID: String)
        case offline(server: ServerConfig, message: String)
        case recovered(server: ServerConfig)
    }

    public init() {}

    public func messages(for events: [MonitorEvent]) -> [NotificationMessage] {
        var serverLabels: [String: String] = [:]
        var freeGPUs: [String: [GPUSnapshot]] = [:]
        var busyGPUs: [String: [GPUSnapshot]] = [:]
        var freeSlots: Set<String> = []
        var busySlots: Set<String> = []
        var slots: [MessageSlot] = []

        for event in events {
            switch event {
            case let .gpuChanged(server, gpu, _, to):
                serverLabels[server.id] = server.label
                switch to {
                case .free:
                    if freeSlots.insert(server.id).inserted {
                        slots.append(.free(serverID: server.id))
                    }
                    freeGPUs[server.id, default: []].append(gpu)
                case .busy:
                    if busySlots.insert(server.id).inserted {
                        slots.append(.busy(serverID: server.id))
                    }
                    busyGPUs[server.id, default: []].append(gpu)
                }
            case let .serverOffline(server, message):
                slots.append(.offline(server: server, message: message))
            case let .serverRecovered(server):
                slots.append(.recovered(server: server))
            }
        }

        return slots.compactMap { slot in
            switch slot {
            case let .free(serverID):
                guard let serverLabel = serverLabels[serverID], let gpus = freeGPUs[serverID] else {
                    return nil
                }
                let gpuList = gpus.sorted(by: { $0.index < $1.index })
                    .map { "GPU \($0.index)" }
                    .joined(separator: "、")
                return NotificationMessage(
                    title: "GPU 已空闲",
                    body: "服务器 \(serverLabel)：\(gpuList) 已空闲"
                )
            case let .busy(serverID):
                guard let serverLabel = serverLabels[serverID], let gpus = busyGPUs[serverID] else {
                    return nil
                }
                let gpuList = gpus.sorted(by: { $0.index < $1.index })
                    .map(Self.busyDescription)
                    .joined(separator: "、")
                return NotificationMessage(
                    title: "GPU 开始占用",
                    body: "服务器 \(serverLabel)：\(gpuList)"
                )
            case let .offline(server, message):
                return NotificationMessage(
                    title: "服务器已离线",
                    body: "服务器 \(server.label) 已离线：\(message)"
                )
            case let .recovered(server):
                return NotificationMessage(
                    title: "服务器已恢复",
                    body: "服务器 \(server.label) 已恢复在线"
                )
            }
        }
    }

    private static func busyDescription(for gpu: GPUSnapshot) -> String {
        let prefix = "GPU \(gpu.index) 开始占用"
        guard let process = gpu.processes.first else { return prefix }
        return "\(prefix)（\(process.name)，PID \(process.pid)）"
    }
}
