import SwiftUI
import simd

/// Distance labels drawn over the 3D viewport, pinned to each measurement's midpoint. SwiftUI
/// text stays crisp and the same size at any zoom, which a texture in the scene would not.
struct MeasurementLabelsOverlay: View {
    @ObservedObject var store: MeasurementStore
    let project: (SIMD3<Float>) -> CGPoint?

    var body: some View {
        TimelineView(.animation(paused: store.measurements.isEmpty)) { _ in
            ZStack {
                ForEach(Array(store.measurements.enumerated()), id: \.element.id) { index, measurement in
                    if let point = project(measurement.midpoint) {
                        MeasurementLabel(number: index + 1, measurement: measurement)
                            .position(x: point.x, y: point.y - 24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }
}

private struct MeasurementLabel: View {
    let number: Int
    let measurement: RoomMeasurement

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: "#\(number)  \(RoomMeasurement.format(measurement.distance))")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)
            Text(verbatim: "ΔXZ \(RoomMeasurement.format(measurement.horizontal))  ΔY \(RoomMeasurement.format(measurement.vertical))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.75))
        .cornerRadius(6)
        .fixedSize()
    }
}

/// Body of the "Measurements" inspector card.
struct MeasurementListView: View {
    @ObservedObject var store: MeasurementStore

    var body: some View {
        if store.measurements.isEmpty {
            Text(store.isActive ? (store.pendingPoint == nil ? "Click a point on the mesh" : "Click the second point")
                                : "Turn on Measure to add one")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.measurements.enumerated()), id: \.element.id) { index, measurement in
                        row(number: index + 1, measurement: measurement)
                    }
                }
            }
            .frame(maxHeight: 64)
        }
    }

    private func row(number: Int, measurement: RoomMeasurement) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "#\(number)")
                .foregroundColor(.secondary)
            Text(RoomMeasurement.format(measurement.distance))
                .fontWeight(.bold)
                .foregroundColor(.yellow)
            Text(verbatim: "ΔXZ \(RoomMeasurement.format(measurement.horizontal))  ΔY \(RoomMeasurement.format(measurement.vertical))")
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: { store.remove(measurement.id) }) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("Delete Measurement")
        }
        .font(.system(.caption2, design: .monospaced))
    }
}
