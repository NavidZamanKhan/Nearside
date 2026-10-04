import SwiftUI

@main
struct NearsideIOSApp: App {
    @StateObject private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NearsideHomeView(appState: appState)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        // Restore discovery and receiver if active
                        if appState.isReceivingActive {
                            appState.startDiscoveryEngine()
                        }
                    case .background:
                        break
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
