import GPUMonitorUI
import SwiftUI

@main
struct GPUMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycleDelegate
    @StateObject private var model: AppModel

    init() {
        let liveModel = AppModel.live()
        _model = StateObject(wrappedValue: liveModel)
        lifecycleDelegate.configure(model: liveModel)
        Task { @MainActor in
            await liveModel.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Label(model.menuTitle, systemImage: model.menuSystemImage)
                .foregroundStyle(menuColor)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuColor: Color {
        switch model.menuStatus {
        case .unknown: .secondary
        case .available: .green
        case .allBusy: .orange
        case .warning: .yellow
        case .security: .red
        case .offline: .red
        }
    }
}
