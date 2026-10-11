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
            // Always On (wrist down) is .inactive; with the workout running the app can even go
            // .background and keep streaming. WatchModel decides what counts as "left the app".
            model.lifecycle(active: phase != .background, foreground: phase == .active)
        }
    }
}
