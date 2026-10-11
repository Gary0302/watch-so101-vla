import HealthKit
import SwiftUI
import UIKit

/// The watch app runs an HKWorkoutSession only to stay alive with the wrist down. watchOS can
/// hand its HealthKit permission request to the companion; if the phone app doesn't take it,
/// the request is cancelled and the workout never starts.
final class RelayAppDelegate: NSObject, UIApplicationDelegate {
    private let healthStore = HKHealthStore()

    func applicationShouldRequestHealthAuthorization(_ application: UIApplication) {
        healthStore.handleAuthorizationForExtension { _, _ in }
    }
}

@main
struct SO101RelayApp: App {
    @UIApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
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
