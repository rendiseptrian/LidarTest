import AppKit
import SceneKit
import simd

extension SceneKitMeshView.Coordinator: NSGestureRecognizerDelegate {
    /// A click recognizer fails as soon as the mouse moves, so a click-drag still orbits through
    /// the camera controller and only a clean click places a point.
    func installMeasureClick(on scnView: SCNView) {
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleMeasureClick(_:)))
        click.delegate = self
        click.delaysPrimaryMouseButtonEvents = false
        click.delaysSecondaryMouseButtonEvents = false
        click.delaysOtherMouseButtonEvents = false
        click.isEnabled = false
        scnView.addGestureRecognizer(click)
        measureClick = click
    }

    public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        true
    }

    /// Called from `updateNSView` whenever the store publishes.
    func syncMeasurements() {
        guard let store = measurements else { return }
        measureClick?.isEnabled = store.isActive
        measurementRenderer.sync(measurements: store.measurements, pending: store.pendingPoint,
                                 eye: scnView?.pointOfView?.presentation.simdWorldPosition)
    }

    /// The measurement label's anchor in SwiftUI's top-left-origin coordinates, or nil when the
    /// point is behind the camera.
    public func screenPoint(of world: SIMD3<Float>) -> CGPoint? {
        guard let scnView else { return nil }
        let p = scnView.projectPoint(SCNVector3(world))
        guard p.z > 0, p.z < 1 else { return nil }
        return CGPoint(x: p.x, y: scnView.bounds.height - p.y)
    }

    @objc private func handleMeasureClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended, let store = measurements, store.isActive,
              let scnView, let meshContainer else { return }

        // Rooted at the mesh container: the floor grid and the measurement nodes are not hit.
        let hits = scnView.hitTest(gesture.location(in: scnView), options: [
            .rootNode: meshContainer,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
        ])
        guard let hit = hits.first else { return }

        var point = hit.simdWorldCoordinates
        if NSEvent.modifierFlags.contains(.option), let vertex = Self.nearestVertex(of: hit) {
            point = vertex
        }
        store.place(point)
    }

    /// The hit triangle's corner closest to the hit point, in world space. Reads the indices of
    /// the element that was hit, so it works for the per-classification split as well.
    private static func nearestVertex(of hit: SCNHitTestResult) -> SIMD3<Float>? {
        guard let geometry = hit.node.geometry,
              hit.geometryIndex >= 0, hit.geometryIndex < geometry.elements.count,
              let source = geometry.sources(for: .vertex).first,
              source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else {
            return nil
        }
        let element = geometry.elements[hit.geometryIndex]
        guard element.primitiveType == .triangles, element.bytesPerIndex == 4,
              hit.faceIndex >= 0, hit.faceIndex < element.primitiveCount else { return nil }

        let indexData = element.data
        let vertexData = source.data
        let local = hit.simdLocalCoordinates
        var best: SIMD3<Float>?
        var bestDistance = Float.greatestFiniteMagnitude

        for corner in 0..<3 {
            let indexOffset = (hit.faceIndex * 3 + corner) * 4
            guard indexOffset + 4 <= indexData.count else { return nil }
            let index = Int(indexData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: indexOffset, as: Int32.self) })
            let offset = source.dataOffset + index * source.dataStride
            guard index >= 0, index < source.vectorCount, offset + 12 <= vertexData.count else { return nil }
            let vertex = vertexData.withUnsafeBytes { raw in
                SIMD3<Float>(raw.loadUnaligned(fromByteOffset: offset, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: offset + 4, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: offset + 8, as: Float32.self))
            }
            let d = simd_distance(vertex, local)
            if d < bestDistance {
                bestDistance = d
                best = vertex
            }
        }
        guard let best else { return nil }
        let world = hit.node.simdWorldTransform * SIMD4<Float>(best, 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
