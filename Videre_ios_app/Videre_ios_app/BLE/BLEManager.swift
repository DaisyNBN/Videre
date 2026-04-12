import Foundation
import CoreBluetooth

let CANE_SERVICE_UUID        = CBUUID(string: "FFE0")
let CANE_CHARACTERISTIC_UUID = CBUUID(string: "FFE1")

class BLEManager: NSObject, ObservableObject {

    // ── Published state ───────────────────────────────
    @Published var isConnected:   Bool   = false
    @Published var statusMessage: String = "Looking for cane..."
    @Published var distanceCm:    Int    = 999
    @Published var zone:          Int    = 0
    @Published var buzzerOn:      Bool   = true
    @Published var vibOn:         Bool   = true
    @Published var rawJSON:       String = ""
    @Published var lastWhere:     String = ""
    @Published var lastWhat:      String = ""

    // ── CoreBluetooth ─────────────────────────────────
    private var central:    CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataChar:   CBCharacteristic?
    private var buffer      = ""

    // ── Zone alert cooldown ───────────────────────────
    private var lastZoneAlertTime: Date = .distantPast
    private var lastAlertedZone:   Int  = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // ── Send settings to cane ─────────────────────────
    func sendSettings(_ dict: [String: Any]) {
        guard
            let char = dataChar,
            let peri = peripheral,
            let data = try? JSONSerialization.data(
                            withJSONObject: dict),
            let str  = String(data: data, encoding: .utf8)
        else {
            print("sendSettings failed — not connected")
            return
        }
        peri.writeValue(Data(str.utf8),
                        for: char,
                        type: .withoutResponse)
        print("Sent to cane: \(str)")
    }
}

// ── CBCentralManagerDelegate ──────────────────────────
extension BLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(
            _ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("BLE powered on — starting scan")
            statusMessage = "Scanning for cane..."
            startScan()
        case .poweredOff:
            isConnected   = false
            statusMessage = "Bluetooth is off"
            VoiceService.shared.speak(
                "Bluetooth is off. Please turn it on.")
        case .unauthorized:
            statusMessage = "Bluetooth permission denied"
            print("BLE unauthorized — check Info.plist")
        case .unsupported:
            statusMessage = "Bluetooth not supported"
        default:
            statusMessage = "Bluetooth not ready"
        }
    }

    private func startScan() {
        central.scanForPeripherals(
            withServices: [CANE_SERVICE_UUID],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )
        print("Scanning for HMSoft...")
    }

    func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber) {
        print("Found: \(peripheral.name ?? "unknown") " +
              "RSSI:\(RSSI)")
        self.peripheral           = peripheral
        self.peripheral?.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
        statusMessage = "Found cane — connecting..."
    }

    func centralManager(
            _ central: CBCentralManager,
            didConnect peripheral: CBPeripheral) {
        print("Connected to cane")
        isConnected   = true
        statusMessage = "Cane connected"
        VoiceService.shared.speak(
            "Cane connected. Ready to walk.")
        peripheral.discoverServices([CANE_SERVICE_UUID])
    }

    func centralManager(
            _ central: CBCentralManager,
            didFailToConnect peripheral: CBPeripheral,
            error: Error?) {
        print("Failed: \(error?.localizedDescription ?? "")")
        isConnected   = false
        statusMessage = "Connection failed — retrying..."
        retryAfterDelay()
    }

    func centralManager(
            _ central: CBCentralManager,
            didDisconnectPeripheral peripheral: CBPeripheral,
            error: Error?) {
        print("Disconnected")
        isConnected     = false
        statusMessage   = "Disconnected — reconnecting..."
        dataChar        = nil
        self.peripheral = nil
        VoiceService.shared.speak("Cane disconnected.")
        retryAfterDelay()
    }

    private func retryAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard self.central.state == .poweredOn else { return }
            print("Retrying scan...")
            self.statusMessage = "Scanning for cane..."
            self.startScan()
        }
    }
}

// ── CBPeripheralDelegate ──────────────────────────────
extension BLEManager: CBPeripheralDelegate {

    func peripheral(
            _ peripheral: CBPeripheral,
            didDiscoverServices error: Error?) {
        if let e = error {
            print("Service error: \(e)")
            return
        }
        guard let services = peripheral.services
        else { return }
        print("Found \(services.count) service(s)")
        for service in services
            where service.uuid == CANE_SERVICE_UUID {
            peripheral.discoverCharacteristics(
                [CANE_CHARACTERISTIC_UUID], for: service)
        }
    }

    func peripheral(
            _ peripheral: CBPeripheral,
            didDiscoverCharacteristicsFor service: CBService,
            error: Error?) {
        if let e = error {
            print("Char error: \(e)")
            return
        }
        guard let chars = service.characteristics
        else { return }
        print("Found \(chars.count) characteristic(s)")
        for char in chars
            where char.uuid == CANE_CHARACTERISTIC_UUID {
            dataChar = char
            peripheral.setNotifyValue(true, for: char)
            print("Subscribed to FFE1 — data flowing")
        }
    }

    func peripheral(
            _ peripheral: CBPeripheral,
            didUpdateValueFor characteristic: CBCharacteristic,
            error: Error?) {
        if let e = error {
            print("Data error: \(e)")
            return
        }
        guard
            let data  = characteristic.value,
            let chunk = String(data: data, encoding: .utf8)
        else { return }

        // buffer — HM-10 splits JSON across packets
        buffer += chunk

        // process when complete JSON received
        if buffer.contains("}") {
            let raw = buffer
                .trimmingCharacters(
                    in: .whitespacesAndNewlines)
            buffer  = ""
            rawJSON = raw
            parseJSON(raw)
        }
    }

    func peripheral(
            _ peripheral: CBPeripheral,
            didUpdateNotificationStateFor
            characteristic: CBCharacteristic,
            error: Error?) {
        if let e = error {
            print("Notification error: \(e)")
            return
        }
        print("Notifications: \(characteristic.isNotifying)")
    }
}

// ── JSON parsing ──────────────────────────────────────
extension BLEManager {

    private func parseJSON(_ raw: String) {
        guard
            let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(
                            with: data) as? [String: Any]
        else {
            print("JSON parse failed: \(raw)")
            return
        }


        // where — Button A single press
        let whereVal = json["where"] as? String ?? ""
        if whereVal == "ask" {
            lastWhere = whereVal
            handleWhereRequest()
        }

        // what — Button B single press
        let whatVal = json["what"] as? String ?? ""
        if whatVal == "ask" {
            lastWhat = whatVal
            handleWhatRequest()
        }
    }


    // ── Zone voice alerts ─────────────────────────────
    private func handleZoneAlert(_ zone: Int) {
        guard zone >= 2 else { return }

        let now      = Date()
        let cooldown: TimeInterval = zone == 3 ? 1.0 : 1.5

        if zone == lastAlertedZone &&
           now.timeIntervalSince(lastZoneAlertTime)
               < cooldown {
            return
        }

        lastAlertedZone   = zone
        lastZoneAlertTime = now

        switch zone {
        case 2:
            VoiceService.shared.speak(
                "Obstacle ahead.")
        case 3:
            VoiceService.shared.speak(
                "Stop — obstacle very close.",
                priority: .high)
        default:
            break
        }
    }

    // ── Where am I — Button A single press ───────────
    private func handleWhereRequest() {
        // speak immediately while location loads
        VoiceService.shared.speak(
            "Waiting for location. I am standing at...")

        // post notification — LocationManager
        // follows up with actual address
        NotificationCenter.default.post(
            name: .whereRequested, object: nil)
    }

    // ── What is ahead — Button B single press ────────
    private func handleWhatRequest() {
        // build sentence from current sensor data
        let distanceText: String
        if distanceCm == 999 {
            distanceText = "nothing detected by the sensor"
        } else {
            distanceText = "\(distanceCm) centimetres"
        }

        let zoneText: String
        switch zone {
        case 3: zoneText = "something is very close, please stop"
        case 2: zoneText = "there is an obstacle nearby"
        case 1: zoneText = "there is something in the distance"
        default: zoneText = "the path seems clear"
        }

        // speak immediately with sensor data
        VoiceService.shared.speak(
            "In front of me there are a few things. " +
            "The nearest is \(distanceText). \(zoneText).")

        // post notification — GeminiService
        // follows up with camera description
        NotificationCenter.default.post(
            name: .whatRequested, object: nil)
    }
}

// ── Notification names ────────────────────────────────
extension Notification.Name {
    static let whereRequested = Notification.Name("whereRequested")
    static let whatRequested  = Notification.Name("whatRequested")
    static let sosRequested   = Notification.Name("sosRequested")
    static let endWalk        = Notification.Name("endWalk")
}
