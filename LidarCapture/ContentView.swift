import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var streamer = NetworkStreamer()
    @StateObject private var meshManager: ARMeshManager
    @State private var isTorchOn: Bool = false
    @State private var macIPInput: String = "10.60.50.88"

    init() {
        let st = NetworkStreamer()
        _streamer = StateObject(wrappedValue: st)
        _meshManager = StateObject(wrappedValue: ARMeshManager(streamer: st))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                // Top Header & Connection Status
                headerBar

                // Network IP Banner
                ipBanner

                // Live AR 3D Mesh Viewfinder
                arMeshViewfinder

                // Live Mesh Telemetry Strip
                meshTelemetryStrip

                // Scanning & Session Controls
                scanningControls
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            streamer.startListening(port: 8088)
            meshManager.startScanning()
        }
        .onDisappear {
            meshManager.pauseScanning()
            streamer.stop()
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "cube.transparent")
                        .foregroundColor(.cyan)
                    Text("LiDAR 3D Scanner")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                Text("iPhone 17 Pro Max • ARKit Mesh")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            // Status Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(streamer.isConnected ? Color.green : (streamer.isListening ? Color.blue : Color.orange))
                    .frame(width: 8, height: 8)
                Text(streamer.isConnected ? "STREAMING 3D" : (streamer.isListening ? "READY" : "OFFLINE"))
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.12))
            .cornerRadius(12)
        }
    }

    private var ipBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .foregroundColor(.cyan)
                        .font(.caption)
                    Text("iPhone IP: \(streamer.localIPAddress):8088")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                Text(meshManager.trackingStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
            }

            Spacer()

            Button(action: {
                streamer.connectToMac(host: macIPInput, port: 8088)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.circle.fill")
                    Text("Push to Mac")
                        .font(.caption2)
                        .fontWeight(.bold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }

    private var arMeshViewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.2))

            ARSCNViewContainer(session: meshManager.session)
                .cornerRadius(16)

            // Top-Right Live Mesh HUD
            VStack {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle().fill(meshManager.isPaused ? Color.orange : Color.green).frame(width: 6, height: 6)
                            Text(meshManager.isPaused ? "PAUSED" : "SCANNING")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(meshManager.isPaused ? .orange : .green)
                        }
                        Text("\(meshManager.activeChunkCount) Chunks")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.65))
                    .cornerRadius(8)
                    .padding(10)
                }
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var meshTelemetryStrip: some View {
        HStack(spacing: 12) {
            telemetryCard(title: "Vertices", value: "\(meshManager.totalVertices)", icon: "point.3.filled.connected.trianglepath.dotted")
            telemetryCard(title: "Triangles", value: "\(meshManager.totalFaces)", icon: "triangle.fill")
            telemetryCard(title: "3D Chunks", value: "\(meshManager.activeChunkCount)", icon: "square.3.layers.3d.down.right")
        }
    }

    private func telemetryCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }

    private var scanningControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Pause / Resume Scan
                Button(action: {
                    if meshManager.isPaused {
                        meshManager.resumeScanning()
                    } else {
                        meshManager.pauseScanning()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: meshManager.isPaused ? "play.fill" : "pause.fill")
                        Text(meshManager.isPaused ? "Resume Scan" : "Pause Scan")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(meshManager.isPaused ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }

                // Reset Scan
                Button(action: {
                    meshManager.resetScan()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }

                // Torch Toggle
                Button(action: toggleTorch) {
                    Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.body)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(isTorchOn ? Color.yellow.opacity(0.8) : Color.white.opacity(0.12))
                        .foregroundColor(isTorchOn ? .black : .white)
                        .cornerRadius(10)
                }
            }

            if let error = streamer.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    private func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if device.torchMode == .on {
                device.torchMode = .off
                isTorchOn = false
            } else {
                try device.setTorchModeOn(level: 1.0)
                isTorchOn = true
            }
            device.unlockForConfiguration()
        } catch {}
    }
}
