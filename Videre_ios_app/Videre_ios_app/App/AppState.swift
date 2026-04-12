//
//  AppState.swift
//  Videre_ios_app
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation

enum AppMode {
    case normal, crowd, silent
}

enum WalkState {
    case idle, walking, ended
}

class AppState: ObservableObject {

    // cane connection
    @Published var isConnected:      Bool      = false
    @Published var statusMessage:    String    = "Looking for cane..."

    // sensor data
    @Published var distanceCm:       Int       = 999
    @Published var zone:             Int       = 0
    @Published var battery:          Int       = 100
    @Published var crowdMode:        Bool      = false
    @Published var buzzerOn:         Bool      = true
    @Published var appMode:          AppMode   = .normal

    // gemini
    @Published var sceneDescription: String    = ""
    @Published var isAnalysing:      Bool      = false

    // walk session
    @Published var walkState:        WalkState = .idle
    @Published var sessionDistance:  Double    = 0
    @Published var sessionStart:     Date?     = nil
    @Published var obstacleCount:    Int       = 0

    // last button
    @Published var lastButton:       String    = ""
    @Published var lastButtonId:     String    = ""
    
    // LiDAR
    @Published var lidarEnabled:     Bool    = false
    @Published var lidarDistance:    Float   = 0
    @Published var lidarAvailable:   Bool    = false
}
