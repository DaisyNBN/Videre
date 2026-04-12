import SwiftUI

@main
struct VidereApp: App {

    @StateObject private var bleManager   = BLEManager()
    @StateObject private var lidarService = LiDARService.shared
    @StateObject private var scanService  = ScanService.shared
    @StateObject private var appState     = AppState()
    @StateObject private var navigationContext = NavigationContextService()

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        _ = VoiceService.shared
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(bleManager)
                .environmentObject(lidarService)
                .environmentObject(scanService)
                .environmentObject(appState)
                .environmentObject(navigationContext)
                .onAppear {
                    LiDARService.shared.configure(
                        appState: appState)
                    navigationContext.start()
                }
        }
    }
}
