import Foundation

enum DeviceIdentity {
    private static let userIdStorageKey = "videre.device.userId"

    static var userId: String {
        if let existing = UserDefaults.standard.string(forKey: userIdStorageKey),
           UUID(uuidString: existing) != nil {
            return existing
        }

        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: userIdStorageKey)
        return generated
    }
}
