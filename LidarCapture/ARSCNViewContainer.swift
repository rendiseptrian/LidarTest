import SwiftUI
import ARKit
import SceneKit

public struct ARSCNViewContainer: UIViewRepresentable {
    public let session: ARSession

    public init(session: ARSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.session = session
        arView.delegate = context.coordinator
        arView.automaticallyUpdatesLighting = true
        arView.antialiasingMode = .multisampling4X
        return arView
    }

    public func updateUIView(_ uiView: ARSCNView, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator: NSObject, ARSCNViewDelegate {
        public func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode()
            updateNode(node, for: meshAnchor)
            return node
        }

        public func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            updateNode(node, for: meshAnchor)
        }

        private func updateNode(_ node: SCNNode, for meshAnchor: ARMeshAnchor) {
            let geom = meshAnchor.geometry
            let vertCount = geom.vertices.count
            let faceCount = geom.faces.count
            guard vertCount > 0, faceCount > 0 else { return }

            let vertByteCount = vertCount * geom.vertices.stride
            let vertData = Data(bytes: geom.vertices.buffer.contents(), count: vertByteCount)

            let normalByteCount = geom.normals.count * geom.normals.stride
            let normalData = Data(bytes: geom.normals.buffer.contents(), count: normalByteCount)

            let faceByteCount = faceCount * geom.faces.indexCountPerPrimitive * geom.faces.bytesPerIndex
            let faceData = Data(bytes: geom.faces.buffer.contents(), count: faceByteCount)

            let payload = MeshChunkPayload(
                id: meshAnchor.identifier,
                action: .addOrUpdate,
                transform: meshAnchor.transform,
                vertexCount: vertCount,
                normalCount: geom.normals.count,
                faceCount: faceCount,
                vertexData: vertData,
                normalData: normalData,
                faceData: faceData
            )

            if let scnGeom = MeshGeometryHelper.makeGeometry(from: payload, mode: .wireframe) {
                node.geometry = scnGeom
            }
        }
    }
}
