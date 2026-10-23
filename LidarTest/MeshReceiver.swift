import Foundation
import Network
import Combine
import QuartzCore
import simd
import os

public enum MeshConnectionStatus: Equatable {
    case stopped
    case listening
    case connected(String)
    case failed(String)

    public var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .listening: return "Waiting for iPhone..."
        case .connected(let h): return "Connected: \(h)"
        case .failed(let err): return "Failed: \(err)"
        }
    }
}

/// The Mac is listen-only. It advertises itself over Bonjour; the iPhone finds it and connects.
///
/// Threading: socket reads and decoding run on `netQueue` (`MeshStreamReader`), geometry building
/// and bounds measurement on `buildQueue` (`PreparedChunk`), and only the cheap scene-graph swap
/// and bookkeeping on the main thread. Both queues are serial and results reach main via
/// `DispatchQueue.main.async`, so messages are applied in exactly the order they were sent.
///
/// The scene is never cleared because a connection dropped. The phone resends everything plus a
/// `.sync` manifest when it reconnects, which brings this mirror back in line.
@MainActor
public final class MeshReceiver: ObservableObject {
    @Published public private(set) var port: UInt16 = NetworkUtils.defaultPort
    @Published public private(set) var localIP: String = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
    @Published public private(set) var status: MeshConnectionStatus = .stopped
    @Published public private(set) var isListening: Bool = false

    // Geometry Telemetry
    @Published public private(set) var totalVertices: Int = 0
    @Published public private(set) var totalFaces: Int = 0
    @Published public private(set) var activeChunkCount: Int = 0
    @Published public private(set) var roomDimensions: String = "--"

    // Network Telemetry
    @Published public private(set) var fps: Double = 0.0
    @Published public private(set) var bitrateMBs: Double = 0.0

    // Render Settings
    @Published public var renderMode: MeshRenderMode = .realistic {
        didSet {
            guard renderMode != oldValue else { return }
            modeBox.value = renderMode
            rebuildAllChunks()
        }
    }
    @Published public var showGrid: Bool = true
    @Published public var showMesh: Bool = true {
        didSet { sceneCoordinator?.setMeshVisible(showMesh) }
    }
    @Published public var showLayout: Bool = true {
        didSet { sceneCoordinator?.setLayoutVisible(showLayout) }
    }

    /// RoomPlan's structured rooms (walls, doors, windows, furniture), when the iPhone sends one.
    @Published public private(set) var layout: RoomLayout?
    /// How the map is oriented and where its origin is. See `MapFrame`.
    @Published private(set) var mapFrame = MapFrame(mode: .autoAligned, origin: .zero, yaw: 0)

    public weak var sceneCoordinator: SceneKitMeshView.Coordinator?

    /// Connection events and scene stats. Watch live with Console.app, or:
    /// `log stream --level debug --predicate 'subsystem == "c7.LidarTest"'`
    private let log = Logger(subsystem: "c7.LidarTest", category: "MeshReceiver")

    // Tuning
    /// The phone heartbeats every 2 s when idle; this much silence means the link is dead even if
    /// TCP has not noticed yet.
    private let silenceTimeout: TimeInterval = 12
    private let listenerRetryDelay: TimeInterval = 2

    // Pipeline
    private let netQueue = DispatchQueue(label: "mesh.net", qos: .userInitiated)
    private let buildQueue = DispatchQueue(label: "mesh.build", qos: .userInitiated)
    private let modeBox = LockedValue<MeshRenderMode>(.realistic)
    private var listener: NWListener?
    private var reader: MeshStreamReader?
    private var readerID = 0
    private var listenerRetryTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var lastPacketTime: TimeInterval = 0

    // Scene mirror
    private struct ChunkRecord {
        var payload: MeshChunkPayload
        var version: Int
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var hasBounds: Bool
    }
    private var chunks: [UUID: ChunkRecord] = [:]
    private var nextVersion = 1
    private var runningVertices = 0
    private var runningFaces = 0
    private var statsDirty = false
    private var hasAutoFramed = false
    private var layoutPayload: MeshChunkPayload?
    private var layoutBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    private var lastAutoAlign: TimeInterval = 0
    private var autoAlignInFlight = false

    // Metrics
    private var packetCount = 0
    private var byteCount: Int64 = 0
    private var lastMetricsTime: TimeInterval = CACurrentMediaTime()

    public init() {}

    // MARK: - Listening

    public func startListening() {
        stopListening()
        localIP = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
        isListening = true
        status = .listening
        startTicker()
        makeListener()
    }

    public func stopListening() {
        isListening = false
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
        listener?.cancel()
        listener = nil
        dropConnection()
        status = .stopped
    }

    private func makeListener() {
        guard isListening else { return }
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let newListener = try NWListener(using: NetworkUtils.makeTCPParameters(), on: nwPort)
            // Advertised under the Mac's computer name, which the phone shows when it finds it.
            newListener.service = NWListener.Service(type: NetworkUtils.bonjourServiceType)

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.isListening else { return }
                    if case .failed(let err) = state {
                        // e.g. port still held by a previous run. Keep trying instead of giving up.
                        self.status = .failed("Listener: \(err.localizedDescription)")
                        self.listener?.cancel()
                        self.listener = nil
                        self.scheduleListenerRetry()
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.accept(conn)
                }
            }

            newListener.start(queue: .main)
            listener = newListener
        } catch {
            status = .failed("Listener: \(error.localizedDescription)")
            scheduleListenerRetry()
        }
    }

    private func scheduleListenerRetry() {
        guard isListening, listenerRetryTask == nil else { return }
        listenerRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.listenerRetryDelay ?? 2) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.listenerRetryTask = nil
            self.makeListener()
        }
    }

    /// The newest connection always wins. After a silent drop the phone reconnects before this
    /// side has noticed the old socket is dead; refusing it would stall the scan.
    private func accept(_ conn: NWConnection) {
        guard isListening else { conn.cancel(); return }
        dropConnection()

        readerID += 1
        let id = readerID
        let endpoint = "\(conn.endpoint)"
        let modeBox = self.modeBox
        let buildQueue = self.buildQueue

        let newReader = MeshStreamReader(
            connection: conn,
            queue: netQueue,
            onReady: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.connectionReady(id: id, endpoint: endpoint) }
                }
            },
            onPayload: { [weak self] payload, wireBytes in
                buildQueue.async {
                    let prepared = PreparedChunk.make(payload, mode: modeBox.value, wireBytes: wireBytes)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.apply(prepared, readerID: id) }
                    }
                }
            },
            onClose: { [weak self] reason in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.connectionClosed(id: id, reason: reason) }
                }
            }
        )
        reader = newReader
        newReader.start()
    }

    private func connectionReady(id: Int, endpoint: String) {
        guard id == readerID else { return }
        status = .connected(endpoint)
        log.info("connected: \(endpoint, privacy: .public)")
        lastPacketTime = CACurrentMediaTime()
        packetCount = 0
        byteCount = 0
        lastMetricsTime = lastPacketTime
    }

    private func connectionClosed(id: Int, reason: String?) {
        guard id == readerID else { return }
        reader = nil
        fps = 0
        bitrateMBs = 0
        guard isListening else { return }
        status = .listening
        log.info("connection closed: \(reason ?? "peer closed", privacy: .public)")
    }

    private func dropConnection() {
        readerID += 1 // anything still in flight from the old connection is ignored
        reader?.cancel()
        reader = nil
    }

    // MARK: - Applying chunks (main thread)

    private func apply(_ prepared: PreparedChunk, readerID id: Int) {
        let payload = prepared.payload

        if prepared.rebuildOfVersion != 0 {
            // A render-mode rebuild: only valid if the chunk has not changed or vanished since.
            guard let record = chunks[payload.id], record.version == prepared.rebuildOfVersion,
                  prepared.mode == renderMode, let geometry = prepared.geometry else { return }
            sceneCoordinator?.setChunk(id: payload.id, geometry: geometry, transform: payload.transform)
            return
        }

        let isLocal = id == Self.localSourceID
        guard isLocal || id == readerID else { return }
        if !isLocal {
            lastPacketTime = CACurrentMediaTime()
            packetCount += 1
            byteCount += Int64(prepared.wireBytes)
        }

        switch payload.action {
        case .heartbeat:
            return

        case .reset:
            removeAllChunks()

        case .sync:
            let live = payload.manifestIDs
            for staleID in chunks.keys where !live.contains(staleID) {
                removeChunk(staleID)
            }
            if !live.contains(RoomLayout.payloadID) { setLayout(nil) }

        case .remove:
            if payload.id == RoomLayout.payloadID {
                setLayout(nil)
            } else {
                removeChunk(payload.id)
            }

        case .layout:
            setLayout(payload)

        case .addOrUpdate:
            guard let geometry = prepared.geometry else { return }
            if let old = chunks[payload.id] {
                runningVertices -= old.payload.vertexCount
                runningFaces -= old.payload.faceCount
            }
            let version = nextVersion
            nextVersion += 1
            chunks[payload.id] = ChunkRecord(payload: payload, version: version,
                                             boundsMin: prepared.boundsMin, boundsMax: prepared.boundsMax,
                                             hasBounds: prepared.hasBounds)
            runningVertices += payload.vertexCount
            runningFaces += payload.faceCount
            sceneCoordinator?.setChunk(id: payload.id, geometry: geometry, transform: payload.transform)

            if prepared.mode != renderMode {
                rebuild(payload.id)
            }
        }
        statsDirty = true
    }

    private func removeChunk(_ id: UUID) {
        guard let old = chunks.removeValue(forKey: id) else { return }
        runningVertices -= old.payload.vertexCount
        runningFaces -= old.payload.faceCount
        sceneCoordinator?.removeChunk(id: id)
        statsDirty = true
    }

    /// Clears mesh and room layout: everything the iPhone streamed.
    private func removeAllChunks() {
        chunks.removeAll()
        runningVertices = 0
        runningFaces = 0
        hasAutoFramed = false
        sceneCoordinator?.removeAllChunks()
        setLayout(nil)
        statsDirty = true
    }

    private func setLayout(_ payload: MeshChunkPayload?) {
        guard let payload, let decoded = RoomLayout(payload: payload) else {
            guard layoutPayload != nil || layout != nil else { return }
            layoutPayload = nil
            layout = nil
            layoutBounds = nil
            sceneCoordinator?.setLayout(nil)
            statsDirty = true
            return
        }
        layoutPayload = payload
        layout = decoded
        log.debug("layout: \(decoded.rooms.count, privacy: .public) rooms, \(decoded.surfaces.count, privacy: .public) surfaces, \(decoded.objects.count, privacy: .public) objects")
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in decoded.surfaces.flatMap(\.boxCorners) + decoded.objects.flatMap(\.footprint) {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        layoutBounds = lo.x <= hi.x ? (lo, hi) : nil
        sceneCoordinator?.setLayout(decoded)
        statsDirty = true
    }

    public func clearScene() {
        removeAllChunks()
        publishStats()
    }

    public func frameScene() {
        guard let bounds = sceneBounds() else {
            sceneCoordinator?.resetCamera()
            return
        }
        sceneCoordinator?.frame(min: bounds.min, max: bounds.max, mapFrame: mapFrame)
    }

    private func rebuildAllChunks() {
        for id in chunks.keys { rebuild(id) }
    }

    private func rebuild(_ id: UUID) {
        guard let record = chunks[id] else { return }
        let payload = record.payload
        let version = record.version
        let mode = renderMode
        buildQueue.async { [weak self] in
            let prepared = PreparedChunk.make(payload, mode: mode, wireBytes: 0, rebuildOfVersion: version)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(prepared, readerID: 0) }
            }
        }
    }

    // MARK: - Stats & watchdog

    private func startTicker() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()

        if case .connected = status, now - lastPacketTime > silenceTimeout {
            log.info("no data for \(self.silenceTimeout, privacy: .public)s, dropping connection")
            dropConnection()
            status = .listening
            fps = 0
            bitrateMBs = 0
        }

        let elapsed = now - lastMetricsTime
        if elapsed >= 1.0 {
            fps = Double(packetCount) / elapsed
            bitrateMBs = (Double(byteCount) / 1_048_576.0) / elapsed
            packetCount = 0
            byteCount = 0
            lastMetricsTime = now
        }

        if statsDirty {
            publishStats()
        }
    }

    private func publishStats() {
        statsDirty = false
        totalVertices = runningVertices
        totalFaces = runningFaces
        activeChunkCount = chunks.count
        log.debug("scene: \(self.chunks.count, privacy: .public) chunks, \(self.runningVertices, privacy: .public) vertices")

        guard let bounds = sceneBounds() else {
            roomDimensions = "--"
            return
        }
        let size = bounds.max - bounds.min
        roomDimensions = String(format: "%.2f m × %.2f m × %.2f m", size.x, size.y, size.z)

        refreshAutoAlignment()
        if !hasAutoFramed {
            hasAutoFramed = true
            sceneCoordinator?.frame(min: bounds.min, max: bounds.max, mapFrame: mapFrame)
        }
    }

    /// Union of per-chunk world bounds. O(chunks), not O(vertices).
    private func sceneBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for record in chunks.values where record.hasBounds {
            lo = simd_min(lo, record.boundsMin)
            hi = simd_max(hi, record.boundsMax)
            any = true
        }
        if let layoutBounds {
            lo = simd_min(lo, layoutBounds.min)
            hi = simd_max(hi, layoutBounds.max)
            any = true
        }
        return any ? (lo, hi) : nil
    }

    // MARK: - Map frame

    /// Walls to axes, floor to y = 0, origin at the plan corner. Keeps following the scan.
    public func autoAlignMap() {
        mapFrame = MapFrame(mode: .autoAligned, origin: mapFrame.origin, yaw: mapFrame.yaw)
        lastAutoAlign = 0
        refreshAutoAlignment(force: true)
    }

    /// Origin at the measurement's start, +X along it. Returns false for a vertical measurement.
    @discardableResult
    func setMapFrame(from measurement: RoomMeasurement) -> Bool {
        guard let frame = MapFrame.fromMeasurement(start: measurement.start, end: measurement.end) else { return false }
        applyMapFrame(frame)
        return true
    }

    public func useScanOrigin() {
        applyMapFrame(.scanOrigin)
    }

    func applyMapFrame(_ frame: MapFrame) {
        mapFrame = frame
        sceneCoordinator?.setMapFrame(frame)
    }

    /// Recomputed at most every 2 s, off the main thread when it has to read the mesh.
    private func refreshAutoAlignment(force: Bool = false) {
        guard mapFrame.mode == .autoAligned, !autoAlignInFlight else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastAutoAlign >= 2 else { return }
        lastAutoAlign = now

        let layout = self.layout
        // RoomPlan walls are exact and cheap; the mesh is only needed when there is no layout.
        let payloads = (layout?.isEmpty ?? true) ? exportPayloads().filter { $0.action == .addOrUpdate } : []
        autoAlignInFlight = true
        buildQueue.async { [weak self] in
            let frame = MapFrame.autoAligned(layout: layout, payloads: payloads)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.autoAlignInFlight = false
                    guard let frame, self.mapFrame.mode == .autoAligned else { return }
                    self.applyMapFrame(frame)
                }
            }
        }
    }

    // MARK: - Saving & opening scans

    /// `apply` source tag for chunks read from a file rather than the network.
    private static let localSourceID = -1

    /// Every chunk currently in the scene, plus the room layout, for saving or exporting.
    public func exportPayloads() -> [MeshChunkPayload] {
        chunks.values.map(\.payload) + (layoutPayload.map { [$0] } ?? [])
    }

    /// Replaces the scene with a saved scan. Stops listening first: a connected iPhone's `.sync`
    /// manifest would otherwise delete the opened scan. Press Listen again to resume live scanning.
    func loadScan(_ payloads: [MeshChunkPayload], mapFrame frame: MapFrame?) {
        if isListening { stopListening() }
        removeAllChunks()
        applyMapFrame(frame ?? MapFrame(mode: .autoAligned, origin: .zero, yaw: 0))
        lastAutoAlign = 0
        let modeBox = self.modeBox
        for payload in payloads where payload.action == .addOrUpdate || payload.action == .layout {
            buildQueue.async { [weak self] in
                let prepared = PreparedChunk.make(payload, mode: modeBox.value, wireBytes: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.apply(prepared, readerID: Self.localSourceID) }
                }
            }
        }
    }
}
