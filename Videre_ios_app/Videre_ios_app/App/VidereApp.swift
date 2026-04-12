//
//  VidereApp.swift
//  Videre_ios_app
//
//  Created by Ngan Nguyen on 4/12/26.
//

import SwiftUI

@main
struct VidereApp: App {

    @StateObject private var bleManager  = BLEManager()
    @StateObject private var appState    = AppState()
    @StateObject private var lidarService = LiDARService.shared

    init() {
        UIApplication.shared.isIdleTimerDisabled = true
        _ = VoiceService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(appState)
                .environmentObject(lidarService)
                .onAppear {
                    LiDARService.shared.configure(appState: appState)
                    // no need to call start() here — LiDARService starts itself
                }        }
    }
}
