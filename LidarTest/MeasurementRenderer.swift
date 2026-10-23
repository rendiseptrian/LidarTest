import Foundation
import SceneKit
import simd

/// Draws measurement lines and endpoint markers.
///
/// Everything lives under `container`, a root-level node outside `meshContainer`: mesh hit tests
/// are rooted at `meshContainer`, so they never land on a marker, and chunk updates never touch
/// these nodes. Lines and markers draw on top of the mesh and keep a constant on-screen size;
/// the rescale runs every frame as the `SCNView` delegate, on SceneKit's render thread.
nonisolated final class MeasurementRenderer: NSObject, SCNSceneRendererDelegate {
    let container = SCNNode()

    private static let markerName = "measureMarker"
    private static let lineName = "measureLine"
    /// World size per metre of camera distance; roughly 5 pt marker radius and a 3 pt line at
    /// the default field of view.
    private static let markerScale: Float = 0.008
    private static let lineScale: Float = 0.0025

    private let markerGeometry: SCNSphere
    private let pendingMarkerGeometry: SCNSphere
    private let lineMaterial: SCNMaterial
    private var groups: [UUID: SCNNode] = [:]
    private var pendingMarker: SCNNode?

    override init() {
        markerGeometry = SCNSphere(radius: 1)
        markerGeometry.segmentCount = 16
        markerGeometry.materials = [Self.overlayMaterial(.white)]
        pendingMarkerGeometry = SCNSphere(radius: 1)
        pendingMarkerGeometry.segmentCount = 16
        pendingMarkerGeometry.materials = [Self.overlayMaterial(.systemOrange)]
        lineMaterial = Self.overlayMaterial(.systemYellow)
        container.name = "measurementContainer"
        super.init()
    }

    // MARK: - Main thread

    func sync(measurements: [RoomMeasurement], pending: SIMD3<Float>?, eye: SIMD3<Float>?) {
        let live = Set(measurements.map(\.id))
        for (id, group) in groups where !live.contains(id) {
            group.removeFromParentNode()
            groups[id] = nil
        }
        for measurement in measurements where groups[measurement.id] == nil {
            let group = makeGroup(for: measurement)
            container.addChildNode(group)
            groups[measurement.id] = group
        }

        if let pending {
            let marker = pendingMarker ?? makeMarker(pendingMarkerGeometry)
            marker.simdPosition = pending
            if marker.parent == nil { container.addChildNode(marker) }
            pendingMarker = marker
        } else {
            pendingMarker?.removeFromParentNode()
            pendingMarker = nil
        }

        // Size new nodes now so they do not flash at unit scale before the next frame.
        if let eye { Self.applyScreenScale(in: container, eye: eye) }
    }

    private func makeGroup(for measurement: RoomMeasurement) -> SCNNode {
        let group = SCNNode()
        for point in [measurement.start, measurement.end] {
            let marker = makeMarker(markerGeometry)
            marker.simdPosition = point
            group.addChildNode(marker)
        }

        let length = measurement.distance
        let cylinder = SCNCylinder(radius: 1, height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        cylinder.materials = [lineMaterial]
        let line = SCNNode(geometry: cylinder)
        line.name = Self.lineName
        line.simdPosition = measurement.midpoint
        line.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: measurement.delta / length)
        Self.configureOverlay(line)
        group.addChildNode(line)
        return group
    }

    private func makeMarker(_ geometry: SCNSphere) -> SCNNode {
        let marker = SCNNode(geometry: geometry)
        marker.name = Self.markerName
        Self.configureOverlay(marker)
        return marker
    }

    private static func configureOverlay(_ node: SCNNode) {
        node.castsShadow = false
        node.renderingOrder = 1_000
        node.simdScale = SIMD3<Float>(repeating: 0.001)
    }

    private static func overlayMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .constant
        // Always visible, even when the endpoint sits slightly inside a noisy wall.
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        return material
    }

    // MARK: - Render thread

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let pov = renderer.pointOfView else { return }
        Self.applyScreenScale(in: container, eye: pov.presentation.simdWorldPosition)
    }

    private static func applyScreenScale(in container: SCNNode, eye: SIMD3<Float>) {
        for node in container.childNodes {
            if node.name == markerName {
                scaleMarker(node, eye: eye)
            } else {
                for child in node.childNodes {
                    if child.name == lineName { scaleLine(child, eye: eye) } else { scaleMarker(child, eye: eye) }
                }
            }
        }
    }

    private static func scaleMarker(_ node: SCNNode, eye: SIMD3<Float>) {
        let r = simd_distance(eye, node.simdWorldPosition) * markerScale
        setScale(node, SIMD3<Float>(repeating: r))
    }

    /// Width follows the closest point on the segment, so a long line stays thin up close.
    private static func scaleLine(_ node: SCNNode, eye: SIMD3<Float>) {
        guard let cylinder = node.geometry as? SCNCylinder else { return }
        let half = Float(cylinder.height) / 2
        let axis = node.simdWorldOrientation.act(SIMD3<Float>(0, 1, 0))
        let center = node.simdWorldPosition
        let t = Swift.min(Swift.max(simd_dot(eye - center, axis), -half), half)
        let r = simd_distance(eye, center + axis * t) * lineScale
        setScale(node, SIMD3<Float>(r, 1, r))
    }

    /// Writing an unchanged scale would still mark the scene dirty and keep SceneKit rendering.
    private static func setScale(_ node: SCNNode, _ scale: SIMD3<Float>) {
        let current = node.simdScale
        guard simd_length(current - scale) > current.x * 0.01 else { return }
        node.simdScale = scale
    }
}
