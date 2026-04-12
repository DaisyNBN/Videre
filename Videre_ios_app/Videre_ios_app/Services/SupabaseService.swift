//
//  APIService.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation

final class APIService {

    static let shared = APIService()
    private init() {}

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
        let urlStr = "\(apiBaseURL)/scans"
        guard let url = URL(string: urlStr) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization
            .jsonObject(with: data) as? [String: Any]
        else {
            throw URLError(.cannotParseResponse)
        }

        return json
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
    func postNavigate(_ payload: [String: Any]) async throws {
        let urlStr = "\(apiBaseURL)/navigate"
        if Constants.apiDryRun {
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
