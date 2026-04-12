//
//  APIService.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation

struct NavigationInstructionResponse {
    let instruction: String
    let urgency: String
    let hapticPattern: String
    let nextCheckpoint: String?
    let distanceToNextM: Double?
    let fallbackUsed: Bool
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        var output: [Element] = []

        for value in self where !seen.contains(value) {
            seen.insert(value)
            output.append(value)
        }

        return output
    }
}

struct MapGraphResponse {
    let nodes: [[String: Any]]
    let edges: [[String: Any]]
}

struct MapLandmarkRecord: Identifiable {
    let id: String
    let type: String
    let label: String
    let status: String
    let confidence: Double?
    let headingDegrees: Double?
}

struct MapContributionResult {
    let contributionId: String
    let status: String
}

struct ExistingMapRecord: Identifiable {
    let id: String
    let roomName: String
    let createdBy: String
    let createdAt: String
    let version: Int
}

struct NearbyMapCandidate: Identifiable {
    let mapId: String
    let roomName: String
    let distanceMeters: Double?

    var id: String { mapId }
}

struct ExistingScanRecord: Identifiable {
    let id: String
    let roomName: String
    let startedAt: String
    let endedAt: String
    let processingStatus: String
}

struct ExistingNavigationBootstrapResult {
    let map: ExistingMapRecord
    let scans: [ExistingScanRecord]
    let landmarks: [MapLandmarkRecord]
}

struct RouteCalibrationDebugSnapshot {
    let active: Bool
    let mapId: String?
    let routeId: String?
    let startNodeId: String?
    let endNodeId: String?
    let routeNodeCount: Int
    let headingOffsetDegrees: Double?
    let metersPerUnit: Double?
    let anchorLat: Double?
    let anchorLng: Double?
    let nearestNodeId: String?
    let nearestNodeDistanceM: Double?
}

struct RouteLocalizationStatus {
    let active: Bool
    let confidence: Double
    let quality: String
    let nearestNodeId: String?
    let nearestNodeDistanceM: Double?
    let message: String
}

private struct APIRequestError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        if message.isEmpty {
            return "HTTP \(statusCode)"
        }
        return message
    }
}

final class APIService {

    private struct RouteGeoCalibration {
        let mapId: String
        let startNodeId: String
        var anchorLat: Double
        var anchorLng: Double
        var headingRadians: Double
        var metersPerUnit: Double
    }

    private struct LocalRoutePositionOffset {
        let mapId: String
        var dx: Double
        var dy: Double
        var dz: Double
    }

    private struct ProjectedRouteNode {
        let id: String
        let index: Int
        let lat: Double
        let lng: Double
    }

    private struct MapGeoAnchor: Codable {
        let mapId: String
        var roomName: String?
        let latitude: Double
        let longitude: Double
        let updatedAt: TimeInterval
    }

    static let shared = APIService()
    private init() {
        loadMapGeoAnchorsFromDefaults()
    }

    private static let activeRouteIdKey = "videre.activeRouteId"
    private static let activeMapIdKey = "videre.activeMapId"
    private static let activeStartNodeIdKey = "videre.activeStartNodeId"
    private static let activeEndNodeIdKey = "videre.activeEndNodeId"
    private static let mapGeoAnchorsKey = "videre.mapGeoAnchors.v1"

    private static let normalizedApiBaseURL = {
        let trimmed = Secrets.apiURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noTrailingSlash = trimmed.hasSuffix("/")
            ? String(trimmed.dropLast())
            : trimmed
        return noTrailingSlash.hasSuffix("/api")
            ? noTrailingSlash
            : "\(noTrailingSlash)/api"
    }()
    private let apiBaseURL = APIService.normalizedApiBaseURL
    private var cachedMapNodesById: [String: (x: Double, y: Double, z: Double)] = [:]
    private var cachedRouteNodeIds: [String] = []
    private var routeGeoCalibration: RouteGeoCalibration?
    private var localRoutePositionOffset: LocalRoutePositionOffset?
    private var lastGeoCalibrationSample: (lat: Double, lng: Double)?
    private var mapGeoAnchorsByMapId: [String: MapGeoAnchor] = [:]

    var activeRouteId: String? {
        UserDefaults.standard.string(forKey: Self.activeRouteIdKey)
    }

    var activeMapId: String? {
        UserDefaults.standard.string(forKey: Self.activeMapIdKey)
    }

    var activeStartNodeId: String? {
        UserDefaults.standard.string(forKey: Self.activeStartNodeIdKey)
    }

    var activeEndNodeId: String? {
        UserDefaults.standard.string(forKey: Self.activeEndNodeIdKey)
    }

    var activeRouteNodeIds: [String] {
        cachedRouteNodeIds
    }

    func setActiveRouteId(_ routeId: String?) {
        if let routeId, !routeId.isEmpty {
            UserDefaults.standard.set(routeId, forKey: Self.activeRouteIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeRouteIdKey)
        }
    }

    func setActiveMapId(_ mapId: String?) {
        if let mapId, !mapId.isEmpty {
            UserDefaults.standard.set(mapId, forKey: Self.activeMapIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeMapIdKey)
        }
    }

    func setActiveRouteContext(
            mapId: String,
            routeId: String,
            startNodeId: String,
            endNodeId: String
    ) {
        setActiveMapId(mapId)
        setActiveRouteId(routeId)
        UserDefaults.standard.set(startNodeId, forKey: Self.activeStartNodeIdKey)
        UserDefaults.standard.set(endNodeId, forKey: Self.activeEndNodeIdKey)
        if routeGeoCalibration?.mapId != mapId ||
            routeGeoCalibration?.startNodeId != startNodeId {
            routeGeoCalibration = nil
            localRoutePositionOffset = nil
            lastGeoCalibrationSample = nil
        }
    }

    func clearActiveRouteContext() {
        setActiveMapId(nil)
        setActiveRouteId(nil)
        UserDefaults.standard.removeObject(forKey: Self.activeStartNodeIdKey)
        UserDefaults.standard.removeObject(forKey: Self.activeEndNodeIdKey)
        cachedMapNodesById = [:]
        cachedRouteNodeIds = []
        routeGeoCalibration = nil
        localRoutePositionOffset = nil
        lastGeoCalibrationSample = nil
    }

    func correctedMapPosition(
            localX: Double,
            localY: Double,
            localZ: Double
    ) -> (x: Double, y: Double, z: Double) {
        guard let offset = localRoutePositionOffset,
              offset.mapId == activeMapId else {
            return (localX, localY, localZ)
        }

        return (
            x: localX + offset.dx,
            y: localY + offset.dy,
            z: localZ + offset.dz
        )
    }

    func reanchorLocalPositionToRouteNode(
            nodeId: String,
            localX: Double,
            localY: Double,
            localZ: Double,
            blend: Double = 0.85
    ) {
        guard let mapId = activeMapId,
              let node = cachedMapNodesById[nodeId]
        else {
            return
        }

        let corrected = correctedMapPosition(localX: localX, localY: localY, localZ: localZ)
        let safeBlend = clamp(blend, min: 0, max: 1)
        let deltaX = node.x - corrected.x
        let deltaY = node.y - corrected.y
        let deltaZ = node.z - corrected.z

        let existing = localRoutePositionOffset?.mapId == mapId
            ? localRoutePositionOffset
            : LocalRoutePositionOffset(mapId: mapId, dx: 0, dy: 0, dz: 0)

        localRoutePositionOffset = LocalRoutePositionOffset(
            mapId: mapId,
            dx: existing!.dx + (deltaX * safeBlend),
            dy: existing!.dy + (deltaY * safeBlend),
            dz: existing!.dz + (deltaZ * safeBlend)
        )
    }

    func cacheMapNodes(nodes: [[String: Any]]) {
        var parsed: [String: (x: Double, y: Double, z: Double)] = [:]

        for node in nodes {
            guard let id = stringValue(node["id"]),
                  let x = numberAsDouble(node["x"]),
                  let y = numberAsDouble(node["y"])
            else {
                continue
            }

            let z = numberAsDouble(node["z"]) ?? 0
            parsed[id] = (x: x, y: y, z: z)
        }

        cachedMapNodesById = parsed
    }

    func ensureRouteGeoAnchorIfNeeded(latitude: Double, longitude: Double) {
        guard let mapId = activeMapId,
              let startNodeId = activeStartNodeId,
              cachedMapNodesById[startNodeId] != nil
        else {
            return
        }

        guard routeGeoCalibration == nil ||
            routeGeoCalibration?.mapId != mapId ||
            routeGeoCalibration?.startNodeId != startNodeId
        else {
            return
        }

        routeGeoCalibration = RouteGeoCalibration(
            mapId: mapId,
            startNodeId: startNodeId,
            anchorLat: latitude,
            anchorLng: longitude,
            headingRadians: 0,
            metersPerUnit: 1
        )
        lastGeoCalibrationSample = (lat: latitude, lng: longitude)
        upsertMapGeoAnchor(
            mapId: mapId,
            roomName: nil,
            latitude: latitude,
            longitude: longitude
        )
    }

    func distanceToKnownMapAnchor(
            mapId: String,
            latitude: Double,
            longitude: Double
    ) -> Double? {
        guard let anchor = mapGeoAnchorsByMapId[mapId] else {
            return nil
        }

        return haversineMeters(
            lat1: latitude,
            lng1: longitude,
            lat2: anchor.latitude,
            lng2: anchor.longitude
        )
    }

    func fetchNearbyMapCandidates(
            latitude: Double,
            longitude: Double,
            radiusMeters: Double = 220,
            limit: Int = 10
    ) async throws -> [NearbyMapCandidate] {
        let clampedLimit = max(1, min(limit, 30))
        let maps = try await fetchMaps(limit: min(clampedLimit * 6, 100), offset: 0)
        guard !maps.isEmpty else {
            return []
        }

        refreshMapAnchorRoomNames(using: maps)

        let clampedRadius = max(15, radiusMeters)
        var nearby: [NearbyMapCandidate] = []

        for map in maps {
            if let distance = distanceToKnownMapAnchor(
                mapId: map.id,
                latitude: latitude,
                longitude: longitude
            ), distance <= clampedRadius {
                nearby.append(
                    NearbyMapCandidate(
                        mapId: map.id,
                        roomName: map.roomName,
                        distanceMeters: distance
                    )
                )
            }
        }

        let sortedNearby = nearby.sorted { lhs, rhs in
            let lhsDistance = lhs.distanceMeters ?? .greatestFiniteMagnitude
            let rhsDistance = rhs.distanceMeters ?? .greatestFiniteMagnitude
            if lhsDistance == rhsDistance {
                return lhs.roomName.localizedCaseInsensitiveCompare(rhs.roomName) == .orderedAscending
            }
            return lhsDistance < rhsDistance
        }

        if !sortedNearby.isEmpty {
            return Array(sortedNearby.prefix(clampedLimit))
        }

        // Fallback for maps that don't have a known geo anchor yet.
        let fallback = maps.prefix(clampedLimit).map { map in
            NearbyMapCandidate(
                mapId: map.id,
                roomName: map.roomName,
                distanceMeters: distanceToKnownMapAnchor(
                    mapId: map.id,
                    latitude: latitude,
                    longitude: longitude
                )
            )
        }

        return fallback
    }

    func refineRouteGeoCalibration(
            latitude: Double,
            longitude: Double,
            headingDegrees: Double?
    ) {
        ensureRouteGeoAnchorIfNeeded(latitude: latitude, longitude: longitude)

        guard var calibration = routeGeoCalibration,
              let startNode = cachedMapNodesById[calibration.startNodeId],
              !cachedRouteNodeIds.isEmpty
        else {
            return
        }

        if let headingDegrees,
           headingDegrees >= 0,
           headingDegrees < 360,
           let routeHeading = localRouteHeadingRadians() {
            let headingRadians = headingDegrees * .pi / 180
            let targetOffset = normalizeRadians(headingRadians - routeHeading)
            calibration.headingRadians = blendAngles(
                current: calibration.headingRadians,
                target: targetOffset,
                alpha: 0.2
            )
        }

        let projectedNodes = projectRouteNodeCoordinates(using: calibration)
        if let nearest = nearestProjectedRouteNode(
            toLat: latitude,
            lng: longitude,
            in: projectedNodes
        ),
           let nearestNode = cachedMapNodesById[nearest.id] {
            let localDistance = hypot(
                nearestNode.x - startNode.x,
                nearestNode.y - startNode.y
            )

            let geoDistance = haversineMeters(
                lat1: calibration.anchorLat,
                lng1: calibration.anchorLng,
                lat2: latitude,
                lng2: longitude
            )

            if localDistance > 1.25, geoDistance > 2 {
                let candidateScale = clamp(
                    geoDistance / localDistance,
                    min: 0.2,
                    max: 8
                )
                calibration.metersPerUnit =
                    (calibration.metersPerUnit * 0.82) +
                    (candidateScale * 0.18)
            }

            if let previous = lastGeoCalibrationSample {
                let movementDistance = haversineMeters(
                    lat1: previous.lat,
                    lng1: previous.lng,
                    lat2: latitude,
                    lng2: longitude
                )

                if movementDistance >= 2.5,
                   let movementBearing = bearingRadians(
                    lat1: previous.lat,
                    lng1: previous.lng,
                    lat2: latitude,
                    lng2: longitude
                   ),
                   let routeTangent = localRouteTangentRadians(nearIndex: nearest.index) {
                    let headingTarget = normalizeRadians(movementBearing - routeTangent)
                    calibration.headingRadians = blendAngles(
                        current: calibration.headingRadians,
                        target: headingTarget,
                        alpha: 0.12
                    )
                }
            }
        }

        routeGeoCalibration = calibration
        lastGeoCalibrationSample = (lat: latitude, lng: longitude)
    }

    func deriveBlockedNodeIdsFromHazards(
            hazards: [[String: Any]],
            maxCount: Int = 3,
            thresholdMeters: Double = 25
    ) -> [String] {
        guard !hazards.isEmpty else { return [] }
        guard let calibration = routeGeoCalibration,
              !cachedRouteNodeIds.isEmpty
        else {
            return fallbackBlockedNodeIds(maxCount: maxCount)
        }

        let routeNodeCoordinates = projectRouteNodeCoordinates(using: calibration)
        guard !routeNodeCoordinates.isEmpty else {
            return fallbackBlockedNodeIds(maxCount: maxCount)
        }

        var selected: [String] = []
        let safeMax = max(1, maxCount)

        for hazard in hazards {
            guard let hazardLat = numberAsDouble(hazard["lat"]),
                  let hazardLng = numberAsDouble(hazard["lng"])
            else {
                continue
            }

            let nearest = routeNodeCoordinates.min { lhs, rhs in
                haversineMeters(
                    lat1: hazardLat,
                    lng1: hazardLng,
                    lat2: lhs.lat,
                    lng2: lhs.lng
                ) < haversineMeters(
                    lat1: hazardLat,
                    lng1: hazardLng,
                    lat2: rhs.lat,
                    lng2: rhs.lng
                )
            }

            guard let nearest else { continue }

            let distance = haversineMeters(
                lat1: hazardLat,
                lng1: hazardLng,
                lat2: nearest.lat,
                lng2: nearest.lng
            )

            if distance <= thresholdMeters {
                selected.append(nearest.id)
            }
        }

        let filtered = selected
            .filter { $0 != activeStartNodeId && $0 != activeEndNodeId }
            .uniqued()

        if filtered.isEmpty {
            return fallbackBlockedNodeIds(maxCount: safeMax)
        }

        return Array(filtered.prefix(safeMax))
    }

    func calibrationDebugSnapshot(
            latitude: Double,
            longitude: Double
    ) -> RouteCalibrationDebugSnapshot {
        guard let calibration = routeGeoCalibration else {
            return RouteCalibrationDebugSnapshot(
                active: false,
                mapId: activeMapId,
                routeId: activeRouteId,
                startNodeId: activeStartNodeId,
                endNodeId: activeEndNodeId,
                routeNodeCount: cachedRouteNodeIds.count,
                headingOffsetDegrees: nil,
                metersPerUnit: nil,
                anchorLat: nil,
                anchorLng: nil,
                nearestNodeId: nil,
                nearestNodeDistanceM: nil
            )
        }

        let projected = projectRouteNodeCoordinates(using: calibration)
        let nearest = nearestProjectedRouteNode(
            toLat: latitude,
            lng: longitude,
            in: projected
        )

        let nearestDistance = nearest.map {
            haversineMeters(
                lat1: latitude,
                lng1: longitude,
                lat2: $0.lat,
                lng2: $0.lng
            )
        }

        return RouteCalibrationDebugSnapshot(
            active: true,
            mapId: calibration.mapId,
            routeId: activeRouteId,
            startNodeId: calibration.startNodeId,
            endNodeId: activeEndNodeId,
            routeNodeCount: cachedRouteNodeIds.count,
            headingOffsetDegrees: calibration.headingRadians * 180 / .pi,
            metersPerUnit: calibration.metersPerUnit,
            anchorLat: calibration.anchorLat,
            anchorLng: calibration.anchorLng,
            nearestNodeId: nearest?.id,
            nearestNodeDistanceM: nearestDistance
        )
    }

    func routeLocalizationStatus(
            localX: Double,
            localY: Double,
            localZ: Double
    ) -> RouteLocalizationStatus {
        guard activeRouteId != nil,
              !cachedRouteNodeIds.isEmpty
        else {
            return RouteLocalizationStatus(
                active: false,
                confidence: 0,
                quality: "unavailable",
                nearestNodeId: nil,
                nearestNodeDistanceM: nil,
                message: "No active route localization"
            )
        }

        let routeNodes = cachedRouteNodeIds.compactMap { nodeId -> (id: String, x: Double, y: Double, z: Double)? in
            guard let node = cachedMapNodesById[nodeId] else {
                return nil
            }

            return (id: nodeId, x: node.x, y: node.y, z: node.z)
        }

        guard !routeNodes.isEmpty else {
            return RouteLocalizationStatus(
                active: true,
                confidence: 0,
                quality: "low",
                nearestNodeId: nil,
                nearestNodeDistanceM: nil,
                message: "Route map nodes are not loaded"
            )
        }

        let corrected = correctedMapPosition(localX: localX, localY: localY, localZ: localZ)

        var nearestNodeId: String?
        var nearestDistance = Double.greatestFiniteMagnitude

        for node in routeNodes {
            let dx = node.x - corrected.x
            let dy = node.y - corrected.y
            let dz = node.z - corrected.z
            let distance = sqrt((dx * dx) + (dy * dy) + (dz * dz))

            if distance < nearestDistance {
                nearestDistance = distance
                nearestNodeId = node.id
            }
        }

        let clampedDistance = nearestDistance.isFinite
            ? nearestDistance
            : 99
        let confidence = clamp(
            1 - (clampedDistance / 3.5),
            min: 0,
            max: 1
        )

        let quality: String
        if clampedDistance <= 1.2 {
            quality = "high"
        } else if clampedDistance <= 2.5 {
            quality = "medium"
        } else {
            quality = "low"
        }

        let message = "\(quality) confidence (\(String(format: "%.1f", clampedDistance)) m from route)"

        return RouteLocalizationStatus(
            active: true,
            confidence: confidence,
            quality: quality,
            nearestNodeId: nearestNodeId,
            nearestNodeDistanceM: clampedDistance,
            message: message
        )
    }

    private func projectRouteNodeCoordinates(
            using calibration: RouteGeoCalibration
    ) -> [ProjectedRouteNode] {
        guard let startNode = cachedMapNodesById[calibration.startNodeId] else {
            return []
        }

        let cosLat = max(cos(calibration.anchorLat * .pi / 180), 0.0001)
        let headingSin = sin(calibration.headingRadians)
        let headingCos = cos(calibration.headingRadians)

        return cachedRouteNodeIds.enumerated().compactMap { index, nodeId in
            guard let node = cachedMapNodesById[nodeId] else {
                return nil
            }

            let dx = node.x - startNode.x
            let dy = node.y - startNode.y

            let northMeters =
                ((dx * headingCos) - (dy * headingSin)) * calibration.metersPerUnit
            let eastMeters =
                ((dx * headingSin) + (dy * headingCos)) * calibration.metersPerUnit

            let lat = calibration.anchorLat + (northMeters / 111_000)
            let lng = calibration.anchorLng + (eastMeters / (111_000 * cosLat))

            return ProjectedRouteNode(
                id: nodeId,
                index: index,
                lat: lat,
                lng: lng
            )
        }
    }

    private func nearestProjectedRouteNode(
            toLat lat: Double,
            lng: Double,
            in nodes: [ProjectedRouteNode]
    ) -> ProjectedRouteNode? {
        nodes.min { lhs, rhs in
            haversineMeters(
                lat1: lat,
                lng1: lng,
                lat2: lhs.lat,
                lng2: lhs.lng
            ) < haversineMeters(
                lat1: lat,
                lng1: lng,
                lat2: rhs.lat,
                lng2: rhs.lng
            )
        }
    }

    private func localRouteHeadingRadians() -> Double? {
        guard cachedRouteNodeIds.count > 1,
              let first = cachedMapNodesById[cachedRouteNodeIds[0]]
        else {
            return nil
        }

        for nodeId in cachedRouteNodeIds.dropFirst() {
            guard let next = cachedMapNodesById[nodeId] else {
                continue
            }

            let north = next.x - first.x
            let east = next.y - first.y
            if abs(north) > 0.0001 || abs(east) > 0.0001 {
                return atan2(east, north)
            }
        }

        return nil
    }

    private func localRouteTangentRadians(nearIndex index: Int) -> Double? {
        guard !cachedRouteNodeIds.isEmpty else {
            return nil
        }

        let fromIndex = max(0, index - 1)
        let toIndex = min(cachedRouteNodeIds.count - 1, index + 1)
        guard fromIndex != toIndex,
              let fromNode = cachedMapNodesById[cachedRouteNodeIds[fromIndex]],
              let toNode = cachedMapNodesById[cachedRouteNodeIds[toIndex]]
        else {
            return nil
        }

        let north = toNode.x - fromNode.x
        let east = toNode.y - fromNode.y
        guard abs(north) > 0.0001 || abs(east) > 0.0001 else {
            return nil
        }

        return atan2(east, north)
    }

    private func clamp(
            _ value: Double,
            min lowerBound: Double,
            max upperBound: Double
    ) -> Double {
        Swift.max(lowerBound, Swift.min(upperBound, value))
    }

    private func normalizeRadians(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > .pi {
            normalized -= 2 * .pi
        }
        while normalized < -.pi {
            normalized += 2 * .pi
        }
        return normalized
    }

    private func blendAngles(current: Double, target: Double, alpha: Double) -> Double {
        let safeAlpha = clamp(alpha, min: 0, max: 1)
        let delta = normalizeRadians(target - current)
        return normalizeRadians(current + (delta * safeAlpha))
    }

    private func bearingRadians(
            lat1: Double,
            lng1: Double,
            lat2: Double,
            lng2: Double
    ) -> Double? {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaLambda = (lng2 - lng1) * .pi / 180

        let y = sin(deltaLambda) * cos(phi2)
        let x =
            cos(phi1) * sin(phi2) -
            sin(phi1) * cos(phi2) * cos(deltaLambda)

        guard abs(x) > 1e-9 || abs(y) > 1e-9 else {
            return nil
        }

        return atan2(y, x)
    }

    private func fallbackBlockedNodeIds(maxCount: Int) -> [String] {
        let safeMax = max(1, maxCount)
        let filtered = cachedRouteNodeIds
            .filter { $0 != activeStartNodeId && $0 != activeEndNodeId }

        return Array(filtered.prefix(safeMax))
    }

    private func loadMapGeoAnchorsFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.mapGeoAnchorsKey) else {
            return
        }

        guard let decoded = try? JSONDecoder().decode([MapGeoAnchor].self, from: data) else {
            return
        }

        mapGeoAnchorsByMapId = Dictionary(
            uniqueKeysWithValues: decoded.map { anchor in
                (anchor.mapId, anchor)
            }
        )
    }

    private func persistMapGeoAnchorsToDefaults() {
        let anchors = mapGeoAnchorsByMapId.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }

        guard let data = try? JSONEncoder().encode(anchors) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.mapGeoAnchorsKey)
    }

    private func upsertMapGeoAnchor(
            mapId: String,
            roomName: String?,
            latitude: Double,
            longitude: Double
    ) {
        guard !mapId.isEmpty else {
            return
        }

        let previous = mapGeoAnchorsByMapId[mapId]
        let mergedRoomName = roomName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRoomName: String?
        if let mergedRoomName, !mergedRoomName.isEmpty {
            resolvedRoomName = mergedRoomName
        } else {
            resolvedRoomName = previous?.roomName
        }

        mapGeoAnchorsByMapId[mapId] = MapGeoAnchor(
            mapId: mapId,
            roomName: resolvedRoomName,
            latitude: latitude,
            longitude: longitude,
            updatedAt: Date().timeIntervalSince1970
        )

        persistMapGeoAnchorsToDefaults()
    }

    private func refreshMapAnchorRoomNames(using maps: [ExistingMapRecord]) {
        var didMutate = false

        for map in maps {
            guard var anchor = mapGeoAnchorsByMapId[map.id] else {
                continue
            }

            if anchor.roomName?.localizedCaseInsensitiveCompare(map.roomName) == .orderedSame {
                continue
            }

            anchor.roomName = map.roomName
            mapGeoAnchorsByMapId[map.id] = anchor
            didMutate = true
        }

        if didMutate {
            persistMapGeoAnchorsToDefaults()
        }
    }

    private func haversineMeters(
            lat1: Double,
            lng1: Double,
            lat2: Double,
            lng2: Double
    ) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a =
            sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
            sin(dLng / 2) * sin(dLng / 2)

        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return r * c
    }

    private func url(forPath path: String) throws -> URL {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "\(apiBaseURL)\(normalizedPath)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func requestJSON(
            path: String,
            method: String,
            payload: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let url = try url(forPath: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(http.statusCode) else {
            let message = parseBackendErrorMessage(from: data) ?? "Request failed with status \(http.statusCode)"
            throw APIRequestError(statusCode: http.statusCode, message: message)
        }

        guard let json = try? JSONSerialization
            .jsonObject(with: data) as? [String: Any]
        else {
            throw URLError(.cannotParseResponse)
        }

        return json
    }

    private func parseBackendErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["message", "error", "detail", "details", "reason"]
            for key in keys {
                if let value = json[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }

        if let raw = String(data: data, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private func extractApiData(_ response: [String: Any]) throws -> [String: Any] {
        let success = response["success"] as? Bool ?? false
        if !success {
            let message = response["message"] as? String ?? "Backend request failed"
            throw NSError(
                domain: "APIService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return response["data"] as? [String: Any] ?? [:]
    }

    private func numberAsDouble(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String,
           let parsed = Double(value) {
            return parsed
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func jsonBlock(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    /// Compact log: `POST …` + small JSON.
    private static func logDryRunScan(_ payload: [String: Any]) {
        let api  = Self.normalizedApiBaseURL
        let maxP = 6
        let maxL = 4

        let allPoints = payload["points"] as? [[String: Any]] ?? []
        let allLm     = payload["landmarks"] as? [[String: Any]] ?? []
        let kf        = payload["keyframes"] as? [[String: Any]]
        let ds        = payload["depthSamples"] as? [[String: Any]]

        let slimPoints: [[String: Any]] = allPoints.prefix(maxP).map {
            ["x": $0["x"] as Any, "y": $0["y"] as Any, "z": $0["z"] as Any]
        }
        let slimLm: [[String: Any]] = allLm.prefix(maxL).map {
            [
                "x": $0["x"] as Any, "y": $0["y"] as Any, "z": $0["z"] as Any,
                "type": $0["type"] as Any, "label": $0["label"] as Any
            ]
        }

        let body: [String: Any] = [
            "userId":   payload["userId"] as Any,
            "roomName": payload["roomName"] as Any,
            "points":   slimPoints,
            "landmarks": slimLm
        ]

        print("POST \(api)/scans")
        print(jsonBlock(body))

        var parts: [String] = []
        if allPoints.count > maxP {
            parts.append("\(allPoints.count - maxP) more points")
        }
        if allLm.count > maxL {
            parts.append("\(allLm.count - maxL) more landmarks")
        }
        if let k = kf, !k.isEmpty { parts.append("\(k.count) keyframes") }
        if let d = ds, !d.isEmpty { parts.append("\(d.count) depth samples") }
        if !parts.isEmpty {
            print("// omitted: \(parts.joined(separator: ", "))")
        }
    }

    private static func logDryRunHazard(_ payload: [String: Any]) {
        print("POST \(Self.normalizedApiBaseURL)/hazards")
        print(jsonBlock(payload))
    }

    // ── Generic edge function caller ──────────────────
    func callFunction(
            name: String,
            payload: [String: Any]
    ) async throws -> [String: Any] {

        guard name == "ingest-scan" else {
            throw NSError(
                domain: "APIService",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unsupported function \(name). Use explicit API methods."
                ]
            )
        }

        if Constants.apiDryRun {
            Self.logDryRunScan(payload)
            return ["success": true, "dryRun": true]
        }

        return try await postScan(payload)
    }

    private func postScan(_ payload: [String: Any]) async throws -> [String: Any] {
        return try await requestJSON(path: "/scans", method: "POST", payload: payload)
    }

    func fetchScanProcessingStatus(scanId: String) async throws -> String {
        if Constants.apiDryRun {
            return "dry-run"
        }

        let response = try await requestJSON(
            path: "/scans/\(scanId)/processing",
            method: "GET"
        )
        let data = try extractApiData(response)

        return data["processing_status"] as? String
            ?? data["processingStatus"] as? String
            ?? "unknown"
    }

    func fetchScanDetections(scanId: String) async throws -> [[String: Any]] {
        if Constants.apiDryRun {
            return []
        }

        let response = try await requestJSON(
            path: "/scans/\(scanId)/detections",
            method: "GET"
        )
        let data = try extractApiData(response)
        return data["detections"] as? [[String: Any]] ?? []
    }

    func createMapFromScan(scanId: String, roomName: String) async throws -> String {
        let payload: [String: Any] = [
            "scanId": scanId,
            "roomName": roomName,
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/maps")
            print(Self.jsonBlock(payload))
            let dryMapId = "dry-map-\(scanId)"
            setActiveMapId(dryMapId)
            return dryMapId
        }

        let response = try await requestJSON(path: "/maps", method: "POST", payload: payload)
        let data = try extractApiData(response)
        guard let mapId = data["id"] as? String,
              !mapId.isEmpty
        else {
            throw NSError(
                domain: "APIService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Map creation response missing map id"]
            )
        }

        setActiveMapId(mapId)
        return mapId
    }

    func fetchMaps(
            roomName: String? = nil,
            limit: Int = 25,
            offset: Int = 0
    ) async throws -> [ExistingMapRecord] {
        if Constants.apiDryRun {
            return []
        }

        var components = URLComponents(string: "\(apiBaseURL)/maps")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]

        if let roomName,
           !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "roomName", value: roomName))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw URLError(.badServerResponse)
        }

        let apiData = try extractApiData(json)
        let rows = apiData["maps"] as? [[String: Any]] ?? []

        return rows.compactMap { row in
            guard let id = stringValue(row["id"]) else {
                return nil
            }

            return ExistingMapRecord(
                id: id,
                roomName: stringValue(row["room_name"]) ?? stringValue(row["roomName"]) ?? "Unlabeled Room",
                createdBy: stringValue(row["created_by"]) ?? stringValue(row["createdBy"]) ?? "",
                createdAt: stringValue(row["created_at"]) ?? stringValue(row["createdAt"]) ?? "",
                version: Int(numberAsDouble(row["version"]) ?? 1)
            )
        }
    }

    func fetchScans(
            roomName: String? = nil,
            limit: Int = 25,
            offset: Int = 0
    ) async throws -> [ExistingScanRecord] {
        if Constants.apiDryRun {
            return []
        }

        var components = URLComponents(string: "\(apiBaseURL)/scans")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]

        if let roomName,
           !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "roomName", value: roomName))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw URLError(.badServerResponse)
        }

        let apiData = try extractApiData(json)
        let rows = apiData["scans"] as? [[String: Any]] ?? []

        return rows.compactMap { row in
            guard let id = stringValue(row["id"]) else {
                return nil
            }

            return ExistingScanRecord(
                id: id,
                roomName: stringValue(row["room_name"]) ?? stringValue(row["roomName"]) ?? "Unlabeled Room",
                startedAt: stringValue(row["started_at"]) ?? stringValue(row["startedAt"]) ?? "",
                endedAt: stringValue(row["ended_at"]) ?? stringValue(row["endedAt"]) ?? "",
                processingStatus: stringValue(row["processing_status"]) ?? stringValue(row["processingStatus"]) ?? "unknown"
            )
        }
    }

    func bootstrapFromExistingData(
            preferredRoomName: String? = nil
    ) async throws -> ExistingNavigationBootstrapResult? {
        let preferredMaps = try await fetchMaps(roomName: preferredRoomName, limit: 25, offset: 0)
        let selectedMap: ExistingMapRecord?

        if let firstPreferred = preferredMaps.first {
            selectedMap = firstPreferred
        } else if preferredRoomName != nil {
            selectedMap = try await fetchMaps(limit: 25, offset: 0).first
        } else {
            selectedMap = nil
        }

        guard let selectedMap else {
            return nil
        }

        setActiveMapId(selectedMap.id)
        _ = try await fetchMapGraph(mapId: selectedMap.id)

        let landmarks = try await fetchMapLandmarks(mapId: selectedMap.id)
        let scans = try await fetchScans(roomName: selectedMap.roomName, limit: 25, offset: 0)

        return ExistingNavigationBootstrapResult(
            map: selectedMap,
            scans: scans,
            landmarks: landmarks
        )
    }

    func fetchRoomSuggestions(limit: Int = 20) async throws -> [String] {
        let clampedLimit = max(1, min(limit, 100))
        let maps = try? await fetchMaps(limit: clampedLimit, offset: 0)
        let scans = try? await fetchScans(limit: min(clampedLimit * 3, 100), offset: 0)

        if maps == nil && scans == nil {
            throw URLError(.badServerResponse)
        }

        var seen = Set<String>()
        var output: [String] = []

        func appendRoomSuggestion(_ candidate: String) {
            let room = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = room.lowercased()
            guard !room.isEmpty, !seen.contains(normalized) else {
                return
            }

            seen.insert(normalized)
            output.append(room)
        }

        for map in maps ?? [] {
            appendRoomSuggestion(map.roomName)
        }

        for scan in scans ?? [] {
            appendRoomSuggestion(scan.roomName)
        }

        return Array(output.prefix(clampedLimit))
    }

    func fetchMapGraph(mapId: String) async throws -> MapGraphResponse {
        if Constants.apiDryRun {
            return MapGraphResponse(nodes: [], edges: [])
        }

        let response = try await requestJSON(path: "/maps/\(mapId)/graph", method: "GET")
        let data = try extractApiData(response)

        let graph = MapGraphResponse(
            nodes: data["nodes"] as? [[String: Any]] ?? [],
            edges: data["edges"] as? [[String: Any]] ?? []
        )

        cacheMapNodes(nodes: graph.nodes)
        return graph
    }

    func createMapLandmark(
            mapId: String,
            type: String,
            label: String,
            x: Float,
            y: Float,
            z: Float,
            source: String = "user",
            headingDegrees: Double? = nil,
            confidence: Double? = nil
    ) async throws -> String {
        var payload: [String: Any] = [
            "type": type,
            "label": label,
            "x": x,
            "y": y,
            "z": z,
            "source": source,
        ]

        if let confidence {
            payload["confidence"] = confidence
        }

        if let headingDegrees,
           headingDegrees.isFinite,
           headingDegrees >= 0,
           headingDegrees < 360 {
            payload["headingDegrees"] = headingDegrees
        }

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/maps/\(mapId)/landmarks")
            print(Self.jsonBlock(payload))
            return "dry-landmark-\(UUID().uuidString)"
        }

        let response = try await requestJSON(
            path: "/maps/\(mapId)/landmarks",
            method: "POST",
            payload: payload
        )
        let data = try extractApiData(response)

        guard let landmarkId = data["id"] as? String,
              !landmarkId.isEmpty
        else {
            throw NSError(
                domain: "APIService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Map landmark response missing id"]
            )
        }

        return landmarkId
    }

    func fetchMapLandmarks(mapId: String) async throws -> [MapLandmarkRecord] {
        if Constants.apiDryRun {
            return []
        }

        let response = try await requestJSON(
            path: "/maps/\(mapId)/landmarks",
            method: "GET"
        )
        let success = response["success"] as? Bool ?? false
        if !success {
            let message = response["message"] as? String ?? "Failed to fetch map landmarks"
            throw NSError(
                domain: "APIService",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let rows = response["data"] as? [[String: Any]] ?? []

        return rows.compactMap { row in
            guard let id = stringValue(row["id"]) else {
                return nil
            }

            return MapLandmarkRecord(
                id: id,
                type: stringValue(row["type"]) ?? "unknown",
                label: stringValue(row["label"]) ?? "(unlabeled)",
                status: stringValue(row["status"]) ?? "pending",
                confidence: numberAsDouble(row["confidence"]),
                headingDegrees: numberAsDouble(row["heading_degrees"]) ?? numberAsDouble(row["headingDegrees"])
            )
        }
    }

    func verifyLandmark(
            landmarkId: String,
            status: String,
            notes: String? = nil,
            verifiedBy: String = DeviceIdentity.userId
    ) async throws {
        let payload: [String: Any] = [
            "status": status,
            "verifiedBy": verifiedBy,
            "notes": notes ?? "",
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/landmarks/\(landmarkId)/verify")
            print(Self.jsonBlock(payload))
            return
        }

        let response = try await requestJSON(
            path: "/landmarks/\(landmarkId)/verify",
            method: "POST",
            payload: payload
        )
        _ = try extractApiData(response)
    }

    func fetchMapVerificationSummary(mapId: String) async throws -> [String: Any] {
        if Constants.apiDryRun {
            return [:]
        }

        let response = try await requestJSON(
            path: "/maps/\(mapId)/verification-summary",
            method: "GET"
        )
        return try extractApiData(response)
    }

    func createMapContribution(
            mapId: String,
            contributionType: String,
            payload: [String: Any],
            notes: String? = nil,
            createdBy: String = DeviceIdentity.userId
    ) async throws -> MapContributionResult {
        let requestBody: [String: Any] = [
            "contributionType": contributionType,
            "payload": payload,
            "createdBy": createdBy,
            "status": "pending",
            "notes": notes ?? "",
            "createVersionOnAccept": false,
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/maps/\(mapId)/contributions")
            print(Self.jsonBlock(requestBody))
            return MapContributionResult(
                contributionId: "dry-contrib-\(UUID().uuidString)",
                status: "pending"
            )
        }

        let response = try await requestJSON(
            path: "/maps/\(mapId)/contributions",
            method: "POST",
            payload: requestBody
        )
        let data = try extractApiData(response)
        let contribution = data["contribution"] as? [String: Any] ?? [:]

        return MapContributionResult(
            contributionId: stringValue(contribution["id"]) ?? "",
            status: stringValue(contribution["status"]) ?? "pending"
        )
    }

    func generateRoute(
            mapId: String,
            startNodeId: String,
            endNodeId: String,
            blockedNodeIds: [String] = []
    ) async throws -> String {
        let payload: [String: Any] = [
            "mapId": mapId,
            "startNodeId": startNodeId,
            "endNodeId": endNodeId,
            "blockedNodeIds": blockedNodeIds,
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/navigation/routes")
            print(Self.jsonBlock(payload))
            let dryRouteId = "dry-route-\(mapId)"
            cachedRouteNodeIds = [startNodeId, endNodeId]
            setActiveRouteContext(
                mapId: mapId,
                routeId: dryRouteId,
                startNodeId: startNodeId,
                endNodeId: endNodeId
            )
            return dryRouteId
        }

        let response = try await requestJSON(
            path: "/navigation/routes",
            method: "POST",
            payload: payload
        )
        let data = try extractApiData(response)
        let routeId = data["routeId"] as? String
            ?? data["route_id"] as? String
        let routeNodeIds = (data["nodeIds"] as? [String])?.filter { !$0.isEmpty } ?? []

        guard let routeId, !routeId.isEmpty else {
            throw NSError(
                domain: "APIService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Route generation response missing route id"]
            )
        }

        cachedRouteNodeIds = routeNodeIds.isEmpty ? [startNodeId, endNodeId] : routeNodeIds

        setActiveRouteContext(
            mapId: mapId,
            routeId: routeId,
            startNodeId: startNodeId,
            endNodeId: endNodeId
        )
        return routeId
    }

    func generateRouteFromCoordinates(
            mapId: String,
            startX: Double,
            startY: Double,
            startZ: Double,
            endX: Double,
            endY: Double,
            endZ: Double,
            blockedNodeIds: [String] = []
    ) async throws -> String {
        let payload: [String: Any] = [
            "mapId": mapId,
            "start": [
                "x": startX,
                "y": startY,
                "z": startZ,
            ],
            "end": [
                "x": endX,
                "y": endY,
                "z": endZ,
            ],
            "blockedNodeIds": blockedNodeIds,
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/navigation/routes/from-coordinates")
            print(Self.jsonBlock(payload))
            let dryRouteId = "dry-route-coords-\(mapId)"
            let fallbackNodes = Array(cachedMapNodesById.keys.prefix(2))
            let startNodeId = fallbackNodes.first ?? "start-node"
            let endNodeId = (fallbackNodes.last ?? fallbackNodes.first) ?? "end-node"
            cachedRouteNodeIds = [startNodeId, endNodeId].filter { !$0.isEmpty }
            setActiveRouteContext(
                mapId: mapId,
                routeId: dryRouteId,
                startNodeId: startNodeId,
                endNodeId: endNodeId
            )
            return dryRouteId
        }

        let response = try await requestJSON(
            path: "/navigation/routes/from-coordinates",
            method: "POST",
            payload: payload
        )
        let data = try extractApiData(response)

        guard let routeId = stringValue(data["routeId"]), !routeId.isEmpty else {
            throw NSError(
                domain: "APIService",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Coordinate route response missing route id"]
            )
        }

        let startNodeId = stringValue(data["startNodeId"])
            ?? stringValue(data["start_node_id"])
            ?? ""
        let endNodeId = stringValue(data["endNodeId"])
            ?? stringValue(data["end_node_id"])
            ?? ""

        guard !startNodeId.isEmpty, !endNodeId.isEmpty else {
            throw NSError(
                domain: "APIService",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Coordinate route response missing resolved start/end nodes"]
            )
        }

        let routeNodeIds = (data["nodeIds"] as? [String])?.filter { !$0.isEmpty } ?? []
        cachedRouteNodeIds = routeNodeIds.isEmpty ? [startNodeId, endNodeId] : routeNodeIds

        setActiveRouteContext(
            mapId: mapId,
            routeId: routeId,
            startNodeId: startNodeId,
            endNodeId: endNodeId
        )

        return routeId
    }

    func generateRouteToRoom(
            mapId: String,
            startX: Double,
            startY: Double,
            startZ: Double,
            destinationLabel: String,
            blockedNodeIds: [String] = []
    ) async throws -> String {
        let payload: [String: Any] = [
            "mapId": mapId,
            "start": [
                "x": startX,
                "y": startY,
                "z": startZ,
            ],
            "destinationLabel": destinationLabel,
            "blockedNodeIds": blockedNodeIds,
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/navigation/routes/to-room")
            print(Self.jsonBlock(payload))
            let dryRouteId = "dry-route-room-\(mapId)"
            let fallbackNodes = Array(cachedMapNodesById.keys.prefix(2))
            let startNodeId = fallbackNodes.first ?? "start-node"
            let endNodeId = (fallbackNodes.last ?? fallbackNodes.first) ?? "end-node"
            cachedRouteNodeIds = [startNodeId, endNodeId].filter { !$0.isEmpty }
            setActiveRouteContext(
                mapId: mapId,
                routeId: dryRouteId,
                startNodeId: startNodeId,
                endNodeId: endNodeId
            )
            return dryRouteId
        }

        let response = try await requestJSON(
            path: "/navigation/routes/to-room",
            method: "POST",
            payload: payload
        )
        let data = try extractApiData(response)

        guard let routeId = stringValue(data["routeId"]), !routeId.isEmpty else {
            throw NSError(
                domain: "APIService",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Destination room route response missing route id"]
            )
        }

        let startNodeId = stringValue(data["startNodeId"])
            ?? stringValue(data["start_node_id"])
            ?? ""
        let endNodeId = stringValue(data["endNodeId"])
            ?? stringValue(data["end_node_id"])
            ?? ""

        guard !startNodeId.isEmpty, !endNodeId.isEmpty else {
            throw NSError(
                domain: "APIService",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Destination room route response missing start/end nodes"]
            )
        }

        let routeNodeIds = (data["nodeIds"] as? [String])?.filter { !$0.isEmpty } ?? []
        cachedRouteNodeIds = routeNodeIds.isEmpty ? [startNodeId, endNodeId] : routeNodeIds

        setActiveRouteContext(
            mapId: mapId,
            routeId: routeId,
            startNodeId: startNodeId,
            endNodeId: endNodeId
        )

        return routeId
    }

    func rerouteActiveRoute(
            reason: String,
            obstacleNodeIds: [String] = [],
            blockedNodeIds: [String] = []
    ) async throws -> String {
        guard let mapId = activeMapId,
              let startNodeId = activeStartNodeId,
              let endNodeId = activeEndNodeId
        else {
            throw NSError(
                domain: "APIService",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Missing active route context for reroute"]
            )
        }

        let payload: [String: Any] = [
            "mapId": mapId,
            "startNodeId": startNodeId,
            "endNodeId": endNodeId,
            "blockedNodeIds": blockedNodeIds,
            "obstacleNodeIds": obstacleNodeIds,
            "reason": reason,
        ]

        if Constants.apiDryRun {
            print("POST \(apiBaseURL)/navigation/reroute")
            print(Self.jsonBlock(payload))
            let dryRouteId = "dry-reroute-\(mapId)"
            setActiveRouteContext(
                mapId: mapId,
                routeId: dryRouteId,
                startNodeId: startNodeId,
                endNodeId: endNodeId
            )
            return dryRouteId
        }

        let response = try await requestJSON(
            path: "/navigation/reroute",
            method: "POST",
            payload: payload
        )
        let data = try extractApiData(response)
        guard let routeId = stringValue(data["routeId"]), !routeId.isEmpty else {
            throw NSError(
                domain: "APIService",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Reroute response missing route id"]
            )
        }

        if let nodeIds = data["nodeIds"] as? [String], !nodeIds.isEmpty {
            cachedRouteNodeIds = nodeIds.filter { !$0.isEmpty }
        }

        setActiveRouteContext(
            mapId: mapId,
            routeId: routeId,
            startNodeId: startNodeId,
            endNodeId: endNodeId
        )
        return routeId
    }

    // ── Fetch hazards near a location ─────────────────
    func fetchHazards(
            lat: Double,
            lng: Double,
            radiusMeters: Double = 50
    ) async throws -> [[String: Any]] {

        var components = URLComponents(string: "\(apiBaseURL)/hazards/nearby")
        components?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lng", value: String(lng)),
            URLQueryItem(name: "radius", value: String(radiusMeters))
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        if Constants.apiDryRun {
            print("GET \(url.absoluteString)")
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization
            .jsonObject(with: data) as? [String: Any]
        else { return [] }

        let apiData = json["data"] as? [String: Any]
        return apiData?["hazards"] as? [[String: Any]] ?? []
    }

    // ── Report a hazard ───────────────────────────────
    func reportHazard(
            type: String,
            label: String,
            lat: Double,
            lng: Double,
            userId: String = DeviceIdentity.userId
    ) async throws {
        _ = userId

        let payload: [String: Any] = [
            "type":       type,
            "lat":        lat,
            "lng":        lng,
            "description": label,
        ]

        if Constants.apiDryRun {
            Self.logDryRunHazard(payload)
            return
        }

        guard let url = URL(string: "\(apiBaseURL)/hazards")
        else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        print("Hazard reported: \(type) at \(lat),\(lng)")
    }

    // ── POST /api/navigate (Express-style) ────────────
    func postNavigate(_ payload: [String: Any]) async throws -> NavigationInstructionResponse {
        let urlStr = "\(apiBaseURL)/navigate"
        if Constants.apiDryRun {
            print("POST \(urlStr)")
            print(Self.jsonBlock(payload))
            return NavigationInstructionResponse(
                instruction: "Dry run guidance",
                urgency: "low",
                hapticPattern: "single_tap",
                nextCheckpoint: nil,
                distanceToNextM: nil,
                fallbackUsed: true
            )
        }

        let response = try await requestJSON(path: "/navigate", method: "POST", payload: payload)
        let data = try extractApiData(response)

        return NavigationInstructionResponse(
            instruction: data["instruction"] as? String ?? "Continue straight.",
            urgency: data["urgency"] as? String ?? "low",
            hapticPattern: data["haptic_pattern"] as? String ?? "single_tap",
            nextCheckpoint: data["next_checkpoint"] as? String,
            distanceToNextM: numberAsDouble(data["distance_to_next_m"]),
            fallbackUsed: data["fallback_used"] as? Bool ?? false
        )
    }

    // ── Realtime subscription (polling) ───────────────
    // polls for new hazards every N seconds
    // Uses polling for simplicity.
    func pollHazards(
            lat: Double,
            lng: Double,
            every seconds: TimeInterval = 10,
            onUpdate: @escaping ([[String: Any]]) -> Void
    ) {
        Timer.scheduledTimer(
                withTimeInterval: seconds,
                repeats: true) { _ in
            Task {
                do {
                    let hazards = try await self
                        .fetchHazards(lat: lat, lng: lng)
                    DispatchQueue.main.async {
                        onUpdate(hazards)
                    }
                } catch {
                    print("Poll error: \(error)")
                }
            }
        }
    }
}
