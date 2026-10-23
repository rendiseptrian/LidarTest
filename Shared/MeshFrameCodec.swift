import Foundation

/// Wire framing for the mesh stream.
///
///     [UInt32 big-endian length of everything after this field]
///     [UInt8 flags]            bit 0 = body is LZ4-compressed
///     [body]                   a serialized `MeshChunkPayload`
///
/// Compression is lossless: vertex positions stay Float32 metres exactly as ARKit produced them,
/// so measurements taken on the Mac are not degraded by transport.
nonisolated public enum MeshFrameCodec {
    public static let lengthPrefixSize = 4

    /// Upper bound on a single frame. A corrupt or desynchronised length prefix must not make the
    /// receiver wait for gigabytes that will never come.
    public static let maxFrameLength = 64 * 1024 * 1024

    private static let compressedFlag: UInt8 = 0x01
    private static let compressionThreshold = 2048

    public static func encode(_ payload: MeshChunkPayload) -> Data {
        let body = payload.serialize()
        var flags: UInt8 = 0
        var wireBody = body

        if body.count >= compressionThreshold,
           let compressed = try? (body as NSData).compressed(using: .lz4) as Data,
           compressed.count < body.count {
            wireBody = compressed
            flags |= compressedFlag
        }

        var length = UInt32(1 + wireBody.count).bigEndian
        var frame = Data(capacity: lengthPrefixSize + 1 + wireBody.count)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(flags)
        frame.append(wireBody)
        return frame
    }

    /// Parses the 4-byte prefix. Returns nil if the declared length is impossible.
    public static func frameLength(fromPrefix prefix: Data) -> Int? {
        guard prefix.count == lengthPrefixSize else { return nil }
        let length = Int(prefix.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard length >= 1, length <= maxFrameLength else { return nil }
        return length
    }

    /// Decodes the bytes that followed the length prefix.
    public static func decode(frame: Data) -> MeshChunkPayload? {
        guard let flags = frame.first else { return nil }
        let body = frame.dropFirst()

        if flags & compressedFlag != 0 {
            guard let raw = try? (Data(body) as NSData).decompressed(using: .lz4) as Data else { return nil }
            return MeshChunkPayload.deserialize(from: raw)
        }
        return MeshChunkPayload.deserialize(from: Data(body))
    }
}
