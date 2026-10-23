import Foundation
import simd

nonisolated public enum MeshAction: UInt8, Sendable {
    case addOrUpdate = 0
    case remove = 1
    case reset = 2
    /// Lists every anchor ID the sender currently holds; the receiver drops anything else.
    /// Sent after a full resend on (re)connect so chunks removed while offline disappear.
    case sync = 3
    /// Liveness probe. Carries no geometry and must not touch the scene.
    case heartbeat = 4
    /// The RoomPlan room layout as JSON in `vertexData` (see `RoomLayout`). Latest wins.
    case layout = 5
}

/// A serialized 3D mesh chunk representing an ARKit ARMeshAnchor.
nonisolated public struct MeshChunkPayload: Sendable {
    public static let magic: UInt32 = 0x4D455348 // "MESH"

    public struct Header: Sendable {
        public var magic: UInt32 = MeshChunkPayload.magic
        public var actionRaw: UInt8
        public var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
        public var id: UUID
        public var transform: simd_float4x4
        public var vertexCount: UInt32
        public var normalCount: UInt32
        public var faceCount: UInt32
        public var classificationCount: UInt32
        public var vertexBytes: UInt32
        public var normalBytes: UInt32
        public var faceBytes: UInt32
        public var classificationBytes: UInt32
    }

    public let header: Header
    public let vertexData: Data          // [Float32 x, y, z]
    public let normalData: Data          // [Float32 nx, ny, nz]
    public let faceData: Data            // [Int32 i0, i1, i2]
    public let classificationData: Data  // [UInt8 classification]

    public var id: UUID { header.id }
    public var action: MeshAction { MeshAction(rawValue: header.actionRaw) ?? .addOrUpdate }
    public var transform: simd_float4x4 { header.transform }
    public var vertexCount: Int { Int(header.vertexCount) }
    public var faceCount: Int { Int(header.faceCount) }

    public init(
        id: UUID,
        action: MeshAction,
        transform: simd_float4x4 = matrix_identity_float4x4,
        vertexCount: Int = 0,
        normalCount: Int = 0,
        faceCount: Int = 0,
        vertexData: Data = Data(),
        normalData: Data = Data(),
        faceData: Data = Data(),
        classificationData: Data = Data()
    ) {
        self.header = Header(
            magic: MeshChunkPayload.magic,
            actionRaw: action.rawValue,
            id: id,
            transform: transform,
            vertexCount: UInt32(vertexCount),
            normalCount: UInt32(normalCount),
            faceCount: UInt32(faceCount),
            classificationCount: UInt32(classificationData.count),
            vertexBytes: UInt32(vertexData.count),
            normalBytes: UInt32(normalData.count),
            faceBytes: UInt32(faceData.count),
            classificationBytes: UInt32(classificationData.count)
        )
        self.vertexData = vertexData
        self.normalData = normalData
        self.faceData = faceData
        self.classificationData = classificationData
    }

    /// Body only; framing and compression live in `MeshFrameCodec`.
    public func serialize() -> Data {
        var data = Data()
        let headerCopy = self.header
        withUnsafeBytes(of: headerCopy) { ptr in
            data.append(contentsOf: ptr)
        }
        data.append(vertexData)
        data.append(normalData)
        data.append(faceData)
        data.append(classificationData)
        return data
    }

    public static func deserialize(from data: Data) -> MeshChunkPayload? {
        let headerSize = MemoryLayout<Header>.size
        guard data.count >= headerSize else { return nil }

        let header = data.withUnsafeBytes { ptr -> Header in
            ptr.loadUnaligned(as: Header.self)
        }

        guard header.magic == MeshChunkPayload.magic else { return nil }

        let offset = headerSize
        let vEnd = offset + Int(header.vertexBytes)
        let nEnd = vEnd + Int(header.normalBytes)
        let fEnd = nEnd + Int(header.faceBytes)
        let cEnd = fEnd + Int(header.classificationBytes)

        guard data.count >= cEnd else { return nil }

        let base = data.startIndex
        let vData = data.subdata(in: (base + offset)..<(base + vEnd))
        let nData = data.subdata(in: (base + vEnd)..<(base + nEnd))
        let fData = data.subdata(in: (base + nEnd)..<(base + fEnd))
        let cData = data.subdata(in: (base + fEnd)..<(base + cEnd))

        return MeshChunkPayload(
            id: header.id,
            action: MeshAction(rawValue: header.actionRaw) ?? .addOrUpdate,
            transform: header.transform,
            vertexCount: Int(header.vertexCount),
            normalCount: Int(header.normalCount),
            faceCount: Int(header.faceCount),
            vertexData: vData,
            normalData: nData,
            faceData: fData,
            classificationData: cData
        )
    }

    // MARK: - Control messages

    public static func heartbeat() -> MeshChunkPayload {
        MeshChunkPayload(id: UUID(), action: .heartbeat)
    }

    /// The anchor-ID manifest travels in `vertexData` as packed 16-byte UUIDs.
    public static func syncManifest(ids: [UUID]) -> MeshChunkPayload {
        var data = Data(capacity: ids.count * 16)
        for id in ids {
            withUnsafeBytes(of: id.uuid) { data.append(contentsOf: $0) }
        }
        return MeshChunkPayload(id: UUID(), action: .sync, vertexData: data)
    }

    public var manifestIDs: Set<UUID> {
        guard action == .sync else { return [] }
        var ids = Set<UUID>()
        vertexData.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 15, by: 16) {
                ids.insert(UUID(uuid: raw.loadUnaligned(fromByteOffset: offset, as: uuid_t.self)))
            }
        }
        return ids
    }
}
