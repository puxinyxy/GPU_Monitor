import AppKit
import GPUMonitorCore
import SwiftUI

struct GPUDisplayText: Equatable, Sendable {
    let occupancy: String
    let metrics: String
    let process: String?

    init(gpu: GPUSnapshot) {
        occupancy = gpu.occupancy == .free ? "空闲" : "占用"
        metrics = "\(gpu.utilizationPercent)% · \(Self.memory(gpu.usedMemoryMiB)) / \(Self.memory(gpu.totalMemoryMiB)) · \(gpu.temperatureCelsius)°C"
        process = gpu.processes.first.map { "\($0.name) · PID \($0.pid)" }
    }

    private static func memory(_ mebibytes: Int) -> String {
        guard mebibytes >= 1_024, mebibytes.isMultiple(of: 1_024) else {
            return "\(mebibytes) MiB"
        }
        return "\(mebibytes / 1_024) GiB"
    }
}

struct ServerHealthDisplay: Equatable, Sendable {
    let label: String
    let detail: String?

    init(_ health: ServerHealth) {
        switch health {
        case .unknown:
            label = "未知"
            detail = nil
        case .online:
            label = "在线"
            detail = nil
        case let .degraded(message, consecutiveFailures):
            label = "查询失败（\(consecutiveFailures)/3）"
            detail = message
        case let .warning(message):
            label = "查询警告"
            detail = message
        case let .security(message):
            label = "安全错误"
            detail = message
        case let .offline(message):
            label = "离线"
            detail = message
        }
    }
}

public struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let startupError = model.startupError {
                ErrorBanner(title: "配置错误", message: startupError)
            }

            if model.servers.isEmpty {
                ContentUnavailableView(
                    "没有可监控的服务器",
                    systemImage: "server.rack",
                    description: Text(AppModel.emptyConfigurationGuidance)
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(Array(model.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { Divider() }
                    ServerSection(
                        server: server,
                        snapshot: model.snapshots[server.id],
                        health: model.health[server.id] ?? .unknown
                    )
                }
            }

            Divider()
            StatusFooter(model: model)
        }
        .padding(14)
        .frame(width: 540)
    }
}

private struct ServerSection: View {
    let server: ServerConfig
    let snapshot: ServerSnapshot?
    let health: ServerHealth

    var body: some View {
        let display = ServerHealthDisplay(health)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("服务器 \(server.label)", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Text(display.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(healthColor)
            }

            if let snapshot, !snapshot.gpus.isEmpty {
                ForEach(snapshot.gpus.sorted(by: { $0.index < $1.index })) { gpu in
                    GPURow(gpu: gpu)
                }
            } else {
                Label(emptyStateText, systemImage: emptyStateImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            if let detail = display.detail {
                Text(short(detail))
                    .font(.caption)
                    .foregroundStyle(healthColor)
                    .lineLimit(2)
            }
        }
    }

    private var healthColor: Color {
        switch health {
        case .unknown: .secondary
        case .online: .green
        case .degraded: .yellow
        case .warning: .yellow
        case .security: .red
        case .offline: .red
        }
    }

    private var emptyStateText: String {
        switch health {
        case .unknown: "等待首次采样"
        case .online: "在线，但尚无 GPU 数据"
        case .degraded: "查询失败，尚无可保留的快照"
        case .warning: "查询警告，尚无可保留的快照"
        case .security: "SSH 安全校验失败，尚无可保留的快照"
        case .offline: "服务器离线，尚无可保留的快照"
        }
    }

    private var emptyStateImage: String {
        switch health {
        case .unknown: "questionmark.circle"
        case .online: "checkmark.circle"
        case .degraded: "exclamationmark.triangle"
        case .warning: "exclamationmark.triangle"
        case .security: "lock.trianglebadge.exclamationmark"
        case .offline: "wifi.slash"
        }
    }

    private func short(_ message: String) -> String {
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        guard firstLine.count > 140 else { return firstLine }
        return String(firstLine.prefix(137)) + "…"
    }
}

private struct GPURow: View {
    let gpu: GPUSnapshot

    var body: some View {
        let display = GPUDisplayText(gpu: gpu)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("GPU \(gpu.index)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 58, alignment: .leading)
            Text(display.occupancy)
                .foregroundStyle(gpu.occupancy == .free ? .green : .orange)
                .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.metrics)
                    .font(.system(.callout, design: .monospaced))
                if let process = display.process {
                    Text(process)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(notificationText, systemImage: notificationImage)
                    .foregroundStyle(notificationColor)
                Spacer()
                Text(lastUpdatedText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            if let recentError = model.recentErrorSummary {
                Label(recentError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label(model.isRefreshing ? "刷新中…" : "立即刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = model.lastUpdated else { return "上次更新：—" }
        return "上次更新：\(lastUpdated.formatted(date: .omitted, time: .standard))"
    }

    private var notificationText: String {
        switch model.notificationAuthorization {
        case .notDetermined: "通知：待授权"
        case .authorized: "通知：已授权"
        case .denied: "通知：未授权"
        case .provisional: "通知：临时授权"
        case .ephemeral: "通知：临时授权"
        case .error: "通知：状态错误"
        }
    }

    private var notificationImage: String {
        switch model.notificationAuthorization {
        case .authorized, .provisional, .ephemeral: "bell.fill"
        case .denied: "bell.slash.fill"
        case .notDetermined, .error: "bell.badge"
        }
    }

    private var notificationColor: Color {
        switch model.notificationAuthorization {
        case .authorized, .provisional, .ephemeral: .green
        case .denied, .error: .red
        case .notDetermined: .secondary
        }
    }
}

private struct ErrorBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.caption).textSelection(.enabled)
            }
        }
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
