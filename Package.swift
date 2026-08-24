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
    ],
    targets: [
        .target(name: "GPUMonitorCore"),
        .executableTarget(name: "GPUMonitorApp", dependencies: ["GPUMonitorCore"]),
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
    ],
    swiftLanguageModes: [.v5]
)
