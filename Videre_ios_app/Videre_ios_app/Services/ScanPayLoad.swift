//
//  ScanPayLoad.swift
//  Videre
//
//  Created by Ngan Nguyen on 4/12/26.
//

import Foundation

struct ScanPayload: Codable {
    var scanId:            String
    var userId:            String
    var roomName:          String
    var startedAt:         String
    var endedAt:           String
    var device:            DeviceInfo
    var arTrackingQuality: String
    var coordinateSystem:  CoordinateSystem
    var points:            [TrajectoryPoint]
    var landmarks:         [Landmark]
    var keyframes:         [Keyframe]
    var depthSamples:      [DepthSample]
    var sequenceNumber:    Int
    var checksum:          String
    var offlineSync:       Bool
    var retryCount:        Int
    var idempotencyKey:    String
}

struct DeviceInfo: Codable {
    var model:      String
    var osVersion:  String
    var appVersion: String
}

struct CoordinateSystem: Codable {
    var origin: String
    var units:  String
}

struct TrajectoryPoint: Codable {
    var x:                  Float
    var y:                  Float
    var z:                  Float
    var timestamp:          Int64
    var latitude:           Double? = nil
    var longitude:          Double? = nil
    var horizontalAccuracy: Float? = nil
    var verticalAccuracy:   Float? = nil
    var headingDegrees:     Double? = nil
    var trackingState:      String? = nil
}

struct Landmark: Codable {
    var type:      String
    var label:     String
    var x:         Float
    var y:         Float
    var z:         Float
    var source:    String
    var timestamp: Int64
    var headingDegrees:     Double? = nil
    var latitude:           Double? = nil
    var longitude:          Double? = nil
    var horizontalAccuracy: Float? = nil
    var verticalAccuracy:   Float? = nil
}

struct Keyframe: Codable {
    var imageBase64: String
    var imageUrl:   String?
    var timestamp:  Int64
    var cameraPose: CameraPose
    var fx:         Float?
    var fy:         Float?
    var cx:         Float?
    var cy:         Float?
}

struct DepthSample: Codable {
    var timestamp:  Int64
    var cameraPose: CameraPose
    var depthUrl:   String
}

struct CameraPose: Codable {
    var x: Float
    var y: Float
    var z: Float
}

// ── Codable → Dictionary ──────────────────────────────
extension Encodable {
    func toDictionary() -> [String: Any]? {
        guard
            let data = try? JSONEncoder().encode(self),
            let dict = try? JSONSerialization
                            .jsonObject(with: data)
                            as? [String: Any]
        else { return nil }
        return dict
    }
}
