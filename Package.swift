// swift-tools-version: 6.0
import PackageDescription

let developerFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let developerLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "GPUMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GPUMonitorCore", targets: ["GPUMonitorCore"]),
        .executable(name: "GPUMonitor", targets: ["GPUMonitorApp"]),
        .executable(name: "GPUMonitorCoreTestsRunner", targets: ["GPUMonitorCoreTestsRunner"]),
        .executable(name: "GPUMonitorAppTestsRunner", targets: ["GPUMonitorAppTestsRunner"]),
    ],
    targets: [
        .target(name: "GPUMonitorCore"),
        .target(name: "GPUMonitorNotifications", dependencies: ["GPUMonitorCore"]),
        .executableTarget(
            name: "GPUMonitorApp",
            dependencies: ["GPUMonitorCore", "GPUMonitorNotifications"]
        ),
        .executableTarget(
            name: "GPUMonitorCoreTestsRunner",
            dependencies: ["GPUMonitorCore"],
            path: "Tests/GPUMonitorCoreTests",
            swiftSettings: [.unsafeFlags(["-F", developerFrameworks])],
            linkerSettings: [.unsafeFlags([
                "-F", developerFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", developerFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", developerLibraries,
            ])]
        ),
        .executableTarget(
            name: "GPUMonitorAppTestsRunner",
            dependencies: ["GPUMonitorNotifications", "GPUMonitorCore"],
            path: "Tests/GPUMonitorAppTests",
            swiftSettings: [.unsafeFlags(["-F", developerFrameworks])],
            linkerSettings: [.unsafeFlags([
                "-F", developerFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", developerFrameworks,
                "-Xlinker", "-rpath", "-Xlinker", developerLibraries,
            ])]
        ),
    ],
    swiftLanguageModes: [.v5]
)
