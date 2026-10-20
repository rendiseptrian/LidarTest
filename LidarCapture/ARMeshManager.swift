import Foundation
import ARKit
import Combine

@MainActor
public final class ARMeshManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published public private(set) var isSupported: Bool = false
    @Published public private(set) var isScanning: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public private(set) var totalVertices: Int = 0
    @Published public private(set) var totalFaces: Int = 0
    @Published public private(set) var activeChunkCount: Int = 0
    @Published public private(set) var trackingStatus: String = "Not Started"

    public let session = ARSession()
    private let streamer: NetworkStreamer

    // Cache of active anchors
    private var anchors: [UUID: (vertices: Int, faces: Int)] = [:]

    public init(streamer: NetworkStreamer) {
        self.streamer = streamer
        super.init()
        self.isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else {
            config.sceneReconstruction = .mesh
        }
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        config.environmentTexturing = .automatic
        return config
    }

    public func startScanning() {
        guard isSupported else { return }

        let config = makeConfiguration()
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])

        anchors.removeAll()
        totalVertices = 0
        totalFaces = 0
        activeChunkCount = 0
        isScanning = true
        isPaused = false

        // Notify client to reset scene
        let resetPayload = MeshChunkPayload(id: UUID(), action: .reset)
        streamer.sendMesh(payload: resetPayload)
    }

    public func pauseScanning() {
        session.pause()
        isPaused = true
    }

    public func resumeScanning() {
        let config = makeConfiguration()
        session.run(config)
        isPaused = false
    }

    public func resetScan() {
        startScanning()
    }

    // MARK: - ARSessionDelegate

    nonisolated public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        Task { @MainActor in
            self.handleMeshAnchors(meshAnchors, isUpdate: false)
        }
    }

    nonisolated public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        Task { @MainActor in
            self.handleMeshAnchors(meshAnchors, isUpdate: true)
        }
    }

    nonisolated public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshAnchors.isEmpty else { return }
        Task { @MainActor in
            for anchor in meshAnchors {
                self.anchors.removeValue(forKey: anchor.identifier)
                let payload = MeshChunkPayload(id: anchor.identifier, action: .remove)
                self.streamer.sendMesh(payload: payload)
            }
            self.updateTotals()
        }
    }

    nonisolated public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            switch camera.trackingState {
            case .normal:
                self.trackingStatus = "Tracking: Normal"
            case .limited(let reason):
                switch reason {
                case .initializing: self.trackingStatus = "Tracking: Initializing"
                case .excessiveMotion: self.trackingStatus = "Tracking: Move Slower"
                case .insufficientFeatures: self.trackingStatus = "Tracking: Low Details"
                case .relocalizing: self.trackingStatus = "Tracking: Relocalizing"
                @unknown default: self.trackingStatus = "Tracking: Limited"
                }
            case .notAvailable:
                self.trackingStatus = "Tracking: Unavailable"
            }
        }
    }

    // MARK: - Process Mesh Anchors

    private func handleMeshAnchors(_ meshAnchors: [ARMeshAnchor], isUpdate: Bool) {
        for anchor in meshAnchors {
            let geom = anchor.geometry

            let vertCount = geom.vertices.count
            let faceCount = geom.faces.count
            guard vertCount > 0, faceCount > 0 else { continue }

            // Extract vertex buffer
            let vertByteCount = vertCount * geom.vertices.stride
            let vertData = Data(bytes: geom.vertices.buffer.contents(), count: vertByteCount)

            // Extract normal buffer
            let normalByteCount = geom.normals.count * geom.normals.stride
            let normalData = Data(bytes: geom.normals.buffer.contents(), count: normalByteCount)

            // Extract face buffer (triangles, 3 indices per face)
            let faceByteCount = faceCount * geom.faces.indexCountPerPrimitive * geom.faces.bytesPerIndex
            let faceData = Data(bytes: geom.faces.buffer.contents(), count: faceByteCount)

            // Extract classification buffer if available
            var classData = Data()
            if let classification = geom.classification {
                let classByteCount = classification.count * classification.stride
                classData = Data(bytes: classification.buffer.contents(), count: classByteCount)
            }

            // Cache statistics
            self.anchors[anchor.identifier] = (vertCount, faceCount)

            // Build payload and transmit
            let payload = MeshChunkPayload(
                id: anchor.identifier,
                action: .addOrUpdate,
                transform: anchor.transform,
                vertexCount: vertCount,
                normalCount: geom.normals.count,
                faceCount: faceCount,
                vertexData: vertData,
                normalData: normalData,
                faceData: faceData,
                classificationData: classData
            )

            streamer.sendMesh(payload: payload)
        }

        updateTotals()
    }

    private func updateTotals() {
        var vSum = 0
        var fSum = 0
        for (_, counts) in anchors {
            vSum += counts.vertices
            fSum += counts.faces
        }
        self.totalVertices = vSum
        self.totalFaces = fSum
        self.activeChunkCount = anchors.count
    }
}
