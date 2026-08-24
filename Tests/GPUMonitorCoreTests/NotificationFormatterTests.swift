import Testing
import GPUMonitorCore

@Test func formatterAggregatesFreeGPUsOnTheSameServer() {
    let messages = NotificationFormatter().messages(for: [
        .gpuChanged(server: .server10122, gpu: .gpu(index: 2, .free), from: .busy, to: .free),
        .gpuChanged(server: .server10122, gpu: .gpu(index: 0, .free), from: .busy, to: .free),
    ])

    #expect(messages == [
        NotificationMessage(title: "GPU 已空闲", body: "服务器 10122：GPU 0、GPU 2 已空闲"),
    ])
}

@Test func formatterIncludesProcessForBusyGPU() {
    let messages = NotificationFormatter().messages(for: [
        .gpuChanged(
            server: .server10165,
            gpu: .busyGPU(index: 1, pid: 12345, name: "python"),
            from: .free,
            to: .busy
        ),
    ])

    #expect(messages == [
        NotificationMessage(
            title: "GPU 开始占用",
            body: "服务器 10165：GPU 1 开始占用（python，PID 12345）"
        ),
    ])
}

@Test func formatterProducesOneMessageForEachConnectivityEvent() {
    let messages = NotificationFormatter().messages(for: [
        .serverOffline(server: .server10122, message: "connection timed out"),
        .serverRecovered(server: .server10165),
        .serverOffline(server: .server10122, message: "host unreachable"),
    ])

    #expect(messages == [
        NotificationMessage(
            title: "服务器已离线",
            body: "服务器 10122 已离线，请检查连接"
        ),
        NotificationMessage(
            title: "服务器已恢复",
            body: "服务器 10165 已恢复在线"
        ),
        NotificationMessage(
            title: "服务器已离线",
            body: "服务器 10122 已离线，请检查连接"
        ),
    ])
}

@Test func formatterProducesNoMessagesForNoEvents() {
    #expect(NotificationFormatter().messages(for: []).isEmpty)
}

@Test func formatterKeepsFirstEventOrderWhileSeparatingFreeAndBusyGroups() {
    let messages = NotificationFormatter().messages(for: [
        .serverOffline(server: .server10122, message: "connection timed out"),
        .gpuChanged(
            server: .server10165,
            gpu: .busyGPU(index: 10, pid: 200, name: "train"),
            from: .free,
            to: .busy
        ),
        .gpuChanged(server: .server10165, gpu: .gpu(index: 2, .free), from: .busy, to: .free),
        .gpuChanged(
            server: .server10165,
            gpu: .busyGPU(index: 1, pid: 100, name: "python"),
            from: .free,
            to: .busy
        ),
    ])

    #expect(messages == [
        NotificationMessage(
            title: "服务器已离线",
            body: "服务器 10122 已离线，请检查连接"
        ),
        NotificationMessage(
            title: "GPU 开始占用",
            body: "服务器 10165：GPU 1 开始占用（python，PID 100）、GPU 10 开始占用（train，PID 200）"
        ),
        NotificationMessage(
            title: "GPU 已空闲",
            body: "服务器 10165：GPU 2 已空闲"
        ),
    ])
}

@Test func formatterSelectsBusyProcessWithLowestPID() {
    let gpu = GPUSnapshot(
        index: 3,
        uuid: "GPU-3",
        name: "NVIDIA RTX 4090",
        utilizationPercent: 90,
        usedMemoryMiB: 20000,
        totalMemoryMiB: 24564,
        temperatureCelsius: 70,
        processes: [
            GPUProcessInfo(pid: 900, name: "later", usedMemoryMiB: 10000),
            GPUProcessInfo(pid: 100, name: "first", usedMemoryMiB: 10000),
        ]
    )

    let messages = NotificationFormatter().messages(for: [
        .gpuChanged(server: .server10165, gpu: gpu, from: .free, to: .busy),
    ])

    #expect(messages == [
        NotificationMessage(
            title: "GPU 开始占用",
            body: "服务器 10165：GPU 3 开始占用（first，PID 100）"
        ),
    ])
}
