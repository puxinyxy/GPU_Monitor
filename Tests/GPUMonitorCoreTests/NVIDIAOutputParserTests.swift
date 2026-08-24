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

@Test(arguments: [
    "0, , GPU A, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n",
    "0, GPU-a, , 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n",
])
func parseRejectsEmptyGPUIdentityFields(_ output: String) {
    #expect(throws: NVIDIAParseError.malformedGPU) {
        try NVIDIAOutputParser().parse(output, server: .fixture, capturedAt: .distantPast)
    }
}

@Test(arguments: [
    "0, GPU-a, GPU A, 0, 0, 100, 30\n1, GPU-a, GPU B, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n",
    "0, GPU-a, GPU A, 0, 0, 100, 30\n0, GPU-b, GPU B, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n",
])
func parseRejectsDuplicateGPUUUIDsAndIndices(_ output: String) {
    #expect(throws: NVIDIAParseError.duplicateGPU) {
        try NVIDIAOutputParser().parse(output, server: .fixture, capturedAt: .distantPast)
    }
}

@Test(arguments: [
    "GPU-a, 123, , 10",
    ", 123, python, 10",
])
func parseRejectsEmptyProcessIdentityFields(_ processRow: String) {
    let output = "0, GPU-a, GPU A, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\n\(processRow)\n"

    #expect(throws: NVIDIAParseError.malformedProcess) {
        try NVIDIAOutputParser().parse(output, server: .fixture, capturedAt: .distantPast)
    }
}

@Test func parseRejectsProcessesWhoseGPUUUIDIsAbsent() {
    let output = "0, GPU-a, GPU A, 0, 0, 100, 30\n__GPU_MONITOR_PROCESSES__\nGPU-orphan, 123, python, 10\n"

    #expect(throws: NVIDIAParseError.orphanProcess) {
        try NVIDIAOutputParser().parse(output, server: .fixture, capturedAt: .distantPast)
    }
}

@Test func parseTreatsMarkerSubstringInGPUNameAsOrdinaryData() throws {
    let output = "0, GPU-a, NVIDIA __GPU_MONITOR_PROCESSES__ Edition, 0, 0, 100, 30\n  __GPU_MONITOR_PROCESSES__  \n"

    let result = try NVIDIAOutputParser().parse(
        output,
        server: .fixture,
        capturedAt: .distantPast
    )

    #expect(result.gpus[0].name == "NVIDIA __GPU_MONITOR_PROCESSES__ Edition")
}

@Test func parseTreatsMarkerSubstringInProcessNameAsOrdinaryData() throws {
    let output = """
    0, GPU-a, GPU A, 0, 0, 100, 30
    __GPU_MONITOR_PROCESSES__
    GPU-a, 123, worker-__GPU_MONITOR_PROCESSES__-main, 10
    """

    let result = try NVIDIAOutputParser().parse(
        output,
        server: .fixture,
        capturedAt: .distantPast
    )

    #expect(result.gpus[0].processes[0].name == "worker-__GPU_MONITOR_PROCESSES__-main")
}

@Test func parseRequiresExactlyOneStandaloneMarkerLine() {
    let missing = "0, GPU-a, GPU A, 0, 0, 100, 30\n"
    let duplicate = """
    0, GPU-a, GPU A, 0, 0, 100, 30
    __GPU_MONITOR_PROCESSES__
    __GPU_MONITOR_PROCESSES__
    """

    #expect(throws: NVIDIAParseError.missingMarker) {
        try NVIDIAOutputParser().parse(missing, server: .fixture, capturedAt: .distantPast)
    }
    #expect(throws: NVIDIAParseError.missingMarker) {
        try NVIDIAOutputParser().parse(duplicate, server: .fixture, capturedAt: .distantPast)
    }
}
