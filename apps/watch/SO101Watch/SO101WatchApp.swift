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
            model.lifecycle(active: phase == .active)
        }
    }
}
