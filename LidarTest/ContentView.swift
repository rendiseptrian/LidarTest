import SwiftUI
import SceneKit

struct ContentView: View {
    @StateObject private var receiver = MeshReceiver()
    @StateObject private var measurements = MeasurementStore()

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
                SceneKitMeshView(receiver: receiver, measurements: measurements)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                MeasurementLabelsOverlay(store: measurements) { point in
                    receiver.sceneCoordinator?.screenPoint(of: point)
                }

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
            receiver.startListening()
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

            // Listen-only: the iPhone finds this Mac over Bonjour and connects to it.
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "network")
                        .foregroundColor(.secondary)
                    Text(verbatim: "\(receiver.localIP):\(receiver.port)")
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .help("The iPhone finds this Mac automatically. Type this IP on the iPhone only if discovery fails.")

                if receiver.isListening {
                    Button(action: { receiver.stopListening() }) {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: { receiver.startListening() }) {
                        Label("Listen", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                ScanExportMenu(receiver: receiver, measurements: measurements)

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
        case .listening: return .orange
        case .stopped: return .gray
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
            MapControls(receiver: receiver, measurements: measurements)

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

            // Measure Toggle
            Button(action: { measurements.isActive.toggle() }) {
                Label("Measure", systemImage: "ruler")
                    .foregroundColor(measurements.isActive ? .yellow : .secondary)
            }
            .buttonStyle(.bordered)
            .help("Measure distances by clicking two points on the mesh")

            if measurements.isActive {
                Button(action: { measurements.cancel() }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .help(measurements.pendingPoint == nil ? "Exit Measure (Esc)" : "Cancel Point (Esc)")
            }

            // Reset Camera Button
            Button(action: { receiver.frameScene() }) {
                Image(systemName: "camera.viewfinder")
            }
            .buttonStyle(.bordered)
            .help("Frame Scanned Area")
        }
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var navigationHintTag: some View {
        HStack(spacing: 12) {
            if measurements.isActive {
                Label(measurements.pendingPoint == nil ? "Click: First Point" : "Click: Second Point", systemImage: "ruler")
                    .foregroundColor(.yellow)
                Label("⌥ Click: Snap to Vertex", systemImage: "smallcircle.filled.circle")
                Label("Esc: Cancel", systemImage: "escape")
                Label("Orbit: Left Drag", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Orbit: Left Drag", systemImage: "arrow.triangle.2.circlepath")
                Label("Pan: Right Drag / Two Fingers", systemImage: "hand.draw")
                Label("Zoom: Scroll", systemImage: "magnifyingglass")
            }
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

            // Card 4: Measurements
            inspectorCard(title: "Measurements", icon: "ruler") {
                MeasurementListView(store: measurements)
            }
            .overlay(alignment: .topTrailing) {
                if !measurements.measurements.isEmpty {
                    Button("Clear All") { measurements.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(8)
                        .help("Delete All Measurements")
                }
            }
            .frame(minWidth: 330)

            // Card 5: Sensor & Reconstruction Engine
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
