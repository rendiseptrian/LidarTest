import Foundation
import Network
import Combine
import QuartzCore

/// Pushes the live ARKit mesh to the Mac. The iPhone is always the client; the Mac only listens.
///
/// Delivery model — the phone is the source of truth and the Mac is a mirror:
/// - `snapshot` holds the latest payload of every live anchor, whether or not anything is connected.
/// - On every (re)connect the Mac first gets a `.sync` manifest (so chunks removed while offline
///   disappear), then every snapshot chunk is resent. Anything lost when a connection died is
///   therefore recovered on the next one; nothing depends on a chunk happening to update again.
/// - Within a connection, a chunk is only queued once; later updates replace it in `snapshot`
///   so only the newest version is ever sent.
@MainActor
public final class NetworkStreamer: ObservableObject {
    public enum Status: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case waiting(String)

        public var title: String {
            switch self {
            case .idle: return "Offline"
            case .searching: return "Searching for Mac…"
            case .connecting(let h): return "Connecting to \(h)…"
            case .connected(let h): return "Streaming to \(h)"
            case .waiting(let reason): return "Retrying: \(reason)"
            }
        }
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var discoveredMacs: [String] = []
    @Published public private(set) var localIPAddress: String = "Detecting IP..."
    @Published public private(set) var fps: Double = 0.0
    @Published public private(set) var bytesSentTotal: Int64 = 0
    @Published public private(set) var pendingChunkCount: Int = 0
    @Published public private(set) var lastError: String?

    /// Empty = find the Mac automatically over Bonjour. Otherwise connect to this host/IP directly.
    @Published public var manualHost: String = ""

    // Tuning
    private let port = NetworkUtils.defaultPort
    /// Minimum gap between two sends of the same anchor. ARKit refines anchors continuously;
    /// sending each refinement would starve brand-new areas of bandwidth.
    private let perChunkMinInterval: TimeInterval = 0.5
    /// Uncompressed bytes allowed on the wire at once. Lets several chunks be in flight instead of
    /// one round trip per chunk, while still bounding how much sits in the socket buffer.
    private let inFlightByteBudget = 4 * 1024 * 1024
    private let heartbeatInterval: TimeInterval = 2.0
    private let maxReconnectDelay: TimeInterval = 5.0

    // Mesh state (survives disconnects)
    private var snapshot: [UUID: MeshChunkPayload] = [:]

    // Per-connection send state
    private var pendingOrder: [UUID] = []
    private var pendingSet: Set<UUID> = []
    private var sentOnConnection: Set<UUID> = []
    private var lastSentAt: [UUID: TimeInterval] = [:]
    private var inFlightBytes = 0
    private var lastSendTime: TimeInterval = 0

    // Connection
    private var isRunning = false
    private var browser: NWBrowser?
    private var browseResults: [NWEndpoint] = []
    private var connection: NWConnection?
    private var connectionGeneration = 0
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var pumpTimer: Timer?
    /// Encoding and `send` happen here, in order, so the main thread never compresses and the
    /// byte order on the wire matches the order chunks were picked.
    private let encodeQueue = DispatchQueue(label: "mesh.encode", qos: .userInitiated)

    // Metrics
    private var chunksSinceMetric = 0
    private var lastMetricTime: TimeInterval = CACurrentMediaTime()

    public init() {
        refreshIP()
    }

    public func refreshIP() {
        localIPAddress = NetworkUtils.getLocalIPAddress() ?? "No Wi-Fi"
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshIP()
        startBrowsing()
        startPump()
        connectIfPossible()
    }

    public func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pumpTimer?.invalidate()
        pumpTimer = nil
        browser?.cancel()
        browser = nil
        browseResults = []
        discoveredMacs = []
        teardownConnection()
        status = .idle
    }

    /// Apply a changed `manualHost` (or retry right now after a failure).
    public func reconnectNow() {
        guard isRunning else { return start() }
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownConnection()
        connectIfPossible()
    }

    // MARK: - Mesh API (called by ARMeshManager)

    public func upsert(_ payload: MeshChunkPayload) {
        snapshot[payload.id] = payload
        markPending(payload.id)
        drain()
    }

    public func remove(id: UUID) {
        snapshot.removeValue(forKey: id)
        markPending(id)
        drain()
    }

    /// A new scan started: forget everything. If nothing is connected, the empty `.sync` manifest
    /// sent on the next connect clears the Mac instead.
    public func resetScan() {
        snapshot.removeAll()
        pendingOrder.removeAll()
        pendingSet.removeAll()
        sentOnConnection.removeAll()
        lastSentAt.removeAll()
        pendingChunkCount = 0
        if isConnected {
            enqueueSend(MeshChunkPayload(id: UUID(), action: .reset))
        }
    }

    // MARK: - Discovery

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: NetworkUtils.bonjourServiceType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.browseResults = endpoints
                self.discoveredMacs = endpoints.map(Self.displayName(for:))
                if !self.isConnected, self.connection == nil {
                    self.connectIfPossible()
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.browser === browser else { return }
                switch state {
                case .ready:
                    if self.lastError?.hasPrefix("Discovery") == true { self.lastError = nil }
                case .waiting(let error):
                    // Typically Local Network access denied; the browser resumes on its own once
                    // access is granted, so just explain what to do.
                    self.lastError = "Discovery: \(Self.describe(error))"
                case .failed(let error):
                    self.lastError = "Discovery: \(Self.describe(error))"
                    browser.cancel()
                    self.browser = nil
                    self.scheduleBrowserRestart()
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func scheduleBrowserRestart() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.isRunning, self.browser == nil else { return }
            self.startBrowsing()
        }
    }

    /// Turns the DNS-SD error codes iOS reports into something actionable.
    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error {
            switch Int(code) {
            case -65570: // kDNSServiceErr_PolicyDenied
                return "Local Network access is off. Enable it in Settings › Privacy & Security › Local Network › LiDAR Capture."
            case -65555: // kDNSServiceErr_NoAuth
                return "This build doesn't declare the Bonjour service (NSBonjourServices). Reinstall the latest build, or type the Mac's IP."
            default:
                break
            }
        }
        return "\(error.localizedDescription). Type the Mac's IP to connect directly."
    }

    private static func displayName(for endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return "\(endpoint)"
    }

    // MARK: - Connection

    private func connectIfPossible() {
        guard isRunning, connection == nil else { return }

        let endpoint: NWEndpoint
        let label: String
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            label = host
        } else if let found = browseResults.first {
            endpoint = found
            label = Self.displayName(for: found)
        } else {
            status = .searching
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        let conn = NWConnection(to: endpoint, using: NetworkUtils.makeTCPParameters())
        connection = conn
        status = .connecting(label)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectionGeneration else { return }
                switch state {
                case .ready:
                    self.handleReady(label: label)
                case .waiting(let error):
                    // Refused / unreachable. NWConnection would only retry on a path change, so
                    // drop it and retry on our own schedule.
                    self.handleConnectionLoss(reason: Self.describe(error))
                case .failed(let error):
                    self.handleConnectionLoss(reason: Self.describe(error))
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func handleReady(label: String) {
        isConnected = true
        status = .connected(label)
        lastError = nil
        reconnectAttempts = 0
        reconnectTask?.cancel()
        reconnectTask = nil

        // Fresh mirror: manifest first, then resend everything the phone currently holds.
        sentOnConnection.removeAll()
        lastSentAt.removeAll()
        inFlightBytes = 0
        pendingOrder = Array(snapshot.keys)
        pendingSet = Set(pendingOrder)
        pendingChunkCount = pendingOrder.count
        enqueueSend(MeshChunkPayload.syncManifest(ids: Array(snapshot.keys)))
        drain()
    }

    private func handleConnectionLoss(reason: String) {
        lastError = reason
        teardownConnection()
        scheduleReconnect(reason: reason)
    }

    private func teardownConnection() {
        connectionGeneration += 1 // invalidates callbacks from the old connection
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        inFlightBytes = 0
    }

    private func scheduleReconnect(reason: String) {
        guard isRunning, reconnectTask == nil else { return }
        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts), maxReconnectDelay)
        status = .waiting(reason)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connectIfPossible()
        }
    }

    // MARK: - Send queue

    private func markPending(_ id: UUID) {
        if pendingSet.insert(id).inserted {
            pendingOrder.append(id)
        }
        pendingChunkCount = pendingOrder.count
    }

    private func startPump() {
        pumpTimer?.invalidate()
        // Re-checks rate-limited chunks and sends heartbeats; cheap when there is nothing to do.
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.drain()
                self.sendHeartbeatIfIdle()
            }
        }
    }

    private func drain() {
        guard isConnected, connection != nil else { return }
        let now = CACurrentMediaTime()

        while inFlightBytes < inFlightByteBudget, let index = nextPendingIndex(now: now) {
            let id = pendingOrder.remove(at: index)
            pendingSet.remove(id)

            if let payload = snapshot[id] {
                sentOnConnection.insert(id)
                lastSentAt[id] = now
                enqueueSend(payload)
            } else {
                sentOnConnection.remove(id)
                lastSentAt.removeValue(forKey: id)
                enqueueSend(MeshChunkPayload(id: id, action: .remove))
            }
        }
        pendingChunkCount = pendingOrder.count
    }

    /// Removals and never-sent chunks first (new areas of the room appear promptly), then
    /// refinements of chunks the Mac already has, each no more often than `perChunkMinInterval`.
    private func nextPendingIndex(now: TimeInterval) -> Int? {
        var firstEligibleUpdate: Int?
        for (index, id) in pendingOrder.enumerated() {
            if snapshot[id] == nil || !sentOnConnection.contains(id) {
                return index
            }
            if firstEligibleUpdate == nil, now - (lastSentAt[id] ?? 0) >= perChunkMinInterval {
                firstEligibleUpdate = index
            }
        }
        return firstEligibleUpdate
    }

    private func enqueueSend(_ payload: MeshChunkPayload) {
        guard let conn = connection else { return }
        let generation = connectionGeneration
        let estimate = payload.vertexData.count + payload.normalData.count
            + payload.faceData.count + payload.classificationData.count + 256
        inFlightBytes += estimate
        lastSendTime = CACurrentMediaTime()
        let countsAsChunk = payload.action == .addOrUpdate

        let completed: @Sendable (NWError?, Int) -> Void = { [weak self] error, wireBytes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.sendCompleted(generation: generation, estimate: estimate, wireBytes: wireBytes,
                                        countsAsChunk: countsAsChunk, error: error)
                }
            }
        }

        encodeQueue.async {
            let frame = MeshFrameCodec.encode(payload)
            conn.send(content: frame, completion: .contentProcessed { error in
                completed(error, frame.count)
            })
        }
    }

    private func sendCompleted(generation: Int, estimate: Int, wireBytes: Int, countsAsChunk: Bool, error: NWError?) {
        guard generation == connectionGeneration else { return }
        inFlightBytes = max(0, inFlightBytes - estimate)

        if let error {
            // The chunks in flight are not lost: they are still in `snapshot` and get resent on
            // the next connection.
            handleConnectionLoss(reason: "Send failed: \(error.localizedDescription)")
            return
        }

        bytesSentTotal += Int64(wireBytes)
        if countsAsChunk { chunksSinceMetric += 1 }
        let now = CACurrentMediaTime()
        if now - lastMetricTime >= 1.0 {
            fps = Double(chunksSinceMetric) / (now - lastMetricTime)
            chunksSinceMetric = 0
            lastMetricTime = now
        }
        drain()
    }

    private func sendHeartbeatIfIdle() {
        guard isConnected, CACurrentMediaTime() - lastSendTime >= heartbeatInterval else { return }
        enqueueSend(.heartbeat())
    }
}
