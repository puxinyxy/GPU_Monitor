import Foundation

public struct ConfigurationStore: Sendable {
    public let configURL: URL

    public init(configURL: URL = AppPaths.live().configURL) {
        self.configURL = configURL
    }

    public func loadOrCreate() throws -> [ServerConfig] {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configURL.path) {
            let servers = try JSONDecoder().decode(
                [ServerConfig].self,
                from: Data(contentsOf: configURL)
            )
            let migrated = migrateLegacyEndpoints(in: servers)
            if migrated != servers {
                try write(migrated)
            }
            return migrated
        }

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let servers = approvedServers(identityFile: AppPaths.live().identityFileURL.path)
        try write(servers)
        return servers
    }

    private func migrateLegacyEndpoints(in servers: [ServerConfig]) -> [ServerConfig] {
        servers.map { server in
            guard server.id == "server-10165",
                  server.host == "122.207.108.8",
                  server.port == 10165 else {
                return server
            }
            return ServerConfig(
                id: server.id,
                label: server.label,
                host: "122.207.108.7",
                port: server.port,
                username: server.username,
                identityFile: server.identityFile
            )
        }
    }

    private func write(_ servers: [ServerConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: configURL, options: .atomic)
    }

    private func approvedServers(identityFile: String) -> [ServerConfig] {
        [
            ServerConfig(
                id: "server-10122",
                label: "10122",
                host: "122.207.108.8",
                port: 10122,
                username: "yanxiaoyang",
                identityFile: identityFile
            ),
            ServerConfig(
                id: "server-10165",
                label: "10165",
                host: "122.207.108.7",
                port: 10165,
                username: "yanxiaoyang",
                identityFile: identityFile
            ),
        ]
    }
}
