import Foundation
import simd

/// The map's own coordinate system, on top of ARKit's.
///
/// ARKit's world origin is wherever the iPhone was when scanning started, and its 0° heading is
/// whichever way the phone faced (only "up" is fixed, by gravity). So two scans of the same room
/// come out shifted and rotated differently. A map frame fixes that without touching the raw
/// data: it is one origin + one rotation about the vertical axis, applied when displaying (the
/// floor grid and camera) and when exporting. Distances are unaffected, and measurements stay
/// stored in raw ARKit coordinates, so re-aligning never moves them.
///
///     map = rotateY(−yaw) · (world − origin)
nonisolated struct MapFrame: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// ARKit's frame as-is: origin where scanning started.
        case scanOrigin
        /// Walls along the X/Z axes, floor at y = 0, origin at the plan's corner. Follows the scan.
        case autoAligned
        /// Set by the user from a measurement: start point = origin, direction = +X. Frozen.
        case manual
    }

    var mode: Mode
    var origin: SIMD3<Float>
    /// Radians, about +Y.
    var yaw: Float

    static let scanOrigin = MapFrame(mode: .scanOrigin, origin: .zero, yaw: 0)

    var worldToMap: simd_float4x4 {
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(-origin, 1)
        return simd_float4x4(simd_quatf(angle: -yaw, axis: [0, 1, 0])) * translate
    }

    var mapToWorld: simd_float4x4 { worldToMap.inverse }

    func toMap(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let m = worldToMap * SIMD4(p, 1)
        return SIMD3(m.x, m.y, m.z)
    }

    // MARK: - Building

    /// Origin at the measurement's start, +X along it (projected onto the floor plane).
    static func fromMeasurement(start: SIMD3<Float>, end: SIMD3<Float>) -> MapFrame? {
        let d = end - start
        guard simd_length(SIMD2(d.x, d.z)) > 0.01 else { return nil } // a vertical line has no heading
        return MapFrame(mode: .manual, origin: start, yaw: atan2(-d.z, d.x))
    }

    /// Walls → axes, floor → y = 0, plan corner → origin. Prefers RoomPlan walls (exact planes);
    /// falls back to the LiDAR mesh's vertical faces. Nil when there is nothing to align to.
    static func autoAligned(layout: RoomLayout?, payloads: [MeshChunkPayload]) -> MapFrame? {
        guard let yaw = dominantYaw(layout: layout, payloads: payloads) else { return nil }
        let rotation = simd_float3x3(simd_quatf(angle: -yaw, axis: [0, 1, 0]))

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var floorY: Float?
        func include(_ p: SIMD3<Float>) {
            let q = rotation * p
            lo = simd_min(lo, q)
            hi = simd_max(hi, q)
        }

        if let layout, !layout.isEmpty {
            for surface in layout.surfaces {
                let (a, b) = surface.endpoints
                include(a)
                include(b)
            }
            layout.objects.flatMap(\.footprint).forEach(include)
            // Floor height: RoomPlan's floor surfaces if any, else the bottom edge of the walls.
            let floors = layout.surfaces.filter { $0.kind == .floor }.map(\.center.y)
            let wallBottoms = layout.surfaces.filter { $0.kind == .wall }.map { $0.center.y - $0.height / 2 }
            floorY = floors.min() ?? wallBottoms.min()
        }
        var meshFloorSamples: [Float] = []
        forEachSampledFace(payloads) { a, b, c, cls in
            include(a)
            include(b)
            include(c)
            if cls == 2 { meshFloorSamples.append((a.y + b.y + c.y) / 3) }
        }
        guard lo.x <= hi.x else { return nil }

        if floorY == nil {
            if !meshFloorSamples.isEmpty {
                meshFloorSamples.sort()
                floorY = meshFloorSamples[meshFloorSamples.count / 2]
            } else {
                floorY = lo.y
            }
        }

        let cornerRotated = SIMD3<Float>(lo.x, 0, lo.z)
        var origin = simd_float3x3(simd_quatf(angle: yaw, axis: [0, 1, 0])) * cornerRotated
        origin.y = floorY ?? 0
        return MapFrame(mode: .autoAligned, origin: origin, yaw: yaw)
    }

    /// The wall direction, modulo 90°, as a weighted circular mean of 4θ (so walls at θ and
    /// θ ± 90° reinforce instead of cancelling). Returned as the yaw that maps them onto the axes.
    private static func dominantYaw(layout: RoomLayout?, payloads: [MeshChunkPayload]) -> Float? {
        var sum = SIMD2<Double>.zero

        if let layout {
            for wall in layout.surfaces where wall.kind == .wall {
                let r = wall.right
                let theta = Double(atan2(r.z, r.x))
                sum += Double(wall.width) * SIMD2(cos(4 * theta), sin(4 * theta))
            }
        }
        if simd_length(sum) < 1e-6 {
            forEachSampledFace(payloads) { a, b, c, _ in
                let n = simd_cross(b - a, c - a)
                let area = simd_length(n)
                guard area > 1e-9, abs(n.y / area) < 0.3 else { return } // vertical faces only
                let theta = Double(atan2(n.z, n.x)) + .pi / 2 // wall runs perpendicular to its normal
                sum += Double(area) * SIMD2(cos(4 * theta), sin(4 * theta))
            }
        }
        guard simd_length(sum) > 1e-6 else { return nil }
        let wallAngle = atan2(sum.y, sum.x) / 4
        return Float(-wallAngle)
    }

    /// World-space triangles, at most ~60k of them, so auto-alignment stays cheap on huge scans.
    private static func forEachSampledFace(_ payloads: [MeshChunkPayload],
                                           _ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, UInt8) -> Void) {
        let total = payloads.reduce(0) { $0 + $1.faceCount }
        guard total > 0 else { return }
        let stride = max(1, total / 60_000)
        for payload in payloads where payload.action == .addOrUpdate {
            let v = ScanFileIO.worldVertices(payload)
            let faces = ScanFileIO.faceIndices(payload)
            let classes = ScanFileIO.faceClasses(payload)
            guard !v.isEmpty, faces.count == payload.faceCount * 3 else { continue }
            for f in Swift.stride(from: 0, to: payload.faceCount, by: stride) {
                let ia = Int(faces[f * 3]), ib = Int(faces[f * 3 + 1]), ic = Int(faces[f * 3 + 2])
                guard ia < v.count, ib < v.count, ic < v.count, classes[f] != 3 else { continue } // skip ceiling
                body(v[ia], v[ib], v[ic], classes[f])
            }
        }
    }
}
