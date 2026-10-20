import Foundation
import simd

public enum MeshAction: UInt8, Sendable {
    case addOrUpdate = 0
    case remove = 1
    case reset = 2
}

/// A serialized 3D mesh chunk representing an ARKit ARMeshAnchor.
public struct MeshChunkPayload: Sendable {
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

    /// Serializes with a 4-byte big-endian length prefix for TCP streaming.
    public func serializeWithLengthPrefix() -> Data {
        let payload = serialize()
        var totalLength = UInt32(payload.count).bigEndian
        var data = Data(bytes: &totalLength, count: 4)
        data.append(payload)
        return data
    }

    public func serialize() -> Data {
        var data = Data()
        var headerCopy = self.header
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
            ptr.load(as: Header.self)
        }

        guard header.magic == MeshChunkPayload.magic else { return nil }

        var offset = headerSize
        let vEnd = offset + Int(header.vertexBytes)
        let nEnd = vEnd + Int(header.normalBytes)
        let fEnd = nEnd + Int(header.faceBytes)
        let cEnd = fEnd + Int(header.classificationBytes)

        guard data.count >= cEnd else { return nil }

        let vData = data.subdata(in: offset..<vEnd)
        let nData = data.subdata(in: vEnd..<nEnd)
        let fData = data.subdata(in: nEnd..<fEnd)
        let cData = data.subdata(in: fEnd..<cEnd)

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
}
