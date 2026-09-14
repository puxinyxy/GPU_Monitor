import Foundation
import Testing
import GPUMonitorCore

private func makeConfigurationRoot() throws -> (root: URL, config: URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, root.appending(path: "servers.json"))
}

private func writeServers(_ servers: [ServerConfig], to url: URL) throws {
    try JSONEncoder().encode(servers).write(to: url, options: .atomic)
}

@Test func loadOrCreateWritesFourApprovedServersWithoutPasswords() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let identity = AppPaths.live().identityFileURL.path
    let servers = try ConfigurationStore(configURL: paths.config).loadOrCreate()
    #expect(servers == [
        ServerConfig(id: "server-10122", label: "3090 · 10122", host: "122.207.108.8", port: 10122, username: "yanxiaoyang", identityFile: identity),
        ServerConfig(id: "server-10165", label: "3090 · 10165", host: "122.207.108.7", port: 10165, username: "yanxiaoyang", identityFile: identity),
        ServerConfig(id: "server-a100-18200", label: "A100 · 18200", host: "js2.blockelite.cn", port: 18200, username: "yanxiaoyang", identityFile: identity),
        ServerConfig(id: "server-a100-13000", label: "A100 · 13000", host: "js2.blockelite.cn", port: 13000, username: "yanxiaoyang", identityFile: identity),
    ])
    let text = String(decoding: try Data(contentsOf: paths.config), as: UTF8.self)
    #expect(!text.localizedCaseInsensitiveContains("password"))
}

@Test func standardTwoServerConfigurationMigratesToApprovedFourServerOrder() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try writeServers([
        ServerConfig(id: "server-10122", label: "10122", host: "122.207.108.8", port: 10122, username: "first-user", identityFile: "/custom/first-key"),
        ServerConfig(id: "server-10165", label: "10165", host: "122.207.108.7", port: 10165, username: "second-user", identityFile: "/custom/second-key"),
    ], to: paths.config)
    let loaded = try ConfigurationStore(configURL: paths.config).loadOrCreate()
    #expect(loaded.map(\.id) == ["server-10122", "server-10165", "server-a100-18200", "server-a100-13000"])
    #expect(loaded.map(\.label) == ["3090 · 10122", "3090 · 10165", "A100 · 18200", "A100 · 13000"])
    #expect(loaded.map { "\($0.host):\($0.port)" } == ["122.207.108.8:10122", "122.207.108.7:10165", "js2.blockelite.cn:18200", "js2.blockelite.cn:13000"])
    #expect(loaded[0].username == "first-user")
    #expect(loaded[0].identityFile == "/custom/first-key")
    #expect(loaded[1].username == "second-user")
    #expect(loaded[1].identityFile == "/custom/second-key")
    let persisted = try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: paths.config))
    #expect(persisted == loaded)
}

@Test func migrationPreservesCustomRecordsAndDoesNotDuplicateAnExistingA100Endpoint() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let original = [
        ServerConfig(id: "server-10122", label: "实验室主机", host: "122.207.108.8", port: 10122, username: "custom-user", identityFile: "/custom/first-key"),
        ServerConfig(id: "custom-a100", label: "我的 A100", host: "js2.blockelite.cn", port: 18200, username: "custom-user", identityFile: "/custom/a100-key"),
        ServerConfig(id: "custom-server", label: "保留我", host: "example.invalid", port: 2200, username: "other-user", identityFile: "/custom/other-key"),
        ServerConfig(id: "server-10165", label: "第二台自定义", host: "122.207.108.8", port: 10165, username: "second-user", identityFile: "/custom/second-key"),
    ]
    try writeServers(original, to: paths.config)
    let loaded = try ConfigurationStore(configURL: paths.config).loadOrCreate()
    #expect(loaded[0] == original[0])
    #expect(loaded[1] == original[1])
    #expect(loaded[2] == original[2])
    #expect(loaded[3].host == "122.207.108.7")
    #expect(loaded[3].label == "第二台自定义")
    #expect(loaded.filter { $0.host == "js2.blockelite.cn" && $0.port == 18200 }.count == 1)
    #expect(loaded.last?.id == "server-a100-13000")
}

@Test func occupiedApprovedIDUsesStableFallbackAndSecondLoadDoesNotRewrite() throws {
    let paths = try makeConfigurationRoot()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try writeServers([
        ServerConfig(id: "server-a100-18200", label: "占用批准 ID", host: "other.invalid", port: 22, username: "other", identityFile: "/other/key"),
        ServerConfig(id: "server-a100-18200-migrated", label: "占用首个回退 ID", host: "other.invalid", port: 23, username: "other", identityFile: "/other/key"),
    ], to: paths.config)
    let store = ConfigurationStore(configURL: paths.config)
    let first = try store.loadOrCreate()
    #expect(first.first { $0.host == "js2.blockelite.cn" && $0.port == 18200 }?.id == "server-a100-18200-migrated-2")
    #expect(first.filter { $0.host == "js2.blockelite.cn" && $0.port == 18200 }.count == 1)
    let sentinel = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: paths.config.path)
    let bytesBefore = try Data(contentsOf: paths.config)
    let second = try store.loadOrCreate()
    let attributes = try FileManager.default.attributesOfItem(atPath: paths.config.path)
    let bytesAfter = try Data(contentsOf: paths.config)
    #expect(second == first)
    #expect(bytesAfter == bytesBefore)
    #expect(attributes[.modificationDate] as? Date == sentinel)
}
