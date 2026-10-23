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

        /// Preview only. Wraps ARKit's own Metal vertex buffer instead of copying it, and skips
        /// normals and classification, so the on-device wireframe costs a fraction of what it did.
        /// The data sent to the Mac is built separately and in full by `ARMeshManager`.
        private func updateNode(_ node: SCNNode, for meshAnchor: ARMeshAnchor) {
            let geom = meshAnchor.geometry
            let vertices = geom.vertices
            let faces = geom.faces
            guard vertices.count > 0, faces.count > 0 else { return }

            let vertexSource = SCNGeometrySource(
                buffer: vertices.buffer,
                vertexFormat: vertices.format,
                semantic: .vertex,
                vertexCount: vertices.count,
                dataOffset: vertices.offset,
                dataStride: vertices.stride
            )
            let faceData = Data(bytes: faces.buffer.contents(),
                                count: faces.count * faces.indexCountPerPrimitive * faces.bytesPerIndex)
            let element = SCNGeometryElement(
                data: faceData,
                primitiveType: .triangles,
                primitiveCount: faces.count,
                bytesPerIndex: faces.bytesPerIndex
            )

            let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
            geometry.materials = [Self.wireframeMaterial]
            node.geometry = geometry
        }

        private static let wireframeMaterial: SCNMaterial = {
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: 0.0, green: 0.88, blue: 1.0, alpha: 1.0)
            material.lightingModel = .constant
            material.fillMode = .lines
            material.isDoubleSided = true
            return material
        }()
    }
}
