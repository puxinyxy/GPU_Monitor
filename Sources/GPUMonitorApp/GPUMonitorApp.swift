import SwiftUI

@main
struct GPUMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("GPU —/—", systemImage: "cpu") {
            Text("GPU Monitor is starting…")
        }
    }
}
