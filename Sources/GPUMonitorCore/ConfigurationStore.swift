import Foundation

public struct ConfigurationStore: Sendable {
    public let configURL: URL

    public init(configURL: URL = AppPaths.live().configURL) {
        self.configURL = configURL
    }

    public func loadOrCreate() throws -> [ServerConfig] {
        let fileManager = FileManager.default
        let identityFile = AppPaths.live().identityFileURL.path
        if fileManager.fileExists(atPath: configURL.path) {
            let servers = try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: configURL))
            let migrated = migrateApprovedServers(in: servers, identityFile: identityFile)
            if migrated != servers { try write(migrated) }
            return migrated
        }
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let servers = approvedServers(identityFile: identityFile)
        try write(servers)
        return servers
    }

    private func migrateApprovedServers(in servers: [ServerConfig], identityFile: String) -> [ServerConfig] {
        var migrated = servers.map(migrateLegacyServer)
        for approved in approvedServers(identityFile: identityFile).suffix(2) {
            guard !migrated.contains(where: { $0.host == approved.host && $0.port == approved.port }) else { continue }
            migrated.append(ServerConfig(id: availableID(preferred: approved.id, in: migrated), label: approved.label, host: approved.host, port: approved.port, username: approved.username, identityFile: approved.identityFile))
        }
        return migrated
    }

    private func migrateLegacyServer(_ server: ServerConfig) -> ServerConfig {
        let host = server.id == "server-10165" && server.host == "122.207.108.8" && server.port == 10165 ? "122.207.108.7" : server.host
        let label: String
        switch (server.id, host, server.port, server.label) {
        case ("server-10122", "122.207.108.8", 10122, "10122"): label = "3090 · 10122"
        case ("server-10165", "122.207.108.7", 10165, "10165"): label = "3090 · 10165"
        default: label = server.label
        }
        return ServerConfig(id: server.id, label: label, host: host, port: server.port, username: server.username, identityFile: server.identityFile)
    }

    private func availableID(preferred: String, in servers: [ServerConfig]) -> String {
        let used = Set(servers.map(\.id))
        guard used.contains(preferred) else { return preferred }
        let migrated = "\(preferred)-migrated"
        guard used.contains(migrated) else { return migrated }
        var suffix = 2
        while used.contains("\(migrated)-\(suffix)") { suffix += 1 }
        return "\(migrated)-\(suffix)"
    }

    private func write(_ servers: [ServerConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: configURL, options: .atomic)
    }

    private func approvedServers(identityFile: String) -> [ServerConfig] {
        [
            ServerConfig(id: "server-10122", label: "3090 · 10122", host: "122.207.108.8", port: 10122, username: "yanxiaoyang", identityFile: identityFile),
            ServerConfig(id: "server-10165", label: "3090 · 10165", host: "122.207.108.7", port: 10165, username: "yanxiaoyang", identityFile: identityFile),
            ServerConfig(id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200, username: "yanxiaoyang", identityFile: identityFile),
            ServerConfig(id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000, username: "yanxiaoyang", identityFile: identityFile),
        ]
    }
}
