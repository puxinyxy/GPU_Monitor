import Foundation
import XCTest
@testable import GPUMonitorCore

final class ConfigurationStoreTests: XCTestCase {
    func testLoadOrCreateWritesTheTwoApprovedServersWithoutPasswords() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ConfigurationStore(configURL: root.appending(path: "servers.json"))
        let servers = try store.loadOrCreate()

        XCTAssertEqual(servers.map(\.port), [10222, 10165])
        XCTAssertEqual(Set(servers.map(\.host)), ["122.207.108.8"])
        XCTAssertEqual(Set(servers.map(\.username)), ["yanxiaoyang"])
        let data = try Data(contentsOf: root.appending(path: "servers.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("password"))
    }
}
