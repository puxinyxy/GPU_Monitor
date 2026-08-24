import GPUMonitorCore
import UserNotifications

actor MacOSNotificationSink: NotificationSink {
    private let center: UNUserNotificationCenter
    private let formatter: NotificationFormatter

    init(
        center: UNUserNotificationCenter = .current(),
        formatter: NotificationFormatter = NotificationFormatter()
    ) {
        self.center = center
        self.formatter = formatter
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func send(events: [MonitorEvent]) async {
        for message in formatter.messages(for: events) {
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}
