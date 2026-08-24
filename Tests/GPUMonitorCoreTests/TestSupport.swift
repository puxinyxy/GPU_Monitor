import Foundation
import XCTest
@testable import GPUMonitorCore

extension ServerConfig {
    static let fixture = ServerConfig(
        id: "server-fixture", label: "fixture", host: "127.0.0.1", port: 22,
        username: "tester", identityFile: "/tmp/gpu_monitor_ed25519"
    )

    static let server10222 = ServerConfig(
        id: "server-10222", label: "10222", host: "122.207.108.8", port: 10222,
        username: "yanxiaoyang", identityFile: "/tmp/gpu_monitor_ed25519"
    )
    static let server10165 = ServerConfig(
        id: "server-10165", label: "10165", host: "122.207.108.8", port: 10165,
        username: "yanxiaoyang", identityFile: "/tmp/gpu_monitor_ed25519"
    )
}

extension ServerSnapshot {
    static func snapshot(_ occupancy: GPUOccupancy, server: ServerConfig = .fixture) -> ServerSnapshot {
        ServerSnapshot(server: server, gpus: [.gpu(index: 0, occupancy)], capturedAt: .distantPast)
    }
}

extension GPUSnapshot {
    static func gpu(index: Int, _ occupancy: GPUOccupancy) -> GPUSnapshot {
        GPUSnapshot(
            index: index, uuid: "GPU-\(index)", name: "NVIDIA RTX 4090", utilizationPercent: 0,
            usedMemoryMiB: 120, totalMemoryMiB: 24564, temperatureCelsius: 35,
            processes: occupancy == .free ? [] : [.init(pid: 12345, name: "python", usedMemoryMiB: 18100)]
        )
    }

    static func busyGPU(index: Int, pid: Int, name: String) -> GPUSnapshot {
        GPUSnapshot(
            index: index, uuid: "GPU-\(index)", name: "NVIDIA RTX 4090", utilizationPercent: 92,
            usedMemoryMiB: 18432, totalMemoryMiB: 24564, temperatureCelsius: 71,
            processes: [.init(pid: pid, name: name, usedMemoryMiB: 18100)]
        )
    }
}

let validNVIDIAOutput = """
0, GPU-a, NVIDIA RTX 4090, 0, 120, 24564, 35
__GPU_MONITOR_PROCESSES__
"""

actor RecordingRunner {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    let stdout: String
    private var calls: [Call] = []

    init(stdout: String) {
        self.stdout = stdout
    }

    var onlyCall: Call {
        precondition(calls.count == 1)
        return calls[0]
    }

    func record(executable: String, arguments: [String]) {
        calls.append(Call(executable: executable, arguments: arguments))
    }
}

actor ControlledProbe {
    let results: [String: Result<ServerSnapshot, Error>]
    let delay: Duration

    init(results: [String: Result<ServerSnapshot, Error>], delay: Duration) {
        self.results = results
        self.delay = delay
    }
}

enum TestError: Error {
    case unreachable
}

func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure @escaping () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {}
}
