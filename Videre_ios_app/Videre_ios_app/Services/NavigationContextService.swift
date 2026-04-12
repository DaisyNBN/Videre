import Combine
import CoreLocation
import Foundation

struct WalkCoordinateSample {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let localX: Double
    let localY: Double
    let localZ: Double
    let headingDegrees: Double
}

/// Builds `POST /api/navigate` style payloads matching backend `NavRequest`.
final class NavigationContextService: NSObject, ObservableObject {

    /// Default map when GPS not fixed yet (WashU area — replace via real fix).
    private static let defaultLat = 38.6480
    private static let defaultLng = -90.3095

    @Published private(set) var latitude:  Double = NavigationContextService.defaultLat
    @Published private(set) var longitude: Double = NavigationContextService.defaultLng
    /// Degrees 0–360, or 0 if unknown.
    @Published private(set) var headingDegrees: Double = 0
    @Published private(set) var speedMetersPerSecond: Double = 0
    @Published private(set) var locationAuthorized = false
    @Published private(set) var nearbyHazardsCount = 0
    @Published private(set) var hazardPollStatus = ""
    @Published private(set) var autoRerouteStatus = ""
    @Published private(set) var walkCoordinateSampleCount = 0

    var routeId: String = "demo-route"

    private let manager = CLLocationManager()
    private var hazardPollTimer: Timer?
    private var cachedHazardObstacles: [[String: Any]] = []
    private var lastHazardSignature: String = ""
    private var isRerouteInFlight = false
    private var lastCompassHeadingUpdateAt: Date = .distantPast
    private var walkCoordinateTrail: [WalkCoordinateSample] = []
    private var lastWalkCoordinateSampleAt: Date = .distantPast
    private let walkCoordinateSampleInterval: TimeInterval = 0.6

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 1
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
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
        startHazardPolling()
    }

    deinit {
        hazardPollTimer?.invalidate()
    }

    /// Mirrors `backend` `NavRequest` / your sample JSON.
    func payload(
        ble: BLEManager,
        lidar: LiDARService,
        appState: AppState,
        scan: ScanService
    ) -> [String: Any] {
        APIService.shared.refineRouteGeoCalibration(
            latitude: latitude,
            longitude: longitude,
            headingDegrees: headingDegrees
        )

        let selectedRouteId = APIService.shared.activeRouteId ?? routeId
        let speed: String =
            appState.walkState == .walking ? "walking" : "stopped"
        var obstacles = Self.buildObstacles(
            ble: ble,
            lidar: lidar
        )
        obstacles.append(contentsOf: cachedHazardObstacles)
        let mapPosition: [String: Any] = [
            "x": Double(scan.currentPosition.x),
            "y": Double(scan.currentPosition.y),
            "z": Double(scan.currentPosition.z),
        ]

        return [
            "user_id":         DeviceIdentity.userId,
            "route_id":        selectedRouteId,
            "location":        [
                "lat": latitude,
                "lng": longitude
            ],
            "map_position":    mapPosition,
            "heading_degrees": headingDegrees,
            "obstacles":       obstacles,
            "speed":           speed,
            "speed_mps":       speedMetersPerSecond
        ]
    }

    @MainActor
    func recordWalkCoordinateSampleIfNeeded(appState: AppState, scan: ScanService) {
        guard appState.walkState == .walking else { return }

        let now = Date()
        guard now.timeIntervalSince(lastWalkCoordinateSampleAt) >= walkCoordinateSampleInterval else {
            return
        }

        let sample = WalkCoordinateSample(
            timestamp: now,
            latitude: latitude,
            longitude: longitude,
            localX: Double(scan.currentPosition.x),
            localY: Double(scan.currentPosition.y),
            localZ: Double(scan.currentPosition.z),
            headingDegrees: headingDegrees
        )

        walkCoordinateTrail.append(sample)
        if walkCoordinateTrail.count > 1200 {
            walkCoordinateTrail.removeFirst(walkCoordinateTrail.count - 1200)
        }

        walkCoordinateSampleCount = walkCoordinateTrail.count
        lastWalkCoordinateSampleAt = now
    }

    @MainActor
    func walkCoordinateHistory(limit: Int = 300) -> [[String: Any]] {
        let boundedLimit = max(1, limit)
        let startIndex = max(0, walkCoordinateTrail.count - boundedLimit)
        let window = walkCoordinateTrail[startIndex...]

        return window.map { sample in
            [
                "timestamp": sample.timestamp.timeIntervalSince1970,
                "lat": sample.latitude,
                "lng": sample.longitude,
                "x": sample.localX,
                "y": sample.localY,
                "z": sample.localZ,
                "heading_degrees": sample.headingDegrees,
            ]
        }
    }

    private func startHazardPolling() {
        guard hazardPollTimer == nil else { return }

        hazardPollStatus = "Starting hazard polling..."
        hazardPollTimer = Timer.scheduledTimer(
            withTimeInterval: 12,
            repeats: true,
            block: { [weak self] _ in
                self?.pollHazardsTick()
            }
        )

        pollHazardsTick()
    }

    private func pollHazardsTick() {
        Task {
            await refreshNearbyHazards()
        }
    }

    @MainActor
    private func buildHazardObstacles(from hazards: [[String: Any]]) -> [[String: Any]] {
        let current = CLLocation(latitude: latitude, longitude: longitude)

        let enriched = hazards.compactMap { hazard -> (distance: Double, obstacle: [String: Any])? in
            guard let hazardLat = hazard["lat"] as? Double,
                  let hazardLng = hazard["lng"] as? Double
            else {
                return nil
            }

            let hazardLoc = CLLocation(latitude: hazardLat, longitude: hazardLng)
            let meters = current.distance(from: hazardLoc)

            let estimate: String
            if meters < 40 {
                estimate = "near"
            } else if meters < 110 {
                estimate = "mid"
            } else {
                estimate = "far"
            }

            let label = (hazard["type"] as? String)
                ?? (hazard["description"] as? String)
                ?? "hazard"

            return (
                meters,
                [
                    "label": label,
                    "position": "center",
                    "distance_estimate": estimate,
                ]
            )
        }

        return enriched
            .sorted(by: { $0.distance < $1.distance })
            .prefix(3)
            .map { $0.obstacle }
    }

    @MainActor
    private func hazardSignature(_ hazards: [[String: Any]]) -> String {
        hazards
            .compactMap { row in
                guard let type = row["type"] as? String,
                      let lat = row["lat"] as? Double,
                      let lng = row["lng"] as? Double
                else {
                    return nil
                }
                return "\(type):\(String(format: "%.5f", lat)),\(String(format: "%.5f", lng))"
            }
            .sorted()
            .joined(separator: "|")
    }

    @MainActor
    private func maybeTriggerAutoRerouteIfNeeded(
            hazards: [[String: Any]],
            signature: String
    ) {
        guard !signature.isEmpty,
              signature != lastHazardSignature,
              APIService.shared.activeRouteId != nil,
              !isRerouteInFlight
        else {
            lastHazardSignature = signature
            return
        }

        isRerouteInFlight = true
        let blockedNodeIds = APIService.shared.deriveBlockedNodeIdsFromHazards(
            hazards: hazards,
            maxCount: min(max(hazards.count, 1), 4),
            thresholdMeters: 30
        )

        autoRerouteStatus = blockedNodeIds.isEmpty
            ? "Hazards changed. Recomputing route..."
            : "Hazards changed. Blocking \(blockedNodeIds.count) nodes and rerouting..."

        Task {
            do {
                let routeId = try await APIService.shared.rerouteActiveRoute(
                    reason: "Nearby hazards changed",
                    obstacleNodeIds: blockedNodeIds,
                    blockedNodeIds: blockedNodeIds
                )

                await MainActor.run {
                    autoRerouteStatus = "Auto reroute completed: \(routeId)"
                    isRerouteInFlight = false
                    lastHazardSignature = signature
                }
            } catch {
                await MainActor.run {
                    autoRerouteStatus = "Auto reroute failed: \(error.localizedDescription)"
                    isRerouteInFlight = false
                    lastHazardSignature = signature
                }
            }
        }
    }

    @MainActor
    func refreshNearbyHazards() async {
        do {
            let hazards = try await APIService.shared.fetchHazards(
                lat: latitude,
                lng: longitude,
                radiusMeters: 120
            )

            nearbyHazardsCount = hazards.count
            cachedHazardObstacles = buildHazardObstacles(from: hazards)
            hazardPollStatus = "Hazards in range: \(hazards.count)"

            APIService.shared.refineRouteGeoCalibration(
                latitude: latitude,
                longitude: longitude,
                headingDegrees: headingDegrees
            )

            let signature = hazardSignature(hazards)
            maybeTriggerAutoRerouteIfNeeded(hazards: hazards, signature: signature)
        } catch {
            hazardPollStatus = "Hazard polling failed: \(error.localizedDescription)"
        }
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
            self.speedMetersPerSecond = max(0, loc.speed)

            // Use GPS course only as fallback when compass heading has not updated
            // recently and the user is actually moving.
            let compassIsStale = Date().timeIntervalSince(self.lastCompassHeadingUpdateAt) > 4
            if compassIsStale && loc.course >= 0 && loc.speed > 0.8 {
                self.headingDegrees = loc.course
            }
        }

        Task { @MainActor in
            await self.refreshNearbyHazards()
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
            self.lastCompassHeadingUpdateAt = Date()
        }
    }

    func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}
