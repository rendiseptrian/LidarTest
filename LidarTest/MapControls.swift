import SwiftUI

/// Viewport controls for the hybrid map: which layers show, how the map is oriented, and the
/// list of RoomPlan objects with their sizes.
struct MapControls: View {
    @ObservedObject var receiver: MeshReceiver
    @ObservedObject var measurements: MeasurementStore
    @State private var showObjects = false
    @State private var frameMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $receiver.showLayout) { Image(systemName: "square.split.bottomrightquarter") }
                .toggleStyle(.button)
                .help("Show RoomPlan rooms: walls, doors, windows, furniture")
            Toggle(isOn: $receiver.showMesh) { Image(systemName: "cube.transparent") }
                .toggleStyle(.button)
                .help("Show the LiDAR detail mesh")

            Menu {
                Button("Auto-align to Walls") { receiver.autoAlignMap() }
                Button("Origin & +X from Last Measurement") { useLastMeasurement() }
                    .disabled(measurements.measurements.isEmpty)
                Button("Use Scan Start as Origin") { receiver.useScanOrigin() }
                Divider()
                Text(frameDescription)
            } label: {
                Image(systemName: "scope")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Map origin and orientation. Applies to the grid, camera and every export.")

            Button(action: { showObjects.toggle() }) {
                Label("\(receiver.layout?.objects.count ?? 0)", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)
            .disabled(receiver.layout == nil)
            .help("RoomPlan objects and their sizes")
            .popover(isPresented: $showObjects, arrowEdge: .bottom) {
                RoomObjectList(layout: receiver.layout, frame: receiver.mapFrame)
            }
        }
        .alert("Map Origin", isPresented: Binding(get: { frameMessage != nil }, set: { if !$0 { frameMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(frameMessage ?? "")
        }
    }

    private var frameDescription: String {
        switch receiver.mapFrame.mode {
        case .scanOrigin: return "Now: scan start (raw ARKit)"
        case .autoAligned: return String(format: "Now: auto-aligned (rotated %.1f°)", receiver.mapFrame.yaw * 180 / .pi)
        case .manual: return "Now: set from a measurement"
        }
    }

    private func useLastMeasurement() {
        guard let last = measurements.measurements.last else { return }
        if !receiver.setMapFrame(from: last) {
            frameMessage = "That measurement is vertical, so it has no direction on the floor. Measure along the floor or a wall instead (e.g. along a wall from a corner)."
        }
    }
}

/// Every recognised object, with its size and position in map coordinates.
private struct RoomObjectList: View {
    let layout: RoomLayout?
    let frame: MapFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Room Objects").font(.headline)
            if let layout, !layout.objects.isEmpty {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Object"); Text("W × D × H"); Text("Position (x, z)")
                        }
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        ForEach(Array(layout.objects.enumerated()), id: \.offset) { _, object in
                            let p = frame.toMap(object.center)
                            GridRow {
                                Text(object.displayName)
                                Text(String(format: "%.2f × %.2f × %.2f m", object.size.x, object.size.z, object.size.y))
                                Text(String(format: "%.2f, %.2f m", p.x, p.z))
                            }
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text("\(layout.surfaces.filter { $0.kind == .wall }.count) walls · \(layout.surfaces.filter { $0.kind == .door || $0.kind == .openDoor }.count) doors · \(layout.surfaces.filter { $0.kind == .window }.count) windows · \(layout.rooms.count) rooms\(layout.isMerged ? " (merged)" : "")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("No RoomPlan objects yet. Scan in Rooms mode on the iPhone.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 420)
    }
}
