import SwiftUI

@main
struct SO101WatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Always On (wrist down) is .inactive but the app is still frontmost and, with the
            // runtime session, still streaming. Only leaving the app counts; if the system does
            // suspend us, motion stops and the agent holds on motion_stale within 250 ms.
            model.lifecycle(active: phase != .background, foreground: phase == .active)
        }
    }
}
