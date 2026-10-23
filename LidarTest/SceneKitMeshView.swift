import SwiftUI
import SceneKit
import simd

public struct SceneKitMeshView: NSViewRepresentable {
    @ObservedObject public var receiver: MeshReceiver
    @ObservedObject public var measurements: MeasurementStore

    public init(receiver: MeshReceiver, measurements: MeasurementStore) {
        self.receiver = receiver
        self.measurements = measurements
    }

    public func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView(frame: .zero)
        let scene = SCNScene()
        scnView.scene = scene
        scnView.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X

        // 1. Camera Node with Headlight & Screen Space Ambient Occlusion (SSAO)
        let cameraNode = SCNNode()
        cameraNode.name = "mainCamera"
        let camera = SCNCamera()
        camera.zNear = 0.05
        camera.zFar = 100.0
        camera.wantsHDR = true
        camera.screenSpaceAmbientOcclusionIntensity = 2.0
        camera.screenSpaceAmbientOcclusionRadius = 0.7
        camera.screenSpaceAmbientOcclusionBias = 0.02
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.5
        camera.screenSpaceAmbientOcclusionNormalThreshold = 0.5
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(x: 0, y: 1.8, z: 3.5)
        cameraNode.eulerAngles = SCNVector3(x: -0.35, y: 0, z: 0)

        // Headlight ensures surfaces facing the user are never unlit
        let headlight = SCNNode()
        headlight.light = SCNLight()
        headlight.light?.type = .directional
        headlight.light?.color = NSColor(white: 0.35, alpha: 1.0)
        cameraNode.addChildNode(headlight)
        scene.rootNode.addChildNode(cameraNode)

        // 2. Lighting Setup (Key Light + Fill Light + Ambient)
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = NSColor(white: 0.45, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light?.type = .directional
        dirLight.light?.color = NSColor(white: 0.85, alpha: 1.0)
        dirLight.light?.castsShadow = true
        dirLight.light?.shadowMode = .deferred
        dirLight.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        dirLight.light?.shadowSampleCount = 16
        dirLight.light?.shadowRadius = 8.0
        dirLight.light?.shadowColor = NSColor.black.withAlphaComponent(0.35)
        dirLight.position = SCNVector3(x: 6, y: 12, z: 8)
        dirLight.eulerAngles = SCNVector3(x: -0.7, y: 0.5, z: 0)
        scene.rootNode.addChildNode(dirLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.color = NSColor(white: 0.30, alpha: 1.0)
        fillLight.position = SCNVector3(x: -8, y: 6, z: -6)
        fillLight.eulerAngles = SCNVector3(x: -0.4, y: -2.3, z: 0)
        scene.rootNode.addChildNode(fillLight)

        // 3. Coordinate Reference Floor Grid
        let gridNode = makeFloorGridNode()
        gridNode.name = "floorGrid"
        scene.rootNode.addChildNode(gridNode)

        // 4. Mesh Container Node
        let meshContainer = SCNNode()
        meshContainer.name = "meshContainer"
        scene.rootNode.addChildNode(meshContainer)

        // 5. Measurement overlay: a sibling of the mesh container, never inside it
        scene.rootNode.addChildNode(context.coordinator.measurementRenderer.container)
        scnView.delegate = context.coordinator.measurementRenderer

        // RoomPlan layout lives inside the mesh container so measurement hit tests (rooted
        // there) land on walls and furniture boxes too. Chunk bookkeeping never touches it.
        let layoutContainer = SCNNode()
        layoutContainer.name = "layoutContainer"
        meshContainer.addChildNode(layoutContainer)
        context.coordinator.layoutContainer = layoutContainer
        context.coordinator.gridNode = gridNode

        context.coordinator.meshContainer = meshContainer
        context.coordinator.scnView = scnView
        context.coordinator.measurements = measurements
        context.coordinator.installMeasureClick(on: scnView)
        receiver.sceneCoordinator = context.coordinator
        context.coordinator.setMapFrame(receiver.mapFrame)
        context.coordinator.setLayout(receiver.layout)
        context.coordinator.setMeshVisible(receiver.showMesh)
        context.coordinator.setLayoutVisible(receiver.showLayout)

        return scnView
    }

    public func updateNSView(_ scnView: SCNView, context: Context) {
        if let grid = scnView.scene?.rootNode.childNode(withName: "floorGrid", recursively: false) {
            grid.isHidden = !receiver.showGrid
        }
        context.coordinator.syncMeasurements()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator: NSObject {
        public weak var meshContainer: SCNNode?
        weak var layoutContainer: SCNNode?
        weak var gridNode: SCNNode?
        public weak var scnView: SCNView?
        private var meshVisible = true
        weak var measurements: MeasurementStore?
        let measurementRenderer = MeasurementRenderer()
        var measureClick: NSClickGestureRecognizer?
        private var chunkNodes: [UUID: SCNNode] = [:]

        /// Geometry is built off the main thread by `MeshReceiver`; this only swaps it in.
        public func setChunk(id: UUID, geometry: SCNGeometry, transform: simd_float4x4) {
            if let node = chunkNodes[id] {
                node.geometry = geometry
                node.simdTransform = transform
                return
            }
            guard let container = meshContainer else { return }
            let node = SCNNode(geometry: geometry)
            node.name = id.uuidString
            node.simdTransform = transform
            // Hundreds of chunk nodes each casting into a 2048² shadow map was a large share of
            // the GPU cost in big rooms. The floor and walls read fine with SSAO and the key light.
            node.castsShadow = false
            node.isHidden = !meshVisible
            container.addChildNode(node)
            chunkNodes[id] = node
        }

        public func setLayout(_ layout: RoomLayout?) {
            guard let container = layoutContainer else { return }
            container.childNodes.forEach { $0.removeFromParentNode() }
            if let layout {
                container.addChildNode(RoomLayoutRenderer.makeNode(layout))
            }
        }

        /// Hidden nodes are skipped by hit tests, so measuring follows what is visible.
        public func setMeshVisible(_ visible: Bool) {
            meshVisible = visible
            chunkNodes.values.forEach { $0.isHidden = !visible }
        }

        public func setLayoutVisible(_ visible: Bool) {
            layoutContainer?.isHidden = !visible
        }

        /// The floor grid is drawn in map coordinates: it lines up with the walls and sits at
        /// floor level, with a line through the map origin.
        func setMapFrame(_ frame: MapFrame) {
            gridNode?.simdTransform = frame.mapToWorld
        }

        public func removeChunk(id: UUID) {
            chunkNodes.removeValue(forKey: id)?.removeFromParentNode()
        }

        public func removeAllChunks() {
            for node in chunkNodes.values {
                node.removeFromParentNode()
            }
            chunkNodes.removeAll()
        }

        /// Point the camera at the scanned area so a mesh far from the origin is not off-screen.
        /// Looks along the map's −Z axis, so aligned walls appear square to the screen.
        func frame(min lo: SIMD3<Float>, max hi: SIMD3<Float>, mapFrame: MapFrame = .scanOrigin) {
            guard let pov = scnView?.pointOfView else { return }
            let center = (lo + hi) / 2
            let radius = Swift.max(simd_length(hi - lo) / 2, 0.5)
            let offset = simd_float3x3(simd_quatf(angle: mapFrame.yaw, axis: [0, 1, 0])) * SIMD3<Float>(0, radius * 0.9, radius * 1.6)
            let eye = center + offset

            if let camera = pov.camera {
                camera.zFar = Swift.max(100, Double(radius) * 8)
            }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            pov.simdPosition = eye
            pov.simdLook(at: center)
            SCNTransaction.commit()
        }

        public func resetCamera() {
            guard let scnView = scnView else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
            scnView.pointOfView?.position = SCNVector3(x: 0, y: 1.8, z: 3.5)
            scnView.pointOfView?.eulerAngles = SCNVector3(x: -0.35, y: 0, z: 0)
            SCNTransaction.commit()
        }
    }

    private func makeFloorGridNode() -> SCNNode {
        let gridContainer = SCNNode()
        let size: CGFloat = 30.0 // map origin sits at the plan corner, so the room is in +X/+Z
        let step: CGFloat = 0.5
        let count = Int(size / step)

        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        var idx: Int32 = 0

        let half = CGFloat(size)
        for i in -count...count {
            let p = CGFloat(i) * step
            // X line
            vertices.append(SCNVector3(x: -half, y: 0, z: p))
            vertices.append(SCNVector3(x: half, y: 0, z: p))
            indices.append(idx); indices.append(idx + 1)
            idx += 2

            // Z line
            vertices.append(SCNVector3(x: p, y: 0, z: -half))
            vertices.append(SCNVector3(x: p, y: 0, z: half))
            indices.append(idx); indices.append(idx + 1)
            idx += 2
        }

        let vertSource = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geom = SCNGeometry(sources: [vertSource], elements: [element])

        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 0.25, alpha: 0.6)
        mat.isDoubleSided = true
        geom.materials = [mat]

        gridContainer.geometry = geom
        return gridContainer
    }
}
