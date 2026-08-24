import Foundation

public struct AppPaths: Equatable, Sendable {
    public let applicationSupportDirectoryURL: URL
    public let configURL: URL
    public let knownHostsURL: URL
    public let identityFileURL: URL

    public static func live(fileManager: FileManager = .default) -> AppPaths {
        let applicationSupportDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/GPUMonitor")
        return AppPaths(
            applicationSupportDirectoryURL: applicationSupportDirectoryURL,
            configURL: applicationSupportDirectoryURL.appending(path: "servers.json"),
            knownHostsURL: applicationSupportDirectoryURL.appending(path: "known_hosts"),
            identityFileURL: fileManager.homeDirectoryForCurrentUser.appending(path: ".ssh/gpu_monitor_ed25519")
        )
    }
}
