import Foundation
import Testing
import GPUMonitorCore

@Test func loadOrCreateWritesTheTwoApprovedServersWithoutPasswords() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ConfigurationStore(configURL: root.appending(path: "servers.json"))
    let servers = try store.loadOrCreate()

    #expect(servers.map(\.port) == [10122, 10165])
    #expect(servers.map(\.id) == ["server-10122", "server-10165"])
    #expect(servers.map(\.label) == ["10122", "10165"])
    #expect(servers.map(\.host) == ["122.207.108.8", "122.207.108.7"])
    #expect(Set(servers.map(\.username)) == ["yanxiaoyang"])
    let data = try Data(contentsOf: root.appending(path: "servers.json"))
    #expect(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("password"))
}

@Test func loadOrCreateMigratesOnlyTheLegacySecondEndpointAndPersistsIt() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configURL = root.appending(path: "servers.json")
    let original = [
        ServerConfig(
            id: "server-10122",
            label: "10122",
            host: "122.207.108.8",
            port: 10122,
            username: "yanxiaoyang",
            identityFile: "/custom/first-key"
        ),
        ServerConfig(
            id: "server-10165",
            label: "second-custom-label",
            host: "122.207.108.8",
            port: 10165,
            username: "custom-user",
            identityFile: "/custom/second-key"
        ),
        ServerConfig(
            id: "custom-server",
            label: "leave-me-alone",
            host: "122.207.108.8",
            port: 10165,
            username: "custom-user",
            identityFile: "/custom/third-key"
        ),
    ]
    try JSONEncoder().encode(original).write(to: configURL, options: .atomic)

    let loaded = try ConfigurationStore(configURL: configURL).loadOrCreate()

    #expect(loaded[0] == original[0])
    #expect(loaded[1] == ServerConfig(
        id: "server-10165",
        label: "second-custom-label",
        host: "122.207.108.7",
        port: 10165,
        username: "custom-user",
        identityFile: "/custom/second-key"
    ))
    #expect(loaded[2] == original[2])
    let persisted = try JSONDecoder().decode([ServerConfig].self, from: Data(contentsOf: configURL))
    #expect(persisted == loaded)
}
