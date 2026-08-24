import Foundation

public enum NVIDIAParseError: Error, Equatable, Sendable {
    case missingMarker
    case noGPUs
    case malformedGPU
    case malformedProcess
    case duplicateGPU
    case orphanProcess
}

public struct NVIDIAOutputParser: Sendable {
    public static let marker = "__GPU_MONITOR_PROCESSES__"

    public init() {}

    public func parse(_ output: String, server: ServerConfig, capturedAt: Date) throws -> ServerSnapshot {
        let lines = output.components(separatedBy: .newlines)
        let markerLines = lines.indices.filter { index in
            lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == Self.marker
        }
        guard markerLines.count == 1, let markerLine = markerLines.first else {
            throw NVIDIAParseError.missingMarker
        }
        let gpuSection = lines[..<markerLine].joined(separator: "\n")
        let processSection = lines[lines.index(after: markerLine)...].joined(separator: "\n")

        let processes = try parseProcesses(processSection)
        var seenUUIDs: Set<String> = []
        var seenIndices: Set<Int> = []
        var gpus: [GPUSnapshot] = []
        for line in gpuSection.split(whereSeparator: \.isNewline) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let gpu = try parseGPU(String(line), processesByUUID: processes)
            guard seenUUIDs.insert(gpu.uuid).inserted,
                  seenIndices.insert(gpu.index).inserted else {
                throw NVIDIAParseError.duplicateGPU
            }
            gpus.append(gpu)
        }

        guard !gpus.isEmpty else { throw NVIDIAParseError.noGPUs }
        guard Set(processes.keys).isSubset(of: seenUUIDs) else {
            throw NVIDIAParseError.orphanProcess
        }
        return ServerSnapshot(server: server, gpus: gpus.sorted { $0.index < $1.index }, capturedAt: capturedAt)
    }

    private func parseProcesses(_ section: String) throws -> [String: [GPUProcessInfo]] {
        let trimmedSection = section.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSection.isEmpty, trimmedSection != "No running processes found" else {
            return [:]
        }

        var processesByUUID: [String: [GPUProcessInfo]] = [:]
        for line in section.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let fields = csvFields(String(trimmedLine))
            guard fields.count == 4,
                  !fields[0].isEmpty,
                  !fields[2].isEmpty,
                  let pid = Int(fields[1]),
                  let usedMemoryMiB = Int(fields[3]) else {
                throw NVIDIAParseError.malformedProcess
            }

            processesByUUID[fields[0], default: []].append(
                GPUProcessInfo(pid: pid, name: fields[2], usedMemoryMiB: usedMemoryMiB)
            )
        }
        return processesByUUID
    }

    private func parseGPU(_ line: String, processesByUUID: [String: [GPUProcessInfo]]) throws -> GPUSnapshot {
        let fields = csvFields(line)
        guard fields.count == 7,
              !fields[1].isEmpty,
              !fields[2].isEmpty,
              let index = Int(fields[0]),
              let utilizationPercent = Int(fields[3]),
              let usedMemoryMiB = Int(fields[4]),
              let totalMemoryMiB = Int(fields[5]),
              let temperatureCelsius = Int(fields[6]) else {
            throw NVIDIAParseError.malformedGPU
        }

        return GPUSnapshot(
            index: index,
            uuid: fields[1],
            name: fields[2],
            utilizationPercent: utilizationPercent,
            usedMemoryMiB: usedMemoryMiB,
            totalMemoryMiB: totalMemoryMiB,
            temperatureCelsius: temperatureCelsius,
            processes: processesByUUID[fields[1]] ?? []
        )
    }

    private func csvFields(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
