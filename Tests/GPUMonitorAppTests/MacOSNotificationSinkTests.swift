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
    private var authorizationRequestCount = 0
    private var requests: [MacOSNotificationRequest] = []

    init(
        authorizationResult: Result<NotificationAuthorizationState, Error> = .success(.authorized),
        addFailures: Set<Int> = []
    ) {
        self.authorizationResult = authorizationResult
        self.addFailures = addFailures
    }

    func requestAuthorization() async throws -> NotificationAuthorizationState {
        authorizationRequestCount += 1
        return try authorizationResult.get()
    }

    func authorizationState() async -> NotificationAuthorizationState {
        (try? authorizationResult.get()) ?? .error
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
