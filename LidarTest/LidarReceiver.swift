import Foundation
import Network
import AppKit
import Combine
import QuartzCore

public enum ConnectionStatus: Equatable {
    case disconnected
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)

    public var title: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .searching: return "Waiting for iPhone..."
        case .connecting(let h): return "Connecting to \(h)..."
        case .connected(let h): return "Connected: \(h)"
        case .failed(let err): return "Failed: \(err)"
        }
    }
}

@MainActor
public final class LidarReceiver: ObservableObject {
    @Published public var host: String = "10.60.50.88"
    @Published public var port: UInt16 = 8088
    @Published public private(set) var localIP: String = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
    @Published public private(set) var status: ConnectionStatus = .disconnected
    @Published public private(set) var isListening: Bool = false

    @Published public private(set) var rgbImage: NSImage?
    @Published public private(set) var depthImage: NSImage?
    @Published public private(set) var latestPacket: LidarPacket?

    @Published public private(set) var fps: Double = 0.0
    @Published public private(set) var bitrateMBs: Double = 0.0
    @Published public private(set) var latencyMs: Double = 0.0

    // Visualization settings
    @Published public var minRange: Float = 0.2 {
        didSet { reprocessDepthMap() }
    }
    @Published public var maxRange: Float = 5.0 {
        didSet { reprocessDepthMap() }
    }
    @Published public var selectedColorMap: ColorMapType = .turbo {
        didSet { reprocessDepthMap() }
    }

    // Cursor probing
    @Published public var probeDistance: Float?
    @Published public var probeNormalizedPoint: CGPoint?

    private var connection: NWConnection?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var isRunning: Bool = false

    private var frameCount: Int = 0
    private var byteCount: Int64 = 0
    private var lastMetricsTime: TimeInterval = 0

    public init() {
        self.localIP = NetworkUtils.getLocalIPAddress() ?? "127.0.0.1"
    }

    // MARK: - Client Mode (Connect to iPhone)

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
                    self.readNextPacket()
                case .failed(let error):
                    self.status = .failed(error.localizedDescription)
                    self.disconnect()
                case .cancelled:
                    if case .connecting = self.status {
                        self.status = .disconnected
                    }
                default:
                    break
                }
            }
        }

        conn.start(queue: .main)
    }

    // MARK: - Server Mode (Mac listens, iPhone connects)

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

    public func startBonjourDiscovery() {
        disconnect()
        status = .searching
        isRunning = true

        let params = NWParameters()
        params.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: "_lidartest._tcp", domain: nil), using: params)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                if let first = results.first {
                    switch first.endpoint {
                    case .service(let name, _, _, _):
                        self.host = "\(name).local"
                        self.connect()
                    case .hostPort(let h, _):
                        self.host = "\(h)"
                        self.connect()
                    default:
                        break
                    }
                }
            }
        }

        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed(let err) = state {
                    self?.status = .failed("Bonjour: \(err.localizedDescription)")
                }
            }
        }

        newBrowser.start(queue: .main)
        self.browser = newBrowser
    }

    public func disconnect() {
        isRunning = false
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        isListening = false
        status = .disconnected
    }

    // MARK: - Packet Loop

    private func readNextPacket() {
        guard let conn = connection, isRunning else { return }

        // 1. Read 4-byte length prefix
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }

                if let error = error {
                    self.status = .failed("Read length error: \(error.localizedDescription)")
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
                    self.status = .failed("Read payload error: \(error.localizedDescription)")
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
        guard let packet = LidarPacket.deserialize(from: data) else { return }

        self.latestPacket = packet
        self.byteCount += Int64(data.count + 4)
        self.frameCount += 1

        let now = CACurrentMediaTime()
        let elapsed = now - lastMetricsTime
        if elapsed >= 0.5 {
            self.fps = Double(frameCount) / elapsed
            self.bitrateMBs = (Double(byteCount) / 1_048_576.0) / elapsed
            self.frameCount = 0
            self.byteCount = 0
            self.lastMetricsTime = now
        }

        // Latency calculation
        if packet.header.timestamp > 0 {
            let systemTime = ProcessInfo.processInfo.systemUptime
            let delta = max((systemTime - packet.header.timestamp) * 1000.0, 0.0)
            self.latencyMs = delta < 1000.0 ? delta : 0.0
        }

        // Update RGB
        if let nsImage = NSImage(data: packet.rgbData) {
            self.rgbImage = nsImage
        }

        // Render Depth Heatmap
        let w = Int(packet.header.depthWidth)
        let h = Int(packet.header.depthHeight)
        let minR = self.minRange
        let maxR = self.maxRange
        let cmap = self.selectedColorMap
        let depthData = packet.depthData

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let rendered = ColorMaps.renderDepthImage(
                from: depthData,
                width: w,
                height: h,
                minRange: minR,
                maxRange: maxR,
                colormap: cmap
            )

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.depthImage = rendered
                    self?.updateProbeDistance()
                }
            }
        }
    }

    private func reprocessDepthMap() {
        guard let packet = latestPacket else { return }
        let w = Int(packet.header.depthWidth)
        let h = Int(packet.header.depthHeight)
        let minR = self.minRange
        let maxR = self.maxRange
        let cmap = self.selectedColorMap
        let depthData = packet.depthData

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rendered = ColorMaps.renderDepthImage(
                from: depthData,
                width: w,
                height: h,
                minRange: minR,
                maxRange: maxR,
                colormap: cmap
            )

            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.depthImage = rendered }
            }
        }
    }

    public func setProbePoint(_ normalized: CGPoint?) {
        self.probeNormalizedPoint = normalized
        updateProbeDistance()
    }

    private func updateProbeDistance() {
        guard let norm = probeNormalizedPoint,
              let packet = latestPacket,
              norm.x >= 0 && norm.x <= 1 && norm.y >= 0 && norm.y <= 1 else {
            self.probeDistance = nil
            return
        }

        let w = Int(packet.header.depthWidth)
        let h = Int(packet.header.depthHeight)
        guard w > 0, h > 0 else { return }

        let px = min(max(Int(norm.x * CGFloat(w)), 0), w - 1)
        let py = min(max(Int(norm.y * CGFloat(h)), 0), h - 1)
        let index = py * w + px

        let totalFloats = w * h
        guard packet.depthData.count >= totalFloats * MemoryLayout<Float32>.size else { return }

        packet.depthData.withUnsafeBytes { ptr in
            let floats = ptr.bindMemory(to: Float32.self)
            let val = floats[index]
            if !val.isNaN && !val.isInfinite && val > 0.05 {
                self.probeDistance = val
            } else {
                self.probeDistance = nil
            }
        }
    }
}
