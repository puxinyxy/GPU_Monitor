import Foundation
import Darwin
import Testing
import GPUMonitorCore
import UserNotifications
@testable import GPUMonitorNotifications

private enum FakeCenterError: Error {
    case containsSensitiveDetails
}

private actor FakeNotificationCenter: UserNotificationCenterClient {
    private let authorizationResult: Result<NotificationAuthorizationState, Error>
    private let addFailures: Set<Int>
    private var currentState: NotificationAuthorizationState
    private var authorizationRequestCount = 0
    private var requests: [MacOSNotificationRequest] = []

    init(
        authorizationResult: Result<NotificationAuthorizationState, Error> = .success(.authorized),
        currentState: NotificationAuthorizationState? = nil,
        addFailures: Set<Int> = []
    ) {
        self.authorizationResult = authorizationResult
        self.currentState = currentState ?? ((try? authorizationResult.get()) ?? .error)
        self.addFailures = addFailures
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        authorizationRequestCount += 1
        return try authorizationResult.get()
    }

    func authorizationState() async -> NotificationAuthorizationState { currentState }

    func setCurrentState(_ state: NotificationAuthorizationState) {
        currentState = state
    }

    func add(_ request: MacOSNotificationRequest) async throws {
        let index = requests.count
        requests.append(request)
        if addFailures.contains(index) {
            throw FakeCenterError.containsSensitiveDetails
        }
    }

    var recordedRequests: [MacOSNotificationRequest] { requests }
    var requestCount: Int { authorizationRequestCount }
}

private actor FakeCompatibilityNotificationClient: CompatibilityNotificationClient {
    struct Message: Equatable, Sendable {
        let title: String
        let body: String
    }

    private let failures: Set<Int>
    private(set) var messages: [Message] = []

    init(failures: Set<Int> = []) {
        self.failures = failures
    }

    func add(title: String, body: String) async throws {
        let index = messages.count
        messages.append(.init(title: title, body: body))
        if failures.contains(index) { throw FakeCenterError.containsSensitiveDetails }
    }
}

private actor CancellingCompatibilityNotificationClient: CompatibilityNotificationClient {
    private(set) var callCount = 0

    func add(title: String, body: String) async throws {
        callCount += 1
        throw CancellationError()
    }
}

private actor TermResistantCompatibilityNotificationClient: CompatibilityNotificationClient {
    private let pidURL: URL

    init(pidURL: URL) {
        self.pidURL = pidURL
    }

    func add(title: String, body: String) async throws {
        _ = try await CommandRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 5",
                "gpu-monitor-compatibility-test",
                pidURL.path,
            ],
            timeout: .seconds(10)
        )
    }
}

private actor ControlledAuthorizationNotificationCenter: UserNotificationCenterClient {
    private let immediateStates: [Int: NotificationAuthorizationState]
    private var authorizationStateReadCount = 0
    private var stateContinuations: [
        Int: CheckedContinuation<NotificationAuthorizationState, Never>
    ] = [:]
    private var readCountWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var requests: [MacOSNotificationRequest] = []

    init(immediateStates: [Int: NotificationAuthorizationState] = [:]) {
        self.immediateStates = immediateStates
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        throw notificationsNotAllowedError()
    }

    func authorizationState() async -> NotificationAuthorizationState {
        let index = authorizationStateReadCount
        authorizationStateReadCount += 1
        resumeSatisfiedReadCountWaiters()
        if let state = immediateStates[index] { return state }
        return await withCheckedContinuation { continuation in
            stateContinuations[index] = continuation
        }
    }

    func add(_ request: MacOSNotificationRequest) async throws {
        requests.append(request)
    }

    func waitForAuthorizationStateReadCount(_ count: Int) async {
        guard authorizationStateReadCount < count else { return }
        await withCheckedContinuation { continuation in
            readCountWaiters.append((count, continuation))
        }
    }

    func resolveAuthorizationStateRead(
        _ index: Int,
        with state: NotificationAuthorizationState
    ) {
        stateContinuations.removeValue(forKey: index)?.resume(returning: state)
    }

    var stateReadCount: Int { authorizationStateReadCount }
    var recordedRequests: [MacOSNotificationRequest] { requests }

    private func resumeSatisfiedReadCountWaiters() {
        let satisfied = readCountWaiters.filter { $0.count <= authorizationStateReadCount }
        readCountWaiters.removeAll { $0.count <= authorizationStateReadCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

private actor ManualTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private let notificationTestServer = ServerConfig(
    id: "server-test",
    label: "Test Server",
    host: "example.invalid",
    port: 22,
    username: "tester",
    identityFile: "/private/test-key"
)

private func notificationsNotAllowedError() -> NSError {
    NSError(
        domain: UNErrorDomain,
        code: UNError.Code.notificationsNotAllowed.rawValue
    )
}

@Test func foregroundDelegateIsInstalledAndStronglyRetained() {
    weak var installedDelegate: ForegroundNotificationDelegate?
    var installation: ForegroundNotificationDelegateInstallation? =
        ForegroundNotificationDelegateInstallation { delegate in
            installedDelegate = delegate
        }

    #expect(installedDelegate != nil)
    var protocolDelegate: (any UNUserNotificationCenterDelegate)? = installedDelegate
    #expect(protocolDelegate != nil)

    protocolDelegate = nil
    installation = nil
    #expect(installation == nil)
    #expect(installedDelegate == nil)
}

@Test func foregroundDelegateImplementsCallbackAndCompletesVisiblePresentationOptions() {
    let delegate = ForegroundNotificationDelegate()
    let selector = #selector(
        UNUserNotificationCenterDelegate.userNotificationCenter(
            _:willPresent:withCompletionHandler:
        )
    )
    #expect(delegate.responds(to: selector))
    var completedOptions: UNNotificationPresentationOptions?

    delegate.completeForegroundPresentation { options in
        completedOptions = options
    }

    #expect(completedOptions == [.banner, .list, .sound])
}

@Test func macOSSinkContinuesAfterFailuresAndReturnsSanitizedResult() async {
    let center = FakeNotificationCenter(addFailures: [0, 2])
    let sink = MacOSNotificationSink(center: center)
    let server = ServerConfig(
        id: "server-1",
        label: "1",
        host: "example.invalid",
        port: 22,
        username: "tester",
        identityFile: "/private/key"
    )

    let result = await sink.send(events: [
        .serverRecovered(server: server),
        .serverOffline(server: server, message: "secret backend token"),
        .serverRecovered(server: server),
    ])

    #expect(result.attemptedCount == 3)
    #expect(result.deliveredCount == 1)
    #expect(result.failures == [
        NotificationDeliveryFailure(messageIndex: 0, reason: .schedulingFailed),
        NotificationDeliveryFailure(messageIndex: 2, reason: .schedulingFailed),
    ])
    let requests = await center.recordedRequests
    #expect(requests.count == 3)
    #expect(Set(requests.map(\.identifier)).count == 3)
    #expect(requests[1].body == "服务器 1 已离线，请检查连接")
    #expect(requests.allSatisfy { $0.playsDefaultSound })
}

@Test func macOSSinkReturnsExplicitAuthorizationStates() async {
    let deniedCenter = FakeNotificationCenter(authorizationResult: .success(.denied))
    let deniedSink = MacOSNotificationSink(center: deniedCenter)
    let failingCenter = FakeNotificationCenter(
        authorizationResult: .failure(FakeCenterError.containsSensitiveDetails)
    )
    let failingSink = MacOSNotificationSink(center: failingCenter)

    #expect(await deniedSink.requestAuthorization() == .denied)
    #expect(await deniedSink.authorizationState() == .denied)
    #expect(await deniedCenter.requestCount == 1)
    #expect(await failingSink.requestAuthorization() == .error)
    #expect(await failingSink.authorizationState() == .error)
}

@Test func notificationsNotAllowedActivatesCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .compatibility)
    let result = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(result.isSuccess)
    #expect(await center.recordedRequests.isEmpty)
    #expect(await compatibility.messages == [.init(
        title: "服务器已恢复",
        body: "服务器 Test Server 已恢复在线"
    )])
}

@Test func explicitDenialNeverActivatesCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .denied
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .denied)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])
    #expect(await compatibility.messages.isEmpty)
}

@Test func compatibilityReturnsToNativeWhenAuthorizationBecomesAvailable() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .compatibility)
    await center.setCurrentState(.authorized)
    #expect(await sink.authorizationState() == .authorized)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func compatibilityReportsPartialFailuresWithoutSensitiveDetails() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient(failures: [0, 2])
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    let result = await sink.send(events: [
        .serverRecovered(server: notificationTestServer),
        .serverOffline(server: notificationTestServer, message: "secret backend token"),
        .serverRecovered(server: notificationTestServer),
    ])

    #expect(result.attemptedCount == 3)
    #expect(result.deliveredCount == 1)
    #expect(result.failures.map(\.messageIndex) == [0, 2])
}

@Test func unrelatedAuthorizationErrorDoesNotActivateCompatibility() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(FakeCenterError.containsSensitiveDetails),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .error)
    #expect(await compatibility.messages.isEmpty)
}

@Test func compatibilityPersistsWhileNativeStateRemainsUnavailable() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let sink = MacOSNotificationSink(
        center: center,
        compatibility: FakeCompatibilityNotificationClient()
    )

    #expect(await sink.requestAuthorization() == .compatibility)
    #expect(await sink.authorizationState() == .compatibility)
    await center.setCurrentState(.error)
    #expect(await sink.authorizationState() == .compatibility)
}

@Test func laterExplicitDenialStopsCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    await center.setCurrentState(.denied)
    #expect(await sink.authorizationState() == .denied)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func compatibilityCancellationStopsBeforeStartingAnotherDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = CancellingCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    let result = await sink.send(events: [
        .serverRecovered(server: notificationTestServer),
        .serverOffline(server: notificationTestServer, message: "offline"),
    ])

    #expect(await compatibility.callCount == 1)
    #expect(result.attemptedCount == 2)
    #expect(result.deliveredCount == 0)
    #expect(result.failures.map(\.messageIndex) == [0, 1])
}

@Test func compatibilitySendRevalidatesNativeDenialWithoutAStatusRefresh() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    #expect(await sink.requestAuthorization() == .compatibility)

    await center.setCurrentState(.denied)
    let result = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(result.isSuccess)
    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func staleAuthorizationStateReadCannotRestoreCompatibilityOverDenial() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [0: .notDetermined])
    let sink = MacOSNotificationSink(
        center: center,
        compatibility: FakeCompatibilityNotificationClient()
    )
    #expect(await sink.requestAuthorization() == .compatibility)

    let olderRead = Task { await sink.authorizationState() }
    await center.waitForAuthorizationStateReadCount(2)
    let newerRead = Task { await sink.authorizationState() }
    await center.waitForAuthorizationStateReadCount(3)

    await center.resolveAuthorizationStateRead(2, with: .denied)
    #expect(await newerRead.value == .denied)
    await center.resolveAuthorizationStateRead(1, with: .notDetermined)
    #expect(await olderRead.value == .denied)
}

@Test func staleAuthorizationRequestCannotRestoreCompatibilityOverDenial() async {
    let center = ControlledAuthorizationNotificationCenter()
    let sink = MacOSNotificationSink(
        center: center,
        compatibility: FakeCompatibilityNotificationClient()
    )

    let olderRequest = Task { await sink.requestAuthorization() }
    await center.waitForAuthorizationStateReadCount(1)
    let newerRead = Task { await sink.authorizationState() }
    await center.waitForAuthorizationStateReadCount(2)

    await center.resolveAuthorizationStateRead(1, with: .denied)
    #expect(await newerRead.value == .denied)
    await center.resolveAuthorizationStateRead(0, with: .notDetermined)
    #expect(await olderRequest.value == .denied)
}

@Test func newerNotDeterminedReadDoesNotDiscardOlderExactErrorEvidence() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [
        1: .notDetermined,
        2: .notDetermined,
    ])
    let sink = MacOSNotificationSink(
        center: center,
        compatibility: FakeCompatibilityNotificationClient()
    )

    let exactErrorRequest = Task { await sink.requestAuthorization() }
    await center.waitForAuthorizationStateReadCount(1)
    #expect(await sink.authorizationState() == .notDetermined)

    await center.resolveAuthorizationStateRead(0, with: .notDetermined)
    #expect(await exactErrorRequest.value == .compatibility)
    #expect(await sink.authorizationState() == .compatibility)
}

@Test func newerErrorReadDoesNotDiscardOlderExactErrorEvidence() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [
        1: .error,
        2: .error,
    ])
    let sink = MacOSNotificationSink(
        center: center,
        compatibility: FakeCompatibilityNotificationClient()
    )

    let exactErrorRequest = Task { await sink.requestAuthorization() }
    await center.waitForAuthorizationStateReadCount(1)
    #expect(await sink.authorizationState() == .error)

    await center.resolveAuthorizationStateRead(0, with: .notDetermined)
    #expect(await exactErrorRequest.value == .compatibility)
    #expect(await sink.authorizationState() == .compatibility)
}

@Test func newerDenialRemainsAuthoritativeOverOlderExactErrorEvidence() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [
        1: .denied,
        2: .denied,
    ])
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    let exactErrorRequest = Task { await sink.requestAuthorization() }
    await center.waitForAuthorizationStateReadCount(1)
    #expect(await sink.authorizationState() == .denied)

    await center.resolveAuthorizationStateRead(0, with: .notDetermined)
    #expect(await exactErrorRequest.value == .denied)
    #expect(await sink.authorizationState() == .denied)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])
    #expect(await compatibility.messages.isEmpty)
}

@Test func compatibilityRouteStaleFromNewerDenialNeverLaunchesCompatibility() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [0: .notDetermined])
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    #expect(await sink.requestAuthorization() == .compatibility)

    let delivery = Task {
        await sink.send(events: [.serverRecovered(server: notificationTestServer)])
    }
    await center.waitForAuthorizationStateReadCount(2)
    let denialRefresh = Task { await sink.authorizationState() }
    await center.waitForAuthorizationStateReadCount(3)

    await center.resolveAuthorizationStateRead(2, with: .denied)
    #expect(await denialRefresh.value == .denied)
    await center.resolveAuthorizationStateRead(1, with: .notDetermined)
    _ = await delivery.value

    #expect(await compatibility.messages.isEmpty)
}

@Test func compatibilityRouteStaleFromNewerInconclusiveReadRetriesCompatibility() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [
        0: .notDetermined,
        3: .notDetermined,
    ])
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    #expect(await sink.requestAuthorization() == .compatibility)

    let delivery = Task {
        await sink.send(events: [.serverRecovered(server: notificationTestServer)])
    }
    await center.waitForAuthorizationStateReadCount(2)
    let inconclusiveRefresh = Task { await sink.authorizationState() }
    await center.waitForAuthorizationStateReadCount(3)

    await center.resolveAuthorizationStateRead(2, with: .notDetermined)
    #expect(await inconclusiveRefresh.value == .compatibility)
    await center.resolveAuthorizationStateRead(1, with: .notDetermined)
    let result = await delivery.value

    #expect(result.isSuccess)
    #expect(await center.recordedRequests.isEmpty)
    #expect(await compatibility.messages.count == 1)
    #expect(await center.stateReadCount == 4)
}

@Test func cancellationDuringStaleCompatibilityRouteRetryAccountsForExactSuffix() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [0: .notDetermined])
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    #expect(await sink.requestAuthorization() == .compatibility)

    let delivery = Task {
        await sink.send(events: [
            .serverRecovered(server: notificationTestServer),
            .serverOffline(server: notificationTestServer, message: "offline"),
            .serverRecovered(server: notificationTestServer),
        ])
    }
    await center.waitForAuthorizationStateReadCount(2)
    let inconclusiveRefresh = Task { await sink.authorizationState() }
    await center.waitForAuthorizationStateReadCount(3)
    await center.resolveAuthorizationStateRead(2, with: .notDetermined)
    #expect(await inconclusiveRefresh.value == .compatibility)
    await center.resolveAuthorizationStateRead(1, with: .notDetermined)

    await center.waitForAuthorizationStateReadCount(4)
    delivery.cancel()
    await center.resolveAuthorizationStateRead(3, with: .notDetermined)
    let result = await delivery.value

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.isEmpty)
    #expect(result.attemptedCount == 3)
    #expect(result.deliveredCount == 0)
    #expect(result.failures.map(\.messageIndex) == [0, 1, 2])
}

@Test func nativeCompatibilityStateCannotActivateCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .success(.compatibility),
        currentState: .compatibility
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.requestAuthorization() == .error)
    #expect(await sink.authorizationState() == .error)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func nativeNotDeterminedStateDoesNotActivateCompatibilityDelivery() async {
    let center = FakeNotificationCenter(currentState: .notDetermined)
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)

    #expect(await sink.authorizationState() == .notDetermined)
    _ = await sink.send(events: [.serverRecovered(server: notificationTestServer)])

    #expect(await compatibility.messages.isEmpty)
    #expect(await center.recordedRequests.count == 1)
}

@Test func cancellationBeforeSendStartsSkipsAllCompatibilityDelivery() async {
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    let gate = ManualTestGate()
    _ = await sink.requestAuthorization()

    let delivery = Task {
        await gate.wait()
        return await sink.send(events: [
            .serverRecovered(server: notificationTestServer),
            .serverOffline(server: notificationTestServer, message: "offline"),
        ])
    }
    delivery.cancel()
    await gate.open()
    let result = await delivery.value

    #expect(await compatibility.messages.isEmpty)
    #expect(result.attemptedCount == 2)
    #expect(result.deliveredCount == 0)
    #expect(result.failures.map(\.messageIndex) == [0, 1])
}

@Test func cancellationDuringCompatibilityRevalidationAccountsForTheSuffixOnce() async {
    let center = ControlledAuthorizationNotificationCenter(immediateStates: [0: .notDetermined])
    let compatibility = FakeCompatibilityNotificationClient()
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    _ = await sink.requestAuthorization()

    let delivery = Task {
        await sink.send(events: [
            .serverRecovered(server: notificationTestServer),
            .serverOffline(server: notificationTestServer, message: "offline"),
        ])
    }
    await center.waitForAuthorizationStateReadCount(2)
    delivery.cancel()
    await center.resolveAuthorizationStateRead(1, with: .notDetermined)
    let result = await delivery.value

    #expect(await compatibility.messages.isEmpty)
    #expect(result.attemptedCount == 2)
    #expect(result.deliveredCount == 0)
    #expect(result.failures.map(\.messageIndex) == [0, 1])
}

@Test func compatibilityDrainForceKillsAndReapsActiveCommandBeforeReturning() async throws {
    let pidURL = FileManager.default.temporaryDirectory
        .appending(path: "gpu-monitor-compatibility-drain-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidURL) }
    let center = FakeNotificationCenter(
        authorizationResult: .failure(notificationsNotAllowedError()),
        currentState: .notDetermined
    )
    let compatibility = TermResistantCompatibilityNotificationClient(pidURL: pidURL)
    let sink = MacOSNotificationSink(center: center, compatibility: compatibility)
    #expect(await sink.requestAuthorization() == .compatibility)
    let delivery = Task {
        await sink.send(events: [.serverRecovered(server: notificationTestServer)])
    }

    for _ in 0..<1_000 where !FileManager.default.fileExists(atPath: pidURL.path) {
        try await ContinuousClock().sleep(for: .milliseconds(1))
    }
    #expect(FileManager.default.fileExists(atPath: pidURL.path))

    await sink.cancelAndDrainCompatibilityCommands()

    let pidText = try String(contentsOf: pidURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(pid_t(pidText))
    errno = 0
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
    let result = await delivery.value
    #expect(result.deliveredCount == 0)
    #expect(result.failures.map(\.messageIndex) == [0])
}
