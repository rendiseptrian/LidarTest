import SwiftUI
import SceneKit

struct ContentView: View {
    @StateObject private var receiver = MeshReceiver()

    var body: some View {
        VStack(spacing: 0) {
            // Top Navigation & Connection Bar
            topBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Main 3D Viewport
            ZStack(alignment: .topTrailing) {
                SceneKitMeshView(receiver: receiver)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 3D Viewport Floating Overlay Controls
                viewportOverlayControls
                    .padding(16)

                // Navigation Instructions Tag
                VStack {
                    Spacer()
                    HStack {
                        navigationHintTag
                            .padding(16)
                        Spacer()
                    }
                }
            }

            Divider()

            // Bottom 3D Mesh Telemetry & Spatial Inspector
            bottomInspectorBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 1100, minHeight: 740)
        .background(Color(NSColor.underPageBackgroundColor))
        .onAppear {
            receiver.startListening(port: 8088)
        }
    }

    // MARK: - Top Navigation Bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // App Branding
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent")
                    .font(.title2)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text("iPhone LiDAR 3D Mapping Explorer")
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("iPhone 17 Pro Max • ARKit 3D Mesh Reconstruction")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Connection controls
            HStack(spacing: 8) {
                // Host input field
                HStack {
                    Image(systemName: "network")
                        .foregroundColor(.secondary)
                    TextField("Host / IP", text: $receiver.host)
                        .textFieldStyle(.plain)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(width: 140)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                // Connect / Disconnect / Listen buttons
                if case .connected = receiver.status {
                    Button(action: { receiver.disconnect() }) {
                        Label("Disconnect", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else if receiver.isListening {
                    Button(action: { receiver.disconnect() }) {
                        Label("Stop Listening", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button(action: { receiver.connect() }) {
                        Label("Connect", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button(action: { receiver.startListening(port: 8088) }) {
                        Label("Listen Mode", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Listen on \(receiver.localIP):8088 so iPhone can tap 'Push to Mac'")
                }

                Button(action: { receiver.clearScene() }) {
                    Image(systemName: "trash")
                        .help("Clear 3D Mesh")
                }
                .buttonStyle(.bordered)
            }

            // Status Badge & Metrics Pill
            HStack(spacing: 12) {
                statusBadge

                if case .connected = receiver.status {
                    metricsPill
                }
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 4)

            Text(receiver.status.title)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch receiver.status {
        case .connected: return .green
        case .connecting, .searching: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    private var metricsPill: some View {
        HStack(spacing: 10) {
            Label(String(format: "%.1f Chunks/s", receiver.fps), systemImage: "gauge.with.needle")
                .foregroundColor(.green)
            Text("•")
                .foregroundColor(.secondary)
            Label(String(format: "%.2f MB/s", receiver.bitrateMBs), systemImage: "arrow.down.circle")
                .foregroundColor(.cyan)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Viewport Floating Controls

    private var viewportOverlayControls: some View {
        HStack(spacing: 10) {
            // Render Mode Picker
            Picker("", selection: $receiver.renderMode) {
                ForEach(MeshRenderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 450)

            // Grid Toggle Button
            Button(action: { receiver.showGrid.toggle() }) {
                Image(systemName: receiver.showGrid ? "grid" : "grid.circle")
                    .foregroundColor(receiver.showGrid ? .cyan : .secondary)
            }
            .buttonStyle(.bordered)
            .help("Toggle Ground Grid")

            // Reset Camera Button
            Button(action: { receiver.sceneCoordinator?.resetCamera() }) {
                Image(systemName: "camera.viewfinder")
            }
            .buttonStyle(.bordered)
            .help("Reset Camera View")
        }
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var navigationHintTag: some View {
        HStack(spacing: 12) {
            Label("Orbit: Left Drag", systemImage: "arrow.triangle.2.circlepath")
            Label("Pan: Right Drag / Two Fingers", systemImage: "hand.draw")
            Label("Zoom: Scroll", systemImage: "magnifyingglass")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.65))
        .cornerRadius(8)
    }

    // MARK: - Bottom Inspector

    private var bottomInspectorBar: some View {
        HStack(spacing: 20) {
            // Card 1: 3D Geometry
            inspectorCard(title: "Mesh Complexity", icon: "triangle.fill") {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(receiver.totalFaces)")
                            .font(.system(.title2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(.cyan)
                        Text("Triangles")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("\(receiver.totalVertices) Vertices")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Card 2: Spatial Extents
            inspectorCard(title: "Spatial Extents (W × H × D)", icon: "ruler.fill") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(receiver.roomDimensions)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Calculated Room Bounding Box")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Card 3: 3D Mapping Structure
            inspectorCard(title: "Mapping Chunks", icon: "square.3.layers.3d.down.right") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(receiver.activeChunkCount) Chunks Active")
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.semibold)
                    Text("Incremental Volumetric TSDF")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }

            // Card 4: Sensor & Reconstruction Engine
            inspectorCard(title: "Reconstruction Engine", icon: "cpu") {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple ARKit Scene Reconstruction")
                        .font(.system(.caption, weight: .semibold))
                    Text("iPhone 17 Pro Max • dToF LiDAR")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func inspectorCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.cyan)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

#Preview {
    ContentView()
}
