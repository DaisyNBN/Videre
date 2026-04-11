//
//  BLEManager.swift
//  
//
//  Created by Ngan Nguyen on 4/11/26.
//

import Foundation
import CoreBluetooth

// ── HM-10 identifiers ─────────────────────────────────
// share these with your vibecoder — they need them for nothing
// but good to document in api-contracts/
let CANE_SERVICE_UUID        = CBUUID(string: "FFE0")
let CANE_CHARACTERISTIC_UUID = CBUUID(string: "FFE1")

class BLEManager: NSObject, ObservableObject {

    // shared state — every view reads from this
    var appState: AppState

    // CoreBluetooth internals
    private var central:        CBCentralManager!
    private var peripheral:     CBPeripheral?
    private var dataChar:       CBCharacteristic?

    // buffer for incoming BLE bytes
    // HM-10 sometimes splits one JSON across multiple packets
    private var incomingBuffer = ""

    init(appState: AppState) {
        self.appState = appState
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // ── Send settings to cane ──────────────────────────
    func sendSettings(_ dict: [String: Any]) {
        guard
            let char  = dataChar,
            let peri  = peripheral,
            let data  = try? JSONSerialization.data(withJSONObject: dict),
            let str   = String(data: data, encoding: .utf8)
        else { return }

        // HM-10 sends/receives as plain string
        let bytes = Array(str.utf8)
        let chunk = Data(bytes)
        peri.writeValue(chunk, for: char, type: .withoutResponse)
    }
}

// ── Central manager events ────────────────────────────
extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("BLE on — scanning for cane")
            startScan()
        case .poweredOff:
            appState.isConnected = false
            VoiceService.shared.speak("Bluetooth is off. Please turn it on.")
        case .unauthorized:
            VoiceService.shared.speak("Bluetooth permission denied. Check settings.")
        default:
            break
        }
    }

    private func startScan() {
        central.scanForPeripherals(
            withServices: [CANE_SERVICE_UUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        print("Found: \(peripheral.name ?? "unknown") RSSI: \(RSSI)")
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        print("Connected to cane")
        appState.isConnected = true
        VoiceService.shared.speak("Cane connected. Ready to walk.")
        peripheral.discoverServices([CANE_SERVICE_UUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        print("Connection failed: \(error?.localizedDescription ?? "")")
        appState.isConnected = false
        retryAfterDelay()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        print("Disconnected")
        appState.isConnected = false
        dataChar  = nil
        self.peripheral = nil
        VoiceService.shared.speak("Cane disconnected.")
        retryAfterDelay()
    }

    private func retryAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.central.state == .poweredOn else { return }
            print("Retrying scan...")
            self.startScan()
        }
    }
}

// ── Peripheral events ─────────────────────────────────
extension BLEManager: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == CANE_SERVICE_UUID {
            peripheral.discoverCharacteristics(
                [CANE_CHARACTERISTIC_UUID],
                for: service
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let chars = service.characteristics else { return }
        for char in chars where char.uuid == CANE_CHARACTERISTIC_UUID {
            dataChar = char
            // subscribe — cane pushes data to us automatically
            peripheral.setNotifyValue(true, for: char)
            print("Subscribed to cane data stream")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard
            let data  = characteristic.value,
            let chunk = String(data: data, encoding: .utf8)
        else { return }

        // buffer chunks until we have a complete JSON object
        incomingBuffer += chunk

        // JSON ends with } — process when we have a complete object
        if incomingBuffer.contains("}") {
            let raw = incomingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            incomingBuffer = ""
            parseJSON(raw)
        }
    }
}

// ── JSON parsing ──────────────────────────────────────
extension BLEManager {

    private func parseJSON(_ raw: String) {
        guard
            let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any]
        else {
            print("Bad JSON: \(raw)")
            return
        }

        // distance + zone
        if let dist = json["distance_cm"] as? Int {
            appState.distanceCm = dist
        }
        if let zone = json["zone"] as? Int {
            appState.zone = zone
            handleZoneAlert(zone)
        }

        // battery — warn if low
        if let bat = json["battery"] as? Int {
            appState.battery = bat
            if bat < 20 && bat > 0 {
                VoiceService.shared.speak("Cane battery low. \(bat) percent.")
            }
        }

        // crowd mode transition
        if let crowd = json["crowd_mode"] as? Bool {
            handleCrowdMode(crowd)
        }

        // button press
        if let btn   = json["button"]    as? String,
           let btnId = json["button_id"] as? String,
           !btn.isEmpty {
            handleButton(type: btn, id: btnId)
        }
    }

    // ── Zone alerts ────────────────────────────────────
    private var lastZoneAlertedZone: Int = 0
    private var lastZoneAlertTime: Date = .distantPast

    private func handleZoneAlert(_ zone: Int) {
        guard appState.appMode != .silent else { return }
        guard zone >= 2 else { return } // zone 0 and 1 = no voice

        let now      = Date()
        let cooldown: TimeInterval = zone == 3 ? 1.0 : 1.5

        // same zone within cooldown = skip
        if zone == lastZoneAlertedZone &&
           now.timeIntervalSince(lastZoneAlertTime) < cooldown { return }

        lastZoneAlertedZone = zone
        lastZoneAlertTime   = now

        switch zone {
        case 2:
            VoiceService.shared.speak("Obstacle ahead.")
        case 3:
            VoiceService.shared.speak("Stop — obstacle very close.",
                                      priority: .high)
        default:
            break
        }
    }

    // ── Crowd mode ─────────────────────────────────────
    private func handleCrowdMode(_ crowd: Bool) {
        let was = appState.crowdMode
        appState.crowdMode = crowd

        if crowd && !was {
            appState.appMode = .crowd
            VoiceService.shared.speak("Busy area — critical alerts only.")
        } else if !crowd && was {
            appState.appMode = .normal
            VoiceService.shared.speak("Path clear.")
        }
    }

    // ── Button actions ──────────────────────────────────
    private func handleButton(type: String, id: String) {
        switch (id, type) {

        case ("A", "single_press"):
            VoiceService.shared.repeatLast()

        case ("A", "long_press"):
            NotificationCenter.default.post(
                name: .endWalk, object: nil)

        case ("B", "single_press"):
            let bat  = appState.battery
            let conn = appState.isConnected ? "Cane connected." : "Cane not connected."
            VoiceService.shared.speak("Battery \(bat) percent. \(conn)")

        case ("B", "double_press"):
            // toggle silent mode
            if appState.appMode == .silent {
                appState.appMode = .normal
                VoiceService.shared.speak("Sound on.")
            } else {
                appState.appMode = .silent
                // no voice confirmation — that defeats the purpose
            }

        case ("B", "long_press"):
            NotificationCenter.default.post(
                name: .sosRequested, object: nil)

        default:
            break
        }
    }
}

// ── Notification names ─────────────────────────────────
extension Notification.Name {
    static let endWalk      = Notification.Name("endWalk")
    static let sosRequested = Notification.Name("sosRequested")
}
