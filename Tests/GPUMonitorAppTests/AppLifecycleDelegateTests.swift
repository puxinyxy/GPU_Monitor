import AppKit
@testable import GPUMonitorUI
import Testing

@MainActor
private final class ControlledLifecycleModel: AppLifecycleControlling {
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopCalls = 0
    private(set) var authorizationRefreshes = 0

    func stop() async {
        stopCalls += 1
        await withCheckedContinuation { stopContinuation = $0 }
    }

    func refreshNotificationAuthorization() async {
        authorizationRefreshes += 1
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

@Test @MainActor
func terminationWaitsForStopAndCoalescesRepeatedRequests() async {
    let model = ControlledLifecycleModel()
    let delegate = AppLifecycleDelegate()
    delegate.configure(model: model)
    var replies: [Bool] = []

    let first = delegate.requestTermination { replies.append($0) }
    for _ in 0..<100 where model.stopCalls == 0 { await Task.yield() }
    let repeated = delegate.requestTermination { replies.append($0) }

    #expect(first == .terminateLater)
    #expect(repeated == .terminateLater)
    #expect(model.stopCalls == 1)
    #expect(replies.isEmpty)

    model.releaseStop()
    for _ in 0..<100 where replies.isEmpty { await Task.yield() }

    #expect(replies == [true, true])
    #expect(delegate.requestTermination { replies.append($0) } == .terminateNow)
    #expect(model.stopCalls == 1)
}

@Test @MainActor
func unconfiguredLifecycleDelegateTerminatesWithoutHanging() {
    let delegate = AppLifecycleDelegate()
    var replies: [Bool] = []

    #expect(delegate.requestTermination { replies.append($0) } == .terminateNow)
    #expect(replies.isEmpty)
}

@Test @MainActor
func applicationActivationRefreshesAuthorizationState() async {
    let model = ControlledLifecycleModel()
    let delegate = AppLifecycleDelegate()
    delegate.configure(model: model)

    delegate.applicationBecameActive()
    for _ in 0..<100 where model.authorizationRefreshes == 0 { await Task.yield() }

    #expect(model.authorizationRefreshes == 1)
}
