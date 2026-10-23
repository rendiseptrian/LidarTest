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

    /// ARKit delivers mesh anchors here instead of on the main thread. Copying several hundred KB
    /// of vertex/face buffers per update on the main thread stalled the UI and the send queue in
    /// large rooms.
    private let extractionQueue = DispatchQueue(label: "mesh.extract", qos: .userInitiated)

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

    // MARK: - Modes
    //
    // One ARSession serves both engines. RoomPlan (`RoomScanManager`) and this detail-mesh mode
    // take turns on it, and tracking is never reset between them, so rooms and mesh share one
    // world frame. Only `newScan` resets the origin.

    /// Detail mode on: this manager owns the session's delegate and runs scene reconstruction.
    public func enterMeshMode() {
        guard isSupported else { return }
        attach()
        session.run(makeConfiguration())
        isScanning = true
        isPaused = false
    }

    /// Hand the session to RoomPlan. Mesh already captured stays on the Mac and in the snapshot.
    public func leaveMeshMode() {
        detach()
        isScanning = false
        isPaused = false
    }

    public func pauseScanning() {
        session.pause()
        isPaused = true
    }

    public func resumeScanning() {
        session.run(makeConfiguration())
        isPaused = false
    }

    /// Starts over: new world origin, all mesh and room data cleared (here and on the Mac).
    /// `meshMode` decides whether scene reconstruction runs right away.
    public func newScan(meshMode: Bool) {
        anchors.removeAll()
        totalVertices = 0
        totalFaces = 0
        activeChunkCount = 0
        streamer.resetScan()

        if meshMode {
            attach()
            session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
            isScanning = true
            isPaused = false
        } else {
            detach()
            // Plain tracking just to re-origin the world; RoomPlan installs its own configuration
            // when the first room starts.
            session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
            isScanning = false
        }
    }

    private func attach() {
        session.delegateQueue = extractionQueue
        session.delegate = self
    }

    /// RoomPlan expects the session's callbacks on the main queue and may install its own delegate.
    private func detach() {
        session.delegate = nil
        session.delegateQueue = nil
    }

    // MARK: - ARSessionDelegate

    // Delegate callbacks arrive on `extractionQueue`. Results hop to the main thread with
    // `DispatchQueue.main.async`, which (unlike spawning a Task per callback) preserves order, so a
    // removal can never overtake the update that preceded it.

    nonisolated public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let payloads = anchors.compactMap { ($0 as? ARMeshAnchor).flatMap(Self.makePayload) }
        guard !payloads.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.apply(payloads) }
        }
    }

    nonisolated public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let payloads = anchors.compactMap { ($0 as? ARMeshAnchor).flatMap(Self.makePayload) }
        guard !payloads.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.apply(payloads) }
        }
    }

    nonisolated public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.compactMap { ($0 as? ARMeshAnchor)?.identifier }
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for id in ids {
                    self.anchors.removeValue(forKey: id)
                    self.streamer.remove(id: id)
                }
                self.updateTotals()
            }
        }
    }

    nonisolated public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let trackingState = camera.trackingState
        DispatchQueue.main.async { MainActor.assumeIsolated {
            switch trackingState {
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
        } }
    }

    // MARK: - Process Mesh Anchors

    private func apply(_ payloads: [MeshChunkPayload]) {
        for payload in payloads {
            anchors[payload.id] = (payload.vertexCount, payload.faceCount)
            streamer.upsert(payload)
        }
        updateTotals()
    }

    /// Copies one anchor's buffers. Positions stay Float32 metres in anchor-local space; the
    /// anchor transform carries them into world space. Nothing here is lossy.
    nonisolated private static func makePayload(from anchor: ARMeshAnchor) -> MeshChunkPayload? {
        let geom = anchor.geometry
        let vertCount = geom.vertices.count
        let faceCount = geom.faces.count
        guard vertCount > 0, faceCount > 0 else { return nil }

        let vertices = geom.vertices
        let vertData = Data(bytes: vertices.buffer.contents().advanced(by: vertices.offset),
                            count: vertCount * vertices.stride)

        let normals = geom.normals
        let normalData = Data(bytes: normals.buffer.contents().advanced(by: normals.offset),
                              count: normals.count * normals.stride)

        let faces = geom.faces
        let faceData = Data(bytes: faces.buffer.contents(),
                            count: faceCount * faces.indexCountPerPrimitive * faces.bytesPerIndex)

        var classData = Data()
        if let classification = geom.classification {
            classData = Data(bytes: classification.buffer.contents().advanced(by: classification.offset),
                             count: classification.count * classification.stride)
        }

        return MeshChunkPayload(
            id: anchor.identifier,
            action: .addOrUpdate,
            transform: anchor.transform,
            vertexCount: vertCount,
            normalCount: normals.count,
            faceCount: faceCount,
            vertexData: vertData,
            normalData: normalData,
            faceData: faceData,
            classificationData: classData
        )
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
