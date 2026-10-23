import Foundation
import simd

/// The structured room model produced by RoomPlan on the iPhone, in a form the Mac can read
/// (RoomPlan itself exists only on iOS).
///
/// Coordinates are ARKit world space in metres, +Y up — the same frame as the LiDAR mesh, because
/// both modes run on one shared `ARSession`. So layout, mesh and measurements line up.
///
/// It travels as a single `MeshChunkPayload` with action `.layout` and id `RoomLayout.payloadID`,
/// JSON in `vertexData`. That reuses the stream's latest-wins queue, compression, resend on
/// reconnect, `.sync` manifest and the `.lidarscan` file format unchanged.
nonisolated public struct RoomLayout: Codable, Sendable, Equatable {
    public static let payloadID = UUID(uuidString: "5A1D0000-0000-4000-8000-00000000A001")!

    public var rooms: [Room] = []
    /// True once `StructureBuilder` has merged the finished rooms; walls shared between two rooms
    /// then appear once.
    public var isMerged = false
    public var surfaces: [Surface] = []
    public var objects: [Object] = []
    public var sections: [Section] = []

    public init() {}

    public var isEmpty: Bool { surfaces.isEmpty && objects.isEmpty }

    public struct Room: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var isComplete: Bool
        public init(id: UUID, name: String, isComplete: Bool) {
            self.id = id
            self.name = name
            self.isComplete = isComplete
        }
    }

    public enum SurfaceKind: String, Codable, Sendable {
        case wall, door, openDoor, window, opening, floor
    }

    /// A flat rectangle: `width` along local +X, `height` along local +Y, centred on `transform`.
    /// RoomPlan uses this convention for walls, doors, windows, openings and floors alike.
    public struct Surface: Codable, Sendable, Equatable {
        public var id: UUID
        public var kind: SurfaceKind
        public var width: Float
        public var height: Float
        /// RoomPlan's third dimension (0 for walls); kept so floors render right whichever local
        /// axes RoomPlan uses for them.
        public var depth: Float
        public var transform: [Float] // simd_float4x4, column-major
        public var confidence: String
        public var story: Int
        /// Floor outline in the surface's local space, when RoomPlan provides one.
        public var polygonCorners: [[Float]]
        /// Curved walls: radius in metres (drawn straight; kept so the data is not lost).
        public var curveRadius: Float?

        public var matrix: simd_float4x4 { RoomLayout.matrix(transform) }
        public var center: SIMD3<Float> { SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) }
        /// The surface's local +X axis in world space.
        public var right: SIMD3<Float> { simd_normalize(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)) }
        /// The two ends of the surface's centre line, in world space (what a plan view draws).
        public var endpoints: (SIMD3<Float>, SIMD3<Float>) {
            (center - right * width / 2, center + right * width / 2)
        }

        /// All 8 corners of the surface's box, in world space. Convention-proof footprint source.
        public var boxCorners: [SIMD3<Float>] {
            let m = matrix
            let half = SIMD3<Float>(width, height, depth) / 2
            var corners: [SIMD3<Float>] = []
            for sx: Float in [-1, 1] { for sy: Float in [-1, 1] { for sz: Float in [-1, 1] {
                let w = m * SIMD4(sx * half.x, sy * half.y, sz * half.z, 1)
                corners.append(SIMD3(w.x, w.y, w.z))
            } } }
            return corners
        }

        public init(id: UUID, kind: SurfaceKind, dimensions: SIMD3<Float>, transform: simd_float4x4,
                    confidence: String, story: Int, polygonCorners: [SIMD3<Float>], curveRadius: Float?) {
            self.id = id
            self.kind = kind
            self.width = dimensions.x
            self.height = dimensions.y
            self.depth = dimensions.z
            self.transform = RoomLayout.array(transform)
            self.confidence = confidence
            self.story = story
            self.polygonCorners = polygonCorners.map { [$0.x, $0.y, $0.z] }
            self.curveRadius = curveRadius
        }
    }

    /// A recognised piece of furniture or fixture, as an oriented box centred on `transform`.
    public struct Object: Codable, Sendable, Equatable {
        public var id: UUID
        public var category: String
        public var dimensions: [Float] // width (x), height (y), depth (z)
        public var transform: [Float]
        public var confidence: String
        public var attributes: [String]
        public var story: Int

        public var matrix: simd_float4x4 { RoomLayout.matrix(transform) }
        public var size: SIMD3<Float> { SIMD3(dimensions[0], dimensions[1], dimensions[2]) }
        public var center: SIMD3<Float> { SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) }

        /// "Sofa", "Washer/Dryer", …
        public var displayName: String {
            switch category {
            case "washerDryer": return "Washer/Dryer"
            case "television": return "TV"
            default: return category.prefix(1).uppercased() + category.dropFirst()
            }
        }

        /// The four footprint corners on the floor plane (world XZ, y = box bottom).
        public var footprint: [SIMD3<Float>] {
            let m = matrix
            let half = size / 2
            return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { sx, sz in
                let local = SIMD4<Float>(Float(sx) * half.x, -half.y, Float(sz) * half.z, 1)
                let w = m * local
                return SIMD3(w.x, w.y, w.z)
            }
        }

        public init(id: UUID, category: String, dimensions: SIMD3<Float>, transform: simd_float4x4,
                    confidence: String, attributes: [String], story: Int) {
            self.id = id
            self.category = category
            self.dimensions = [dimensions.x, dimensions.y, dimensions.z]
            self.transform = RoomLayout.array(transform)
            self.confidence = confidence
            self.attributes = attributes
            self.story = story
        }
    }

    /// A labelled area ("kitchen", "bedroom", …) with its centre point.
    public struct Section: Codable, Sendable, Equatable {
        public var label: String
        public var center: [Float]
        public var story: Int
        public init(label: String, center: SIMD3<Float>, story: Int) {
            self.label = label
            self.center = [center.x, center.y, center.z]
            self.story = story
        }
    }

    // MARK: - Wire

    public func payload() -> MeshChunkPayload {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return MeshChunkPayload(id: Self.payloadID, action: .layout, vertexData: json)
    }

    public init?(payload: MeshChunkPayload) {
        guard payload.action == .layout,
              let decoded = try? JSONDecoder().decode(RoomLayout.self, from: payload.vertexData) else { return nil }
        self = decoded
    }

    // MARK: - Matrix helpers

    static func array(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func matrix(_ a: [Float]) -> simd_float4x4 {
        guard a.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                             SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15]))
    }
}
