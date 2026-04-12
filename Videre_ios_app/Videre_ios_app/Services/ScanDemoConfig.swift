import Foundation

/// Hackathon demo toggles — flip `useHardcodedRoomName` off to rely on voice only.
enum ScanDemoConfig {

    /// When true, `Start scan` uses `hardcodedRoomName` (no mic required).
    static let useHardcodedRoomName = true
    static let hardcodedRoomName    = "Olin Library Hallway"
}
