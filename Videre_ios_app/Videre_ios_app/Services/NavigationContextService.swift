import Combine
import CoreLocation
import Foundation

/// Builds `POST /api/navigate` style payloads matching backend `NavRequest`.
final class NavigationContextService: NSObject, ObservableObject {

    /// Default map when GPS not fixed yet (WashU area — replace via real fix).
    private static let defaultLat = 38.6480
    private static let defaultLng = -90.3095

    @Published private(set) var latitude:  Double = NavigationContextService.defaultLat
    @Published private(set) var longitude: Double = NavigationContextService.defaultLng
    /// Degrees 0–360, or 0 if unknown.
    @Published private(set) var headingDegrees: Double = 0
    @Published private(set) var locationAuthorized = false

    var routeId: String = "demo-route"

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 5
        }
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    /// Mirrors `backend` `NavRequest` / your sample JSON.
    func payload(
        ble: BLEManager,
        lidar: LiDARService,
        appState: AppState
    ) -> [String: Any] {
        let speed: String =
            appState.walkState == .walking ? "walking" : "stopped"
        return [
            "user_id":         DeviceIdentity.userId,
            "route_id":        routeId,
            "location":        [
                "lat": latitude,
                "lng": longitude
            ],
            "heading_degrees": headingDegrees,
            "obstacles":       Self.buildObstacles(
                ble: ble,
                lidar: lidar),
            "speed":           speed
        ]
    }

    /// `depthClearSide` = where LiDAR sees *more* open space; API `position` is
    /// where the obstacle sits — use opposite left/right, keep `center`.
    private static func obstaclePositionFromLidar(
            clearSide: String) -> String {
        switch clearSide {
        case "left":  return "right"
        case "right": return "left"
        default:      return "center"
        }
    }

    private static func buildObstacles(
            ble: BLEManager,
            lidar: LiDARService) -> [[String: Any]] {

        let lidarCm = lidar.nearestCm
        let caneCm  = ble.distanceCm
        let cm      = lidarCm != 999 ? lidarCm : caneCm
        guard cm != 999 else { return [] }

        let estimate: String =
            cm < 60  ? "near"
            : cm < 150 ? "mid"
            : "far"

        let position: String =
            lidar.isRunning && lidarCm != 999
            ? obstaclePositionFromLidar(clearSide: lidar.depthClearSide)
            : "center"

        let obstacleLabel =
            lidar.isRunning
            ? lidar.navigationObstacleLabel
            : "obstacle"

        return [[
            "label":              obstacleLabel,
            "position":           position,
            "distance_estimate":  estimate
        ]]
    }
}

extension NavigationContextService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(
            _ manager: CLLocationManager) {

        let ok: Bool
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            ok = true
        default:
            ok = false
        }
        DispatchQueue.main.async {
            self.locationAuthorized = ok
        }
    }

    func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]) {

        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.latitude  = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude
            // Valid course = direction of travel; invalid stays on compass heading.
            if loc.course >= 0 {
                self.headingDegrees = loc.course
            }
        }
    }

    func locationManager(
            _ manager: CLLocationManager,
            didUpdateHeading newHeading: CLHeading) {

        let v = newHeading.trueHeading >= 0
            ? newHeading.trueHeading
            : newHeading.magneticHeading
        DispatchQueue.main.async {
            self.headingDegrees = v
        }
    }

    func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
