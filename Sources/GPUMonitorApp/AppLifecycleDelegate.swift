import AppKit

@MainActor
public protocol AppLifecycleControlling: AnyObject {
    func stop() async
    func refreshNotificationAuthorization() async
}

extension AppModel: AppLifecycleControlling {}

@MainActor
public final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var model: (any AppLifecycleControlling)?
    private var terminationTask: Task<Void, Never>?
    private var terminationFinished = false

    public override init() {}

    public func configure(model: any AppLifecycleControlling) {
        guard terminationTask == nil, !terminationFinished else { return }
        self.model = model
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func requestTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard model != nil else { return .terminateNow }
        guard !terminationFinished else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { [self] in
            await model?.stop()
            terminationFinished = true
            terminationTask = nil
            reply(true)
        }
        return .terminateLater
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        applicationBecameActive()
    }

    func applicationBecameActive() {
        guard let model, !terminationFinished else { return }
        Task { await model.refreshNotificationAuthorization() }
    }
}
