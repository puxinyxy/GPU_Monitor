import Foundation
import Testing
import GPUMonitorCore

@Test func loadOrCreateWritesTheTwoApprovedServersWithoutPasswords() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = ConfigurationStore(configURL: root.appending(path: "servers.json"))
    let servers = try store.loadOrCreate()

    #expect(servers.map(\.port) == [10222, 10165])
    #expect(Set(servers.map(\.host)) == ["122.207.108.8"])
    #expect(Set(servers.map(\.username)) == ["yanxiaoyang"])
    let data = try Data(contentsOf: root.appending(path: "servers.json"))
    #expect(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("password"))
}
