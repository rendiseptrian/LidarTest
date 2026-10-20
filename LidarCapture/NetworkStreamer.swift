import Foundation
import Network
import Combine
import QuartzCore

@MainActor
public final class NetworkStreamer: ObservableObject {
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var clientEndpoint: String = ""
    @Published public private(set) var localIPAddress: String = "Detecting IP..."
    @Published public private(set) var fps: Double = 0.0
    @Published public private(set) var bytesSentTotal: Int64 = 0
    @Published public private(set) var lastError: String?

    // Support connecting out to Mac as client
    @Published public var targetMacHost: String = "10.60.50.88"
    @Published public var isClientMode: Bool = false

    private var listener: NWListener?
    private var activeConnection: NWConnection?

    // Backpressure & Batching queue to prevent socket buffer exhaustion
    private var pendingMeshChunks: [UUID: MeshChunkPayload] = [:]
    private var pendingChunkOrder: [UUID] = []
    private var isSendingMesh: Bool = false

    // Auto-reconnect & Heartbeat
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var frameCount: Int = 0
    private var lastFPSUpdateTime: TimeInterval = 0

    public init() {
        refreshIP()
    }

    public func refreshIP() {
        if let ip = NetworkUtils.getLocalIPAddress() {
            self.localIPAddress = ip
        } else {
            self.localIPAddress = "127.0.0.1"
        }
    }

    // MARK: - Server Mode (iPhone listens, Mac connects)

    public func startListening(port: UInt16 = 8088) {
        stop()
        refreshIP()
        isClientMode = false

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
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.lastError = nil
                    case .failed(let error):
                        self.isListening = false
                        self.lastError = "Listener failed: \(error.localizedDescription)"
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] newConnection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(newConnection)
                }
            }

            newListener.start(queue: .main)
            self.listener = newListener
            self.lastFPSUpdateTime = CACurrentMediaTime()
        } catch {
            self.lastError = "Failed to create listener: \(error.localizedDescription)"
        }
    }

    // MARK: - Client Mode (iPhone connects to Mac)

    public func connectToMac(host: String, port: UInt16 = 8088) {
        stop()
        refreshIP()
        isClientMode = true
        self.targetMacHost = host

        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let endpointHost = NWEndpoint.Host(trimmed)
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

        let connection = NWConnection(host: endpointHost, port: endpointPort, using: params)
        handleNewConnection(connection)
    }

    public func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil

        pendingMeshChunks.removeAll()
        pendingChunkOrder.removeAll()
        isSendingMesh = false

        isListening = false
        isConnected = false
        clientEndpoint = ""
    }

    private func handleNewConnection(_ connection: NWConnection) {
        activeConnection?.cancel()
        activeConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.isConnected = true
                    self.clientEndpoint = "\(connection.endpoint)"
                    self.lastError = nil
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.startHeartbeat()
                    self.drainMeshQueue()
                case .failed(let error):
                    self.handleDisconnection(reason: "Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.handleDisconnection(reason: nil)
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    private func handleDisconnection(reason: String?) {
        isConnected = false
        clientEndpoint = ""
        isSendingMesh = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if let reason = reason {
            self.lastError = reason
        }

        // Auto-reconnect if we were in client push mode
        if isClientMode && reconnectTask == nil {
            reconnectTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000) // wait 1.5s
                guard !Task.isCancelled, !self.isConnected, self.isClientMode else { return }
                self.connectToMac(host: self.targetMacHost)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // Send a tiny empty probe every 3 seconds if idle to keep Wi-Fi awake
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isConnected, !self.isSendingMesh, self.pendingChunkOrder.isEmpty else { return }
                // Heartbeat packet
                let ping = MeshChunkPayload(id: UUID(), action: .addOrUpdate, vertexCount: 0, faceCount: 0)
                let data = ping.serializeWithLengthPrefix()
                self.activeConnection?.send(content: data, completion: .idempotent)
            }
        }
    }

    // MARK: - Queue-Managed Mesh Streaming (Prevents Disconnects)

    /// Queues a mesh chunk. Replaces older versions of the same chunk to minimize bandwidth.
    public func sendMesh(payload: MeshChunkPayload) {
        guard isConnected else { return }

        // If reset action, flush queue immediately
        if payload.action == .reset {
            pendingMeshChunks.removeAll()
            pendingChunkOrder.removeAll()
            sendDirect(payload: payload)
            return
        }

        if pendingMeshChunks[payload.id] == nil {
            pendingChunkOrder.append(payload.id)
        }
        pendingMeshChunks[payload.id] = payload

        if !isSendingMesh {
            drainMeshQueue()
        }
    }

    private func drainMeshQueue() {
        guard isConnected, !isSendingMesh, let connection = activeConnection else { return }
        guard !pendingChunkOrder.isEmpty else { return }

        let nextId = pendingChunkOrder.removeFirst()
        guard let payload = pendingMeshChunks.removeValue(forKey: nextId) else {
            drainMeshQueue()
            return
        }

        isSendingMesh = true
        let data = payload.serializeWithLengthPrefix()
        let count = data.count

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isSendingMesh = false

                if let error = error {
                    self.lastError = "Send error: \(error.localizedDescription)"
                } else {
                    self.bytesSentTotal += Int64(count)
                    self.frameCount += 1

                    let now = CACurrentMediaTime()
                    let elapsed = now - self.lastFPSUpdateTime
                    if elapsed >= 1.0 {
                        self.fps = Double(self.frameCount) / elapsed
                        self.frameCount = 0
                        self.lastFPSUpdateTime = now
                    }
                }

                // Continue draining queue one by one without flooding socket
                self.drainMeshQueue()
            }
        })
    }

    private func sendDirect(payload: MeshChunkPayload) {
        guard isConnected, let connection = activeConnection else { return }
        let data = payload.serializeWithLengthPrefix()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainMeshQueue()
            }
        })
    }

    /// Transmits a LidarPacket to the connected client with backpressure check.
    public func send(packet: LidarPacket) {
        guard isConnected, let connection = activeConnection, !isSendingMesh else { return }

        isSendingMesh = true
        let data = packet.serializeWithLengthPrefix()
        let count = data.count

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isSendingMesh = false

                if let error = error {
                    self.lastError = "Send error: \(error.localizedDescription)"
                } else {
                    self.bytesSentTotal += Int64(count)
                    self.frameCount += 1

                    let now = CACurrentMediaTime()
                    let elapsed = now - self.lastFPSUpdateTime
                    if elapsed >= 1.0 {
                        self.fps = Double(self.frameCount) / elapsed
                        self.frameCount = 0
                        self.lastFPSUpdateTime = now
                    }
                }
            }
        })
    }
}
