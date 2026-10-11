import SwiftUI

@main
struct SO101RelayApp: App {
    @StateObject private var model = RelayModel()

    var body: some Scene {
        WindowGroup {
            RelayView()
                .environmentObject(model)
                #if DEBUG
                .task { await model.autoConnectFromEnvironment() }
                #endif
        }
    }
}
