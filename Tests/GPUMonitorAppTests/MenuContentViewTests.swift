import GPUMonitorCore
import SwiftUI
import Testing
@testable import GPUMonitorUI

@Test @MainActor
func fourServerListUsesABoundedVerticalScrollContainer() {
    let servers = [10122, 10165, 18200, 13000].map { port in
        ServerConfig(
            id: "server-\(port)", label: "server \(port)", host: "example.invalid",
            port: port, username: "tester", identityFile: "/tmp/test-key"
        )
    }
    let list = ScrollableServerList(servers: servers, snapshots: [:], health: [:])
    let bodyType = String(reflecting: type(of: list.body))

    #expect(bodyType.contains("SwiftUI.ScrollView"))
    #expect(MenuLayout.serverListMaxHeight == 520)
    #expect(MenuLayout.serverListMaxHeight < 600)
}
