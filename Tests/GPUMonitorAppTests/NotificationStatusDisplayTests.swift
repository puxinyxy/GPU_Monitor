import GPUMonitorCore
import Testing
@testable import GPUMonitorUI

@Test func compatibilityNotificationStatusIsAvailableButVisuallyDistinct() {
    let display = NotificationStatusDisplay(.compatibility)

    #expect(display.text == "通知：兼容模式")
    #expect(display.systemImage == "bell.fill")
    #expect(display.tone == .compatibility)
}

@Test func existingNotificationStatusMappingsRemainStable() {
    let cases: [(NotificationAuthorizationState, String, String, NotificationStatusTone)] = [
        (.notDetermined, "通知：待授权", "bell.badge", .secondary),
        (.authorized, "通知：已授权", "bell.fill", .success),
        (.denied, "通知：未授权", "bell.slash.fill", .failure),
        (.provisional, "通知：临时授权", "bell.fill", .success),
        (.ephemeral, "通知：临时授权", "bell.fill", .success),
        (.error, "通知：状态错误", "bell.badge", .failure),
    ]

    for (state, text, image, tone) in cases {
        let display = NotificationStatusDisplay(state)
        #expect(display.text == text)
        #expect(display.systemImage == image)
        #expect(display.tone == tone)
    }
}
