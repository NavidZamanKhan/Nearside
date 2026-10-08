import SwiftUI

@main
struct NearsideIOSApp: App {
    @StateObject private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        IOSNotificationManager.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            NearsideHomeView(appState: appState)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        if appState.isReceivingActive {
                            appState.startDiscoveryEngine()
                        }
                    case .background, .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
