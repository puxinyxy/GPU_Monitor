public struct NotificationMessage: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct NotificationFormatter: Sendable {
    private enum MessageSlot {
        case free(serverID: String)
        case busy(serverID: String)
        case offline(server: ServerConfig)
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
            case let .serverOffline(server, _):
                slots.append(.offline(server: server))
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
            case let .offline(server):
                return NotificationMessage(
                    title: "服务器已离线",
                    body: "服务器 \(server.label) 已离线，请检查连接"
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
        guard let process = gpu.processes.min(by: processSortsBefore) else { return prefix }
        return "\(prefix)（\(process.name)，PID \(process.pid)）"
    }

    private static func processSortsBefore(_ lhs: GPUProcessInfo, _ rhs: GPUProcessInfo) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.usedMemoryMiB < rhs.usedMemoryMiB
    }
}
