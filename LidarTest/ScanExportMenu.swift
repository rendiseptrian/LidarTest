import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Save / open / export menu for the top bar. File work runs off the main thread on a snapshot of
/// the scene, so the viewer stays live while a large room is written out.
struct ScanExportMenu: View {
    @ObservedObject var receiver: MeshReceiver
    @ObservedObject var measurements: MeasurementStore
    @State private var busyLabel: String?
    @State private var resultMessage: String?
    @State private var showResult = false

    static let scanType = UTType(filenameExtension: "lidarscan", conformingTo: .data) ?? .data

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Section("Save for later (includes measurements)") {
                    Button("Save Scan…") { save(.scan) }
                    Button("Open Scan…") { openScan() }
                }
                Section("3D model") {
                    Button("Export OBJ (Blender, CAD, MeshLab)…") { save(.obj) }
                    Button("Export USDZ (Quick Look, AR)…") { save(.usdz) }
                }
                Section("2D map") {
                    Button("Export Floor Plan (PNG + scale JSON, with measurements)…") { save(.floorPlan) }
                }
            } label: {
                Label("File", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(busyLabel != nil)
            .help("Save the scan, export a 3D model, or export a 2D floor plan")

            if let busyLabel {
                ProgressView().controlSize(.small)
                Text(busyLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .alert("Scan File", isPresented: $showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // MARK: - Actions

    private enum Kind {
        case scan, obj, usdz, floorPlan

        var type: UTType {
            switch self {
            case .scan: return ScanExportMenu.scanType
            case .obj: return UTType(filenameExtension: "obj") ?? .data
            case .usdz: return .usdz
            case .floorPlan: return .png
            }
        }

        var verb: String {
            switch self {
            case .scan: return "Saving scan…"
            case .obj: return "Exporting OBJ…"
            case .usdz: return "Exporting USDZ…"
            case .floorPlan: return "Rendering floor plan…"
            }
        }
    }

    private func save(_ kind: Kind) {
        let payloads = receiver.exportPayloads()
        let measured = measurements.measurements
        let frame = receiver.mapFrame
        guard !payloads.isEmpty else {
            return report("Nothing to save yet — the scene is empty.")
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName()
        if kind == .obj { panel.message = "A matching .mtl file is written next to it." }
        if kind == .floorPlan { panel.message = "A .json file with the pixel-to-metre scale is written next to it." }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busyLabel = kind.verb
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                switch kind {
                case .scan: try ScanFileIO.writeScan(payloads, measurements: measured, mapFrame: frame, to: url)
                case .obj: try ScanFileIO.writeOBJ(payloads, mapFrame: frame, to: url)
                case .usdz: try ScanFileIO.writeUSDZ(payloads, mapFrame: frame, to: url)
                case .floorPlan: try FloorPlanRenderer.write(payloads, measurements: measured, mapFrame: frame, to: url)
                }
                outcome = "Saved to \(url.lastPathComponent). Coordinates: origin \(ScanFileIO.describe(frame))"
            } catch {
                outcome = error.localizedDescription
            }
            await MainActor.run {
                busyLabel = nil
                report(outcome)
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func openScan() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.scanType]
        panel.allowsMultipleSelection = false
        panel.message = "Opening a scan stops listening for the iPhone. Press Listen to scan again."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        busyLabel = "Opening scan…"
        Task.detached(priority: .userInitiated) {
            let result = Result { try ScanFileIO.readScan(from: url) }
            await MainActor.run {
                busyLabel = nil
                switch result {
                case .success(let scan):
                    receiver.loadScan(scan.payloads, mapFrame: scan.mapFrame)
                    measurements.replaceAll(with: scan.measurements)
                case .failure(let error): report(error.localizedDescription)
                }
            }
        }
    }

    private func report(_ message: String) {
        resultMessage = message
        showResult = true
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Room Scan \(formatter.string(from: Date()))"
    }
}
