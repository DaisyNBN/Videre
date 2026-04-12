//
//  SupabaseService.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation

class SupabaseService {

    static let shared = SupabaseService()

    private let baseURL = Secrets.supabaseURL
    private let anonKey = Secrets.supabaseAnonKey

    private static func jsonBlock(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    /// Compact log: `POST …` + small JSON (not full Supabase URLs).
    private static func logDryRunScan(_ payload: [String: Any]) {
        let api  = Constants.apiLogBaseURL
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
        let body: [String: Any] = [
            "user_id":     payload["user_id"] as Any,
            "lat":         payload["lat"] as Any,
            "lng":         payload["lng"] as Any,
            "type":        payload["type"] as Any,
            "description": payload["label"] as Any
        ]
        print("POST \(Constants.apiLogBaseURL)/hazards")
        print(jsonBlock(body))
    }

    private static func logDryRunSession(_ payload: [String: Any]) {
        var body = payload
        if let path = payload["path"] as? [[Double]], path.count > 3 {
            var copy = payload
            copy["path"] = Array(path.prefix(3))
            body = copy
            print("POST \(Constants.apiLogBaseURL)/sessions")
            print(jsonBlock(body))
            print("// omitted: \(path.count - 3) more path points")
        } else {
            print("POST \(Constants.apiLogBaseURL)/sessions")
            print(jsonBlock(body))
        }
    }

    // ── Generic edge function caller ──────────────────
    func callFunction(
            name: String,
            payload: [String: Any]
    ) async throws -> [String: Any] {

        let urlStr = "\(baseURL)/functions/v1/\(name)"
        if Constants.supabaseDryRun {
            if name == "ingest-scan" {
                Self.logDryRunScan(payload)
            } else {
                print("POST \(Constants.apiLogBaseURL)/\(name)")
                print(Self.jsonBlock(payload))
            }
            return ["success": true, "dryRun": true]
        }

        guard let url = URL(string: urlStr)
        else {
            throw URLError(.badURL)
        }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(anonKey)",
            forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(
                                    withJSONObject: payload)

        let (data, response) = try await URLSession
                                            .shared
                                            .data(for: request)

        // check HTTP status
        if let http = response as? HTTPURLResponse {
            print("Function \(name) status: \(http.statusCode)")
            if http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
        }

        guard let json = try? JSONSerialization
                             .jsonObject(with: data)
                             as? [String: Any]
        else {
            throw URLError(.cannotParseResponse)
        }

        return json
    }

    // ── Read from a table ─────────────────────────────
    func select(
            table: String,
            query: String = ""
    ) async throws -> [[String: Any]] {

        let urlStr = "\(baseURL)/rest/v1/\(table)\(query)"
        if Constants.supabaseDryRun {
            print("GET \(Constants.apiLogBaseURL)/\(table) (dry run)")
            return []
        }

        guard let url = URL(string: urlStr)
        else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(anonKey)",
            forHTTPHeaderField: "Authorization")
        request.setValue(
            anonKey,
            forHTTPHeaderField: "apikey")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")

        let (data, _) = try await URLSession
                                      .shared
                                      .data(for: request)

        guard let json = try? JSONSerialization
                             .jsonObject(with: data)
                             as? [[String: Any]]
        else { return [] }

        return json
    }

    // ── Insert into a table ───────────────────────────
    func insert(
            table: String,
            payload: [String: Any]
    ) async throws {

        if Constants.supabaseDryRun {
            switch table {
            case "hazards":
                Self.logDryRunHazard(payload)
            case "sessions":
                Self.logDryRunSession(payload)
            default:
                print("POST \(Constants.apiLogBaseURL)/\(table)")
                print(Self.jsonBlock(payload))
            }
            return
        }

        guard let url = URL(
            string: "\(baseURL)/rest/v1/\(table)")
        else { throw URLError(.badURL) }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(anonKey)",
            forHTTPHeaderField: "Authorization")
        request.setValue(
            anonKey,
            forHTTPHeaderField: "apikey")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        request.setValue(
            "return=minimal",
            forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(
                                    withJSONObject: payload)

        let (_, response) = try await URLSession
                                          .shared
                                          .data(for: request)

        if let http = response as? HTTPURLResponse {
            print("Insert \(table) status: \(http.statusCode)")
        }
    }

    // ── Fetch hazards near a location ─────────────────
    func fetchHazards(
            lat: Double,
            lng: Double,
            radiusMeters: Double = 50
    ) async throws -> [[String: Any]] {

        // query hazards within bounding box
        // simple approximation — 1 degree ≈ 111km
        let delta  = radiusMeters / 111000.0
        let minLat = lat - delta
        let maxLat = lat + delta
        let minLng = lng - delta
        let maxLng = lng + delta

        let query = "?lat=gte.\(minLat)" +
                    "&lat=lte.\(maxLat)" +
                    "&lng=gte.\(minLng)" +
                    "&lng=lte.\(maxLng)" +
                    "&order=created_at.desc" +
                    "&limit=20"

        return try await select(
            table: "hazards",
            query: query
        )
    }

    // ── Report a hazard ───────────────────────────────
    func reportHazard(
            type: String,
            label: String,
            lat: Double,
            lng: Double,
            userId: String = DeviceIdentity.userId
    ) async throws {

        let payload: [String: Any] = [
            "type":       type,
            "label":      label,
            "lat":        lat,
            "lng":        lng,
            "user_id":    userId,
            "created_at": ISO8601DateFormatter()
                              .string(from: Date())
        ]

        try await insert(table: "hazards",
                         payload: payload)
        if !Constants.supabaseDryRun {
            print("Hazard reported: \(type) at \(lat),\(lng)")
        }
    }

    // ── Save walk session ─────────────────────────────
    func saveSession(
            userId: String,
            startedAt: Date,
            endedAt: Date,
            distanceMeters: Double,
            obstacleCount: Int,
            path: [[Double]]
    ) async throws {

        let payload: [String: Any] = [
            "user_id":        userId,
            "started_at":     ISO8601DateFormatter()
                                  .string(from: startedAt),
            "ended_at":       ISO8601DateFormatter()
                                  .string(from: endedAt),
            "distance_m":     distanceMeters,
            "obstacle_count": obstacleCount,
            "path":           path
        ]

        try await insert(table: "sessions",
                         payload: payload)
        if !Constants.supabaseDryRun {
            print("Session saved: \(distanceMeters)m")
        }
    }

    // ── Fetch walk history ────────────────────────────
    func fetchSessions(
            userId: String,
            limit: Int = 10
    ) async throws -> [[String: Any]] {

        let query = "?user_id=eq.\(userId)" +
                    "&order=started_at.desc" +
                    "&limit=\(limit)"

        return try await select(
            table: "sessions",
            query: query
        )
    }

    // ── Upload file to storage ────────────────────────
    func uploadFile(
            bucket: String,
            name: String,
            data: Data,
            contentType: String
    ) async throws -> String {

        let urlStr = "\(baseURL)/storage/v1/object/\(bucket)/\(name)"
        if Constants.supabaseDryRun {
            return urlStr
        }

        guard let url = URL(string: urlStr)
        else { throw URLError(.badURL) }

        var request        = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(anonKey)",
            forHTTPHeaderField: "Authorization")
        request.setValue(
            contentType,
            forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await URLSession
                                          .shared
                                          .data(for: request)

        if let http = response as? HTTPURLResponse {
            print("Upload \(name) status: \(http.statusCode)")
        }

        return urlStr
    }

    // ── POST /api/navigate (Express-style) ────────────
    func postNavigate(_ payload: [String: Any]) async throws {
        let urlStr = "\(Constants.apiLogBaseURL)/navigate"
        if Constants.supabaseDryRun {
            print("POST \(urlStr)")
            print(Self.jsonBlock(payload))
            return
        }

        guard let url = URL(string: urlStr)
        else { throw URLError(.badURL) }

        var request        = URLRequest(url: url)
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
    }

    // ── Realtime subscription (polling) ───────────────
    // polls for new hazards every N seconds
    // real Supabase realtime needs websocket library
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
