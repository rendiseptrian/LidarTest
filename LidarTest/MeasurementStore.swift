import Foundation
import Combine
import simd

/// One point-to-point measurement. Endpoints are world-space metres, never node references:
/// chunk nodes get their geometry replaced constantly while the stream refines, and a world
/// point stays put through all of that.
nonisolated public struct RoomMeasurement: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>

    public var delta: SIMD3<Float> { end - start }
    public var distance: Float { simd_length(delta) }
    /// Distance along the floor plane (ΔXZ). What a wall-to-wall measurement usually wants.
    public var horizontal: Float { simd_length(SIMD2<Float>(delta.x, delta.z)) }
    /// Height difference (ΔY). What a floor-to-ceiling measurement usually wants.
    public var vertical: Float { abs(delta.y) }
    public var midpoint: SIMD3<Float> { (start + end) / 2 }

    /// Metres to 2 decimals, centimetres to 1 decimal under a metre.
    public static func format(_ metres: Float) -> String {
        metres < 1 ? String(format: "%.1f cm", metres * 100) : String(format: "%.2f m", metres)
    }
}

/// Measure-mode state. The scene draws from this; it never reads anything back from the scene.
@MainActor
public final class MeasurementStore: ObservableObject {
    @Published public var isActive = false {
        didSet { if !isActive { pendingPoint = nil } }
    }
    @Published public private(set) var measurements: [RoomMeasurement] = []
    /// First endpoint of a half-placed measurement.
    @Published public private(set) var pendingPoint: SIMD3<Float>?

    /// Below this the second click landed on the first point; treat it as a stray click.
    private let minimumLength: Float = 0.001

    public init() {}

    public func place(_ point: SIMD3<Float>) {
        guard isActive else { return }
        guard let start = pendingPoint else {
            pendingPoint = point
            return
        }
        guard simd_distance(start, point) >= minimumLength else { return }
        measurements.append(RoomMeasurement(start: start, end: point))
        pendingPoint = nil
    }

    /// Esc: drop a half-placed measurement, or leave measure mode if there is none.
    public func cancel() {
        if pendingPoint != nil {
            pendingPoint = nil
        } else {
            isActive = false
        }
    }

    public func remove(_ id: UUID) {
        measurements.removeAll { $0.id == id }
    }

    public func removeAll() {
        measurements.removeAll()
        pendingPoint = nil
    }

    /// Restores measurements saved with a scan.
    public func replaceAll(with saved: [RoomMeasurement]) {
        measurements = saved
        pendingPoint = nil
    }
}
