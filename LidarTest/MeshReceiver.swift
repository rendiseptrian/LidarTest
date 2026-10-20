import Foundation
import Network
import Combine
import QuartzCore
import simd

public enum MeshConnectionStatus: Equatable {
    case disconnected
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)

    public var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .searching: return "Listening for iPhone..."
        case .connecting(let h): return "Connecting to \(h)..."
        case .connected(let h): return "Connected: \(h)"
        case .failed(let err): return "Failed: \(err)"
        }
    }
}

@MainActor
public final class MeshReceiver: ObservableObject {
    @Published public var host: String = "10.60.50.88"
    @Published public var port: UInt16 = 8088
    @Published public private(set) var localIP: String = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
    @Published public private(set) var status: MeshConnectionStatus = .disconnected
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
            sceneCoordinator?.reloadAllMaterials(chunks: cachedChunks, mode: renderMode)
        }
    }
    @Published public var showGrid: Bool = true

    public weak var sceneCoordinator: SceneKitMeshView.Coordinator?

    private var cachedChunks: [UUID: MeshChunkPayload] = [:]
    private var connection: NWConnection?
    private var listener: NWListener?
    private var isRunning: Bool = false
    private var reconnectTask: Task<Void, Never>?

    private var packetCount: Int = 0
    private var byteCount: Int64 = 0
    private var lastMetricsTime: TimeInterval = 0

    public init() {
        self.localIP = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
    }

    // MARK: - Connection Management

    public func connect() {
        disconnect()

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        status = .connecting(trimmedHost)
        isRunning = true

        let endpointHost = NWEndpoint.Host(trimmedHost)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(8088)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableFastOpen = true
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2
        tcpOptions.keepaliveInterval = 1
        tcpOptions.keepaliveCount = 5

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo

        let conn = NWConnection(host: endpointHost, port: endpointPort, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                switch state {
                case .ready:
                    self.status = .connected(trimmedHost)
                    self.lastMetricsTime = CACurrentMediaTime()
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.readNextPacket()
                case .failed(let error):
                    self.handleDisconnection(error: error.localizedDescription)
                case .cancelled:
                    if case .connecting = self.status {
                        self.handleDisconnection(error: nil)
                    }
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)
    }

    private func handleDisconnection(error: String?) {
        if let error = error {
            self.status = .failed(error)
        } else {
            self.status = .disconnected
        }
        connection?.cancel()
        connection = nil

        // Auto-reconnect if client mode was active
        if isRunning && !isListening && reconnectTask == nil {
            reconnectTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, self.isRunning, !self.isListening else { return }
                self.connect()
            }
        }
    }

    public func startListening(port: UInt16 = 8088) {
        disconnect()
        self.port = port
        self.localIP = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
        status = .searching
        isRunning = true
        isListening = true

        do {
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(8088)
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableFastOpen = true
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2
            tcpOptions.keepaliveInterval = 1
            tcpOptions.keepaliveCount = 5

            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true
            params.serviceClass = .interactiveVideo

            let newListener = try NWListener(using: params, on: nwPort)
            newListener.service = NWListener.Service(type: "_lidartest._tcp")

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isRunning else { return }
                    switch state {
                    case .ready:
                        self.status = .searching
                    case .failed(let err):
                        self.status = .failed("Listener: \(err.localizedDescription)")
                        self.disconnect()
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.connection?.cancel()
                    self.connection = conn

                    conn.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor [weak self] in
                            guard let self = self, self.isRunning else { return }
                            switch state {
                            case .ready:
                                self.status = .connected("\(conn.endpoint)")
                                self.lastMetricsTime = CACurrentMediaTime()
                                self.readNextPacket()
                            case .failed(let err):
                                self.status = .failed(err.localizedDescription)
                                self.disconnect()
                            default:
                                break
                            }
                        }
                    }

                    conn.start(queue: .main)
                }
            }

            newListener.start(queue: .main)
            self.listener = newListener
        } catch {
            self.status = .failed("Listener error: \(error.localizedDescription)")
        }
    }

    public func disconnect() {
        isRunning = false
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        isListening = false
        status = .disconnected
    }

    public func clearScene() {
        cachedChunks.removeAll()
        totalVertices = 0
        totalFaces = 0
        activeChunkCount = 0
        roomDimensions = "--"
        let resetPayload = MeshChunkPayload(id: UUID(), action: .reset)
        sceneCoordinator?.updateChunk(resetPayload, mode: renderMode)
    }

    // MARK: - Packet Loop

    private func readNextPacket() {
        guard let conn = connection, isRunning else { return }

        // Read 4-byte length prefix
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }

                if let error = error {
                    self.status = .failed("Read error: \(error.localizedDescription)")
                    return
                }

                guard let data = data, data.count == 4 else {
                    if isComplete { self.disconnect() }
                    return
                }

                let payloadLength = data.withUnsafeBytes { ptr in
                    UInt32(bigEndian: ptr.load(as: UInt32.self))
                }

                self.readPayload(length: Int(payloadLength))
            }
        }
    }

    private func readPayload(length: Int) {
        guard let conn = connection, isRunning, length > 0 else { return }

        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }

                if let error = error {
                    self.status = .failed("Payload error: \(error.localizedDescription)")
                    return
                }

                guard let data = data, data.count == length else {
                    if isComplete { self.disconnect() }
                    return
                }

                self.processIncomingPayload(data)
                self.readNextPacket()
            }
        }
    }

    private func processIncomingPayload(_ data: Data) {
        guard let meshPayload = MeshChunkPayload.deserialize(from: data) else { return }

        // Ignore empty heartbeat probes
        if meshPayload.vertexCount == 0 && meshPayload.faceCount == 0 && meshPayload.action == .addOrUpdate {
            return
        }

        self.byteCount += Int64(data.count + 4)
        self.packetCount += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastMetricsTime
        if elapsed >= 0.5 {
            self.fps = Double(packetCount) / elapsed
            self.bitrateMBs = (Double(byteCount) / 1_048_576.0) / elapsed
            self.packetCount = 0
            self.byteCount = 0
            self.lastMetricsTime = now
        }

        switch meshPayload.action {
        case .reset:
            cachedChunks.removeAll()
            sceneCoordinator?.updateChunk(meshPayload, mode: renderMode)

        case .remove:
            cachedChunks.removeValue(forKey: meshPayload.id)
            sceneCoordinator?.updateChunk(meshPayload, mode: renderMode)

        case .addOrUpdate:
            cachedChunks[meshPayload.id] = meshPayload
            sceneCoordinator?.updateChunk(meshPayload, mode: renderMode)
        }

        updateMeshTotals()
    }

    private func updateMeshTotals() {
        var vSum = 0
        var fSum = 0

        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        var minZ: Float = .greatestFiniteMagnitude
        var maxZ: Float = -.greatestFiniteMagnitude

        for (_, chunk) in cachedChunks {
            vSum += chunk.vertexCount
            fSum += chunk.faceCount

            let transform = chunk.transform
            let count = chunk.vertexCount
            guard count > 0, chunk.vertexData.count >= count * 12 else { continue }

            chunk.vertexData.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float32.self)
                for i in stride(from: 0, to: count * 3, by: 9) { // sample vertices
                    let lx = floats[i]
                    let ly = floats[i + 1]
                    let lz = floats[i + 2]
                    let localPos = simd_float4(lx, ly, lz, 1.0)
                    let worldPos = transform * localPos

                    if worldPos.x < minX { minX = worldPos.x }
                    if worldPos.x > maxX { maxX = worldPos.x }
                    if worldPos.y < minY { minY = worldPos.y }
                    if worldPos.y > maxY { maxY = worldPos.y }
                    if worldPos.z < minZ { minZ = worldPos.z }
                    if worldPos.z > maxZ { maxZ = worldPos.z }
                }
            }
        }

        self.totalVertices = vSum
        self.totalFaces = fSum
        self.activeChunkCount = cachedChunks.count

        if minX < maxX && minY < maxY && minZ < maxZ {
            let dx = maxX - minX
            let dy = maxY - minY
            let dz = maxZ - minZ
            self.roomDimensions = String(format: "%.1f m × %.1f m × %.1f m", dx, dy, dz)
        } else {
            self.roomDimensions = "--"
        }
    }
}
