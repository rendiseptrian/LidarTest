import SwiftUI
import SceneKit
import simd

public struct SceneKitMeshView: NSViewRepresentable {
    @ObservedObject public var receiver: MeshReceiver

    public init(receiver: MeshReceiver) {
        self.receiver = receiver
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

        context.coordinator.meshContainer = meshContainer
        context.coordinator.scnView = scnView
        receiver.sceneCoordinator = context.coordinator

        return scnView
    }

    public func updateNSView(_ scnView: SCNView, context: Context) {
        if let grid = scnView.scene?.rootNode.childNode(withName: "floorGrid", recursively: false) {
            grid.isHidden = !receiver.showGrid
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        public weak var meshContainer: SCNNode?
        public weak var scnView: SCNView?
        private var chunkNodes: [UUID: SCNNode] = [:]

        public func updateChunk(_ payload: MeshChunkPayload, mode: MeshRenderMode) {
            guard let container = meshContainer else { return }

            switch payload.action {
            case .reset:
                for (_, node) in chunkNodes {
                    node.removeFromParentNode()
                }
                chunkNodes.removeAll()

            case .remove:
                if let node = chunkNodes.removeValue(forKey: payload.id) {
                    node.removeFromParentNode()
                }

            case .addOrUpdate:
                if let scnGeom = MeshGeometryHelper.makeGeometry(from: payload, mode: mode) {
                    if let existingNode = chunkNodes[payload.id] {
                        existingNode.geometry = scnGeom
                        existingNode.simdTransform = payload.transform
                    } else {
                        let newNode = SCNNode(geometry: scnGeom)
                        newNode.name = payload.id.uuidString
                        newNode.simdTransform = payload.transform
                        container.addChildNode(newNode)
                        chunkNodes[payload.id] = newNode
                    }
                }
            }
        }

        public func reloadAllMaterials(chunks: [UUID: MeshChunkPayload], mode: MeshRenderMode) {
            for (id, payload) in chunks {
                if let node = chunkNodes[id], let scnGeom = MeshGeometryHelper.makeGeometry(from: payload, mode: mode) {
                    node.geometry = scnGeom
                }
            }
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
        let size: CGFloat = 10.0
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
