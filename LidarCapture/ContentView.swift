import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @StateObject var streamer = NetworkStreamer()
    @StateObject var meshManager: ARMeshManager
    @StateObject var roomScanner: RoomScanManager
    @State var mode: ScanMode = .rooms
    @State var confirmNewScan = false
    @State private var isTorchOn: Bool = false
    @State private var macIPInput: String = ""

    init() {
        let st = NetworkStreamer()
        let mesh = ARMeshManager(streamer: st)
        _streamer = StateObject(wrappedValue: st)
        _meshManager = StateObject(wrappedValue: mesh)
        // Both engines share the mesh manager's ARSession, so rooms and mesh share one world frame.
        _roomScanner = StateObject(wrappedValue: RoomScanManager(session: mesh.session, streamer: st))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 10) {
                // Top Header & Connection Status
                headerBar

                // Network IP Banner
                ipBanner

                // RoomPlan rooms vs. raw LiDAR detail mesh
                modePicker

                // Live AR 3D Mesh Viewfinder
                arMeshViewfinder

                // Live Telemetry Strip
                if mode == .rooms {
                    roomTelemetryStrip
                } else {
                    meshTelemetryStrip
                }

                // Scanning & Session Controls
                if mode == .rooms {
                    roomControls
                } else {
                    scanningControls
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            // Walking a large room without touching the screen used to auto-lock the phone, which
            // suspends the app, pauses ARKit and kills the socket mid-scan.
            UIApplication.shared.isIdleTimerDisabled = true
            streamer.start()
            if !roomScanner.isSupported { mode = .detail }
            meshManager.newScan(meshMode: mode == .detail)
        }
        .confirmationDialog("Start a new scan?", isPresented: $confirmNewScan, titleVisibility: .visible) {
            Button("New Scan (clears rooms and mesh)", role: .destructive) { startNewScan() }
        } message: {
            Text("Everything scanned so far is cleared here and on the Mac, and the starting point is reset. Save the scan on the Mac first if you want to keep it.")
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
                Text(mode == .rooms ? "RoomPlan • rooms, doors, furniture" : "ARKit LiDAR • detail mesh")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            // Status Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(streamer.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(streamer.isConnected ? "STREAMING 3D" : "NOT CONNECTED")
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: streamer.isConnected ? "wifi" : "wifi.exclamationmark")
                    .foregroundColor(streamer.isConnected ? .cyan : .orange)
                    .font(.caption)
                Text(streamer.status.title)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                if streamer.pendingChunkCount > 0 {
                    Text("\(streamer.pendingChunkCount) queued")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: 8) {
                TextField("Mac IP (blank = auto-discover)", text: $macIPInput)
                    .font(.system(.caption, design: .monospaced))
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .foregroundColor(.white)
                    .cornerRadius(6)

                Button(action: {
                    streamer.manualHost = macIPInput
                    streamer.reconnectNow()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Connect")
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

            HStack {
                Text(meshManager.trackingStatus)
                    .foregroundColor(.green)
                Spacer()
                Text(streamer.discoveredMacs.isEmpty ? "No Mac found yet" : "Found: \(streamer.discoveredMacs.joined(separator: ", "))")
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .font(.system(size: 10, design: .monospaced))
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }

    private var arMeshViewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.2))

            if mode == .rooms {
                RoomCaptureViewContainer(captureView: roomScanner.captureView)
                    .cornerRadius(16)
                roomOverlay
            } else {
                ARSCNViewContainer(session: meshManager.session)
                    .cornerRadius(16)
            }

            // Top-Right Live Mesh HUD
            if mode == .detail { VStack {
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
            } }
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
                    confirmNewScan = true
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
