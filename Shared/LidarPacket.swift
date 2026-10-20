import Foundation

/// Binary packet structure for streaming synchronized RGB and LiDAR depth data.
public struct LidarPacket: Sendable {
    public static let magic: UInt32 = 0x4C494452 // "LIDR"

    public struct Header: Sendable {
        public var magic: UInt32 = LidarPacket.magic
        public var frameIndex: UInt64
        public var timestamp: Double
        public var rgbWidth: UInt32
        public var rgbHeight: UInt32
        public var depthWidth: UInt32
        public var depthHeight: UInt32
        public var fx: Float
        public var fy: Float
        public var cx: Float
        public var cy: Float
        public var minDepth: Float
        public var maxDepth: Float
        public var centerDepth: Float
        public var rgbSize: UInt32
        public var depthSize: UInt32

        public init(
            frameIndex: UInt64,
            timestamp: Double,
            rgbWidth: UInt32,
            rgbHeight: UInt32,
            depthWidth: UInt32,
            depthHeight: UInt32,
            fx: Float,
            fy: Float,
            cx: Float,
            cy: Float,
            minDepth: Float,
            maxDepth: Float,
            centerDepth: Float,
            rgbSize: UInt32,
            depthSize: UInt32
        ) {
            self.frameIndex = frameIndex
            self.timestamp = timestamp
            self.rgbWidth = rgbWidth
            self.rgbHeight = rgbHeight
            self.depthWidth = depthWidth
            self.depthHeight = depthHeight
            self.fx = fx
            self.fy = fy
            self.cx = cx
            self.cy = cy
            self.minDepth = minDepth
            self.maxDepth = maxDepth
            self.centerDepth = centerDepth
            self.rgbSize = rgbSize
            self.depthSize = depthSize
        }
    }

    public let header: Header
    public let rgbData: Data
    public let depthData: Data // Raw Float32 buffer (depthWidth * depthHeight floats)

    public init(header: Header, rgbData: Data, depthData: Data) {
        self.header = header
        self.rgbData = rgbData
        self.depthData = depthData
    }

    /// Serializes packet with a 4-byte big-endian length prefix for TCP framing.
    public func serializeWithLengthPrefix() -> Data {
        let payload = serialize()
        var totalLength = UInt32(payload.count).bigEndian
        var data = Data(bytes: &totalLength, count: 4)
        data.append(payload)
        return data
    }

    /// Serializes header, rgbData, and depthData into a contiguous binary payload.
    public func serialize() -> Data {
        var data = Data()
        var headerCopy = self.header
        headerCopy.rgbSize = UInt32(rgbData.count)
        headerCopy.depthSize = UInt32(depthData.count)

        withUnsafeBytes(of: headerCopy) { ptr in
            data.append(contentsOf: ptr)
        }
        data.append(rgbData)
        data.append(depthData)
        return data
    }

    /// Deserializes a binary payload into a LidarPacket.
    public static func deserialize(from data: Data) -> LidarPacket? {
        let headerSize = MemoryLayout<Header>.size
        guard data.count >= headerSize else { return nil }

        let header = data.withUnsafeBytes { ptr -> Header in
            ptr.load(as: Header.self)
        }

        guard header.magic == LidarPacket.magic else { return nil }

        let rgbStart = headerSize
        let rgbEnd = rgbStart + Int(header.rgbSize)
        let depthEnd = rgbEnd + Int(header.depthSize)

        guard data.count >= depthEnd else { return nil }

        let rgb = data.subdata(in: rgbStart..<rgbEnd)
        let depth = data.subdata(in: rgbEnd..<depthEnd)

        return LidarPacket(header: header, rgbData: rgb, depthData: depth)
    }

    /// Returns depth values as an array of Floats in meters.
    public func depthFloats() -> [Float] {
        let count = Int(header.depthWidth * header.depthHeight)
        guard depthData.count >= count * MemoryLayout<Float>.size else { return [] }
        return depthData.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer.prefix(count))
        }
    }
}
