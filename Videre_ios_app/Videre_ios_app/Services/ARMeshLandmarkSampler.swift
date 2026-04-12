import ARKit
import simd

// Per Apple docs — not a framework method on all SDKs.
extension ARMeshGeometry {
    fileprivate func classificationOf(
            faceWithIndex index: Int) -> ARMeshClassification {
        guard let source = classification else { return .none }
        guard index >= 0, index < faces.count else { return .none }
        let offset = source.offset + index * source.stride
        let raw = source.buffer.contents()
            .load(fromByteOffset: offset, as: UInt8.self)
        return ARMeshClassification(rawValue: Int(raw)) ?? .none
    }
}

/// Sample classified scene mesh (door / wall / window) near the camera while scanning.
enum ARMeshLandmarkSampler {

    /// Closest classified surface in front of the camera (for navigate `obstacles[].label`).
    /// Returns `nil` if mesh classification is unavailable or nothing matches in the cone.
    static func nearestObstacleLabel(frame: ARFrame) -> String? {

        let camT = frame.camera.transform
        let camPos = simd_float3(camT.columns.3.x,
                                 camT.columns.3.y,
                                 camT.columns.3.z)
        let forward = simd_normalize(
            -simd_float3(camT.columns.2.x,
                         camT.columns.2.y,
                         camT.columns.2.z))

        let maxDistance: Float = 3.0
        let minDistance: Float = 0.35
        let minForwardDot: Float = 0.25

        var bestDist = Float.greatestFiniteMagnitude
        var bestLabel: String?

        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let geometry = mesh.geometry
            let faceCount = geometry.faces.count
            guard faceCount > 0 else { continue }

            let stride = max(1, faceCount / 400)

            for faceIndex in Swift.stride(
                    from: 0,
                    to: faceCount,
                    by: stride) {

                let classification = geometry.classificationOf(
                    faceWithIndex: faceIndex)
                let label: String? = {
                    switch classification {
                    case .door:   return "door"
                    case .wall:   return "wall"
                    case .window: return "window"
                    case .ceiling: return "ceiling"
                    case .floor:  return "floor"
                    case .table:  return "table"
                    case .seat:   return "seat"
                    default:      return nil
                    }
                }()
                guard let l = label else { continue }

                guard let centroid = faceCentroidWorld(
                    geometry: geometry,
                    faceIndex: faceIndex,
                    anchorTransform: mesh.transform)
                else { continue }

                let delta = centroid - camPos
                let dist = simd_length(delta)
                guard dist > minDistance && dist < maxDistance else { continue }

                let dir = delta / dist
                guard simd_dot(forward, dir) >= minForwardDot else { continue }

                if dist < bestDist {
                    bestDist = dist
                    bestLabel = l
                }
            }
        }

        return bestLabel
    }

    /// Returns up to `maxHits` landmark suggestions in world space (meters).
    static func landmarksNearCamera(
        frame: ARFrame,
        maxHits: Int = 2,
        maxDistance: Float = 3.0,
        minDistance: Float = 0.35,
        minForwardDot: Float = 0.25
    ) -> [(type: String, label: String, position: simd_float3)] {

        let camT = frame.camera.transform
        let camPos = simd_float3(camT.columns.3.x,
                                 camT.columns.3.y,
                                 camT.columns.3.z)
        let forward = simd_normalize(
            -simd_float3(camT.columns.2.x,
                         camT.columns.2.y,
                         camT.columns.2.z))

        var out: [(String, String, simd_float3)] = []

        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            let geometry = mesh.geometry
            let faceCount = geometry.faces.count
            guard faceCount > 0 else { continue }

            // Mesh can be huge — sample faces so we stay real-time.
            let stride = max(1, faceCount / 400)

            for faceIndex in Swift.stride(
                    from: 0,
                    to: faceCount,
                    by: stride) {
                guard out.count < maxHits else { break }

                let classification = geometry.classificationOf(
                    faceWithIndex: faceIndex)
                let typeAndLabel: (String, String)? = {
                    switch classification {
                    case .door:   return ("door", "ARKit door")
                    case .wall:   return ("wall", "ARKit wall")
                    case .window: return ("window", "ARKit window")
                    default:      return nil
                    }
                }()
                guard let (t, l) = typeAndLabel else { continue }

                guard let centroid = faceCentroidWorld(
                    geometry: geometry,
                    faceIndex: faceIndex,
                    anchorTransform: mesh.transform)
                else { continue }

                let delta = centroid - camPos
                let dist = simd_length(delta)
                guard dist > minDistance && dist < maxDistance else { continue }

                let dir = delta / dist
                guard simd_dot(forward, dir) >= minForwardDot else { continue }

                out.append((t, l, centroid))
            }
            if out.count >= maxHits { break }
        }

        return out
    }

    private static func faceCentroidWorld(
        geometry: ARMeshGeometry,
        faceIndex: Int,
        anchorTransform: simd_float4x4
    ) -> simd_float3? {

        let faces     = geometry.faces
        let vertices  = geometry.vertices
        let perFace   = faces.indexCountPerPrimitive
        guard perFace == 3,
              faceIndex >= 0,
              faceIndex < faces.count,
              faces.bytesPerIndex == MemoryLayout<UInt32>.size
        else { return nil }

        let indexBytes = faces.buffer.contents()
        var sum = simd_float3.zero

        for v in 0..<perFace {
            let off = (faceIndex * perFace + v) * faces.bytesPerIndex
            let vIdx = indexBytes.load(
                fromByteOffset: off,
                as: UInt32.self)

            let vRaw = vertices.buffer.contents()
                .advanced(by: vertices.offset
                    + Int(vIdx) * vertices.stride)
            let local = vRaw.assumingMemoryBound(
                to: simd_float3.self).pointee

            let world = anchorTransform * simd_float4(local, 1)
            sum += simd_float3(world.x, world.y, world.z)
        }

        return sum / Float(perFace)
    }
}
