// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GPUMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GPUMonitorCore", targets: ["GPUMonitorCore"]),
        .executable(name: "GPUMonitor", targets: ["GPUMonitorApp"]),
    ],
    targets: [
        .target(name: "GPUMonitorCore"),
        .executableTarget(name: "GPUMonitorApp", dependencies: ["GPUMonitorCore"]),
        .testTarget(name: "GPUMonitorCoreTests", dependencies: ["GPUMonitorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
