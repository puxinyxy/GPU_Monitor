import Foundation

public struct ConfigurationStore: Sendable {
    public let configURL: URL

    public init(configURL: URL = AppPaths.live().configURL) {
        self.configURL = configURL
    }

    public func loadOrCreate() throws -> [ServerConfig] {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configURL.path) {
            return try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: configURL))
        }

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let servers = approvedServers(identityFile: AppPaths.live().identityFileURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(servers).write(to: configURL, options: .atomic)
        return servers
    }

    private func approvedServers(identityFile: String) -> [ServerConfig] {
        [
            ServerConfig(
                id: "server-10222",
                label: "10222",
                host: "122.207.108.8",
                port: 10222,
                username: "yanxiaoyang",
                identityFile: identityFile
            ),
            ServerConfig(
                id: "server-10165",
                label: "10165",
                host: "122.207.108.8",
                port: 10165,
                username: "yanxiaoyang",
                identityFile: identityFile
            ),
        ]
    }
}
