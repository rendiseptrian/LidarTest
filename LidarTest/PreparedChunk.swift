import Foundation
import SceneKit
import simd

/// A chunk made ready for the scene off the main thread: geometry built and world bounds measured.
nonisolated struct PreparedChunk: @unchecked Sendable {
    let payload: MeshChunkPayload
    let geometry: SCNGeometry?
    let mode: MeshRenderMode
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    /// 0 for chunks from the network; otherwise the chunk version a render-mode rebuild was made from.
    let rebuildOfVersion: Int
    let wireBytes: Int

    var hasBounds: Bool { boundsMin.x <= boundsMax.x }

    static func make(_ payload: MeshChunkPayload, mode: MeshRenderMode, wireBytes: Int, rebuildOfVersion: Int = 0) -> PreparedChunk {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var geometry: SCNGeometry?

        if payload.action == .addOrUpdate {
            geometry = MeshGeometryHelper.makeGeometry(from: payload, mode: mode)

            // Every vertex, not a sample: these bounds feed the room dimensions readout.
            let count = payload.vertexCount
            if count > 0, payload.vertexData.count >= count * 12 {
                let transform = payload.transform
                payload.vertexData.withUnsafeBytes { raw in
                    let floats = raw.bindMemory(to: Float32.self)
                    for i in 0..<count {
                        let local = SIMD4<Float>(floats[i * 3], floats[i * 3 + 1], floats[i * 3 + 2], 1)
                        let world = transform * local
                        let p = SIMD3<Float>(world.x, world.y, world.z)
                        lo = simd_min(lo, p)
                        hi = simd_max(hi, p)
                    }
                }
            }
        }

        return PreparedChunk(payload: payload, geometry: geometry, mode: mode, boundsMin: lo, boundsMax: hi,
                             rebuildOfVersion: rebuildOfVersion, wireBytes: wireBytes)
    }
}

/// Lets background build work read the current render mode without touching the main actor.
nonisolated final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
