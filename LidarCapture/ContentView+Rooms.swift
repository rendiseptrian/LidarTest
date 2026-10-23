import SwiftUI
import RoomPlan

enum ScanMode: String, CaseIterable, Identifiable {
    case rooms = "Rooms"
    case detail = "Detail Mesh"
    var id: String { rawValue }
}

/// RoomPlan mode UI. Rooms is the main engine (walls, doors, windows, labelled furniture);
/// Detail Mesh adds raw LiDAR geometry for things RoomPlan does not recognise.
extension ContentView {
    var modePicker: some View {
        Picker("Mode", selection: Binding(get: { mode }, set: switchMode)) {
            ForEach(ScanMode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!roomScanner.isSupported || roomScanner.isScanningRoom || roomScanner.isProcessing)
    }

    func switchMode(_ newMode: ScanMode) {
        guard newMode != mode else { return }
        mode = newMode
        switch newMode {
        case .rooms:
            meshManager.leaveMeshMode()
        case .detail:
            roomScanner.cancelRoom()
            meshManager.enterMeshMode()
        }
    }

    func startNewScan() {
        roomScanner.reset()
        meshManager.newScan(meshMode: mode == .detail)
    }

    var roomOverlay: some View {
        VStack {
            if !roomScanner.instruction.isEmpty, roomScanner.isScanningRoom {
                Text(roomScanner.instruction)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.yellow)
                    .cornerRadius(8)
                    .padding(.top, 10)
            }
            Spacer()
            if !roomScanner.isScanningRoom && !roomScanner.isProcessing {
                Text(roomScanner.finishedRoomCount == 0
                     ? "Tap Start Room and slowly sweep the walls, floor and furniture."
                     : "Walk to the next room, then tap Start Room. Rooms are merged into one plan.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(12)
            }
        }
    }

    var roomTelemetryStrip: some View {
        HStack(spacing: 12) {
            roomCard(title: "Rooms", value: "\(roomScanner.finishedRoomCount)", icon: "square.split.2x2")
            roomCard(title: "Objects", value: "\(roomScanner.objectCount)", icon: "sofa.fill")
            roomCard(title: "Status", value: roomStatus, icon: "dot.radiowaves.left.and.right")
        }
    }

    private var roomStatus: String {
        if roomScanner.isProcessing { return "Building" }
        if roomScanner.isScanningRoom { return "Scanning" }
        return "Ready"
    }

    private func roomCard(title: String, value: String, icon: String) -> some View {
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

    var roomControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: {
                    if roomScanner.isScanningRoom { roomScanner.finishRoom() } else { roomScanner.startRoom() }
                }) {
                    HStack(spacing: 6) {
                        if roomScanner.isProcessing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: roomScanner.isScanningRoom ? "checkmark.circle.fill" : "play.fill")
                        }
                        Text(roomScanner.isProcessing ? "Building room…"
                             : roomScanner.isScanningRoom ? "Finish Room" : "Start Room")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(roomScanner.isScanningRoom ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(roomScanner.isProcessing)

                Button(action: { confirmNewScan = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("New Scan")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(roomScanner.isScanningRoom || roomScanner.isProcessing)
            }

            if let message = roomScanner.message ?? streamer.lastError {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(roomScanner.message != nil ? .yellow : .red)
                    .lineLimit(2)
            }
        }
    }
}

/// Hosts RoomPlan's own capture view (live outline of walls and furniture, coaching prompts).
struct RoomCaptureViewContainer: UIViewRepresentable {
    let captureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
