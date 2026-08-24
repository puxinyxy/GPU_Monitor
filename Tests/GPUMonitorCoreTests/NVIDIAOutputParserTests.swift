import Foundation
import Testing
import GPUMonitorCore

private let parserSample = """
0, GPU-a, NVIDIA RTX 4090, 0, 120, 24564, 35
1, GPU-b, NVIDIA RTX 4090, 92, 18432, 24564, 71
__GPU_MONITOR_PROCESSES__
GPU-b, 12345, python, 18100
"""

@Test func parseAssociatesProcessesByGPUUUID() throws {
    let capturedAt = Date(timeIntervalSince1970: 123)
    let result = try NVIDIAOutputParser().parse(parserSample, server: .fixture, capturedAt: capturedAt)

    #expect(result.server == .fixture)
    #expect(result.capturedAt == capturedAt)
    #expect(result.gpus.count == 2)
    #expect(result.gpus[0].occupancy == .free)
    #expect(result.gpus[1].occupancy == .busy)
    #expect(result.gpus[1].processes == [.init(pid: 12345, name: "python", usedMemoryMiB: 18100)])
}

@Test func parseKeepsGPUOrderByIndex() throws {
    let sample = """
    2, GPU-c, GPU C, 4, 10, 100, 30
    0, GPU-a, GPU A, 1, 20, 200, 40
    1, GPU-b, GPU B, 2, 30, 300, 50
    __GPU_MONITOR_PROCESSES__
    """

    let result = try NVIDIAOutputParser().parse(sample, server: .fixture, capturedAt: .distantPast)

    #expect(result.gpus.map(\.index) == [0, 1, 2])
    #expect(result.gpus.map(\.uuid) == ["GPU-a", "GPU-b", "GPU-c"])
}

@Test func parseTrimsCSVFieldsAndReadsGPUValues() throws {
    let sample = " 3 , GPU-c , NVIDIA RTX 6000 , 47 , 2048 , 49152 , 62 \n__GPU_MONITOR_PROCESSES__\n"

    let gpu = try NVIDIAOutputParser().parse(sample, server: .fixture, capturedAt: .distantPast).gpus[0]

    #expect(gpu.index == 3)
    #expect(gpu.uuid == "GPU-c")
    #expect(gpu.name == "NVIDIA RTX 6000")
    #expect(gpu.utilizationPercent == 47)
    #expect(gpu.usedMemoryMiB == 2048)
    #expect(gpu.totalMemoryMiB == 49152)
    #expect(gpu.temperatureCelsius == 62)
}

@Test func parseTreatsEmptyAndNoRunningProcessesSectionsAsFree() throws {
    let empty = try NVIDIAOutputParser().parse(
        "0, GPU-a, GPU A, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n",
        server: .fixture,
        capturedAt: .distantPast
    )
    let noProcesses = try NVIDIAOutputParser().parse(
        "0, GPU-a, GPU A, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\nNo running processes found\n",
        server: .fixture,
        capturedAt: .distantPast
    )

    #expect(empty.gpus[0].processes.isEmpty)
    #expect(noProcesses.gpus[0].processes.isEmpty)
}

@Test func parseRejectsMissingMarker() {
    #expect(throws: (any Error).self) {
        try NVIDIAOutputParser().parse("0, GPU-a", server: .fixture, capturedAt: .distantPast)
    }
}

@Test func parseRejectsMalformedGPUAndProcessRows() {
    #expect(throws: (any Error).self) {
        try NVIDIAOutputParser().parse(
            "0, GPU-a, GPU A, not-a-number, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n",
            server: .fixture,
            capturedAt: .distantPast
        )
    }
    #expect(throws: (any Error).self) {
        try NVIDIAOutputParser().parse(
            "0, GPU-a, GPU A, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\nGPU-a, 12345, python\n",
            server: .fixture,
            capturedAt: .distantPast
        )
    }
}

@Test func parseRejectsOutputWithoutGPUs() {
    #expect(throws: (any Error).self) {
        try NVIDIAOutputParser().parse("__GPU_MONITOR_PROCESSES__\n", server: .fixture, capturedAt: .distantPast)
    }
}
