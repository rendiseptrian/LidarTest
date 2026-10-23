import Foundation
import SceneKit
import simd

/// Saving and exporting a scan. Everything here runs off the main thread on a snapshot of the
/// chunks, and every format keeps ARKit's world units: 1 unit = 1 metre, +Y up (gravity-aligned),
/// origin where the iPhone started the session.
nonisolated enum ScanFileIO {
    enum IOError: LocalizedError {
        case notAScanFile
        case unsupportedVersion(UInt32)
        case truncated
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAScanFile: return "This is not a LiDAR scan file."
            case .unsupportedVersion(let v): return "Scan file version \(v) is newer than this app supports."
            case .truncated: return "The scan file is incomplete or damaged."
            case .writeFailed(let what): return "Could not write \(what)."
            }
        }
    }

    // MARK: - Native scan file (.lidarscan)

    /// Layout: "LSCN" | UInt32 LE version | UInt32 LE chunk count | that many `MeshFrameCodec`
    /// frames | (v2+) "MEAS" | UInt32 LE count | count × 6 Float32 LE (start xyz, end xyz)
    /// | (v3+) "FRAM" | UInt32 LE mode (0 scan origin, 1 auto, 2 manual) | 4 Float32 LE (origin xyz, yaw).
    /// The room layout, when present, is one of the frames (action `.layout`).
    /// Reuses the stream's lossless frame format, so a reopened scan is bit-identical to what the
    /// iPhone sent and measures exactly the same. v1 files (no measurements) still open.
    static let scanMagic: [UInt8] = Array("LSCN".utf8)
    static let measurementMagic: [UInt8] = Array("MEAS".utf8)
    static let frameMagic: [UInt8] = Array("FRAM".utf8)
    static let scanVersion: UInt32 = 3

    struct SavedScan {
        var payloads: [MeshChunkPayload]
        var measurements: [RoomMeasurement]
        var mapFrame: MapFrame?
    }

    static func writeScan(_ payloads: [MeshChunkPayload], measurements: [RoomMeasurement] = [],
                          mapFrame: MapFrame = .scanOrigin, to url: URL) throws {
        var data = Data(scanMagic)
        appendLE(scanVersion, to: &data)
        appendLE(UInt32(payloads.count), to: &data)
        for payload in payloads {
            data.append(MeshFrameCodec.encode(payload))
        }
        data.append(contentsOf: measurementMagic)
        appendLE(UInt32(measurements.count), to: &data)
        for m in measurements {
            for value in [m.start.x, m.start.y, m.start.z, m.end.x, m.end.y, m.end.z] {
                appendLE(value.bitPattern, to: &data)
            }
        }
        data.append(contentsOf: frameMagic)
        let modeCode: UInt32 = switch mapFrame.mode { case .scanOrigin: 0; case .autoAligned: 1; case .manual: 2 }
        appendLE(modeCode, to: &data)
        for value in [mapFrame.origin.x, mapFrame.origin.y, mapFrame.origin.z, mapFrame.yaw] {
            appendLE(value.bitPattern, to: &data)
        }
        try data.write(to: url, options: .atomic)
    }

    static func readScan(from url: URL) throws -> SavedScan {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12, Array(data.prefix(4)) == scanMagic else { throw IOError.notAScanFile }
        let version = readLE(data, at: 4)
        guard version <= scanVersion else { throw IOError.unsupportedVersion(version) }
        let count = Int(readLE(data, at: 8))

        var payloads: [MeshChunkPayload] = []
        payloads.reserveCapacity(count)
        var offset = data.startIndex + 12
        for _ in 0..<count {
            let prefixEnd = offset + MeshFrameCodec.lengthPrefixSize
            guard prefixEnd <= data.endIndex,
                  let length = MeshFrameCodec.frameLength(fromPrefix: data[offset..<prefixEnd]),
                  prefixEnd + length <= data.endIndex,
                  let payload = MeshFrameCodec.decode(frame: data[prefixEnd..<(prefixEnd + length)])
            else { throw IOError.truncated }
            payloads.append(payload)
            offset = prefixEnd + length
        }

        var measurements: [RoomMeasurement] = []
        if version >= 2 {
            guard offset + 8 <= data.endIndex, Array(data[offset..<(offset + 4)]) == measurementMagic else {
                throw IOError.truncated
            }
            let count = Int(readLE(data, at: offset + 4))
            offset += 8
            guard offset + count * 24 <= data.endIndex else { throw IOError.truncated }
            for i in 0..<count {
                let f = (0..<6).map { Float(bitPattern: readLE(data, at: offset + i * 24 + $0 * 4)) }
                measurements.append(RoomMeasurement(start: SIMD3(f[0], f[1], f[2]), end: SIMD3(f[3], f[4], f[5])))
            }
            offset += count * 24
        }

        var mapFrame: MapFrame?
        if version >= 3 {
            guard offset + 24 <= data.endIndex, Array(data[offset..<(offset + 4)]) == frameMagic else {
                throw IOError.truncated
            }
            let mode: MapFrame.Mode = switch readLE(data, at: offset + 4) { case 1: .autoAligned; case 2: .manual; default: .scanOrigin }
            let f = (0..<4).map { Float(bitPattern: readLE(data, at: offset + 8 + $0 * 4)) }
            mapFrame = MapFrame(mode: mode, origin: SIMD3(f[0], f[1], f[2]), yaw: f[3])
        }
        return SavedScan(payloads: payloads, measurements: measurements, mapFrame: mapFrame)
    }

    // MARK: - OBJ (Blender, MeshLab, CloudCompare, most CAD tools)

    /// Vertices in metres in the map frame, faces grouped by surface class (`usemtl wall`,
    /// `floor`, …) with a companion .mtl, so walls/floor/furniture can be selected separately.
    /// The RoomPlan layout, when present, is added as `room_*` boxes and `furniture_*` boxes.
    static func writeOBJ(_ payloads: [MeshChunkPayload], mapFrame: MapFrame = .scanOrigin, to url: URL) throws {
        let (meshPayloads, layout) = split(payloads)
        let rotation = simd_float3x3(simd_quatf(angle: -mapFrame.yaw, axis: [0, 1, 0]))
        let mtlURL = url.deletingPathExtension().appendingPathExtension("mtl")
        try writeMTL(to: mtlURL)

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { throw IOError.writeFailed(url.lastPathComponent) }
        defer { try? handle.close() }

        var header = "# LiDAR room scan\n"
        header += "# Units: metres. +Y is up (gravity).\n"
        header += "# Origin: \(describe(mapFrame))\n"
        header += "# Faces are grouped by ARKit surface classification.\n"
        header += "mtllib \(mtlURL.lastPathComponent)\n"
        try handle.write(contentsOf: Data(header.utf8))

        var vertexBase = 1 // OBJ indices are 1-based and global across the file
        for (chunkIndex, payload) in meshPayloads.enumerated() where payload.vertexCount > 0 && payload.faceCount > 0 {
            var out = "o chunk_\(chunkIndex)\n"
            out.reserveCapacity(payload.vertexCount * 70 + payload.faceCount * 30)

            let world = worldVertices(payload)
            for w in world {
                let p = mapFrame.toMap(w)
                out += "v \(fmt(p.x)) \(fmt(p.y)) \(fmt(p.z))\n"
            }
            let normals = worldNormals(payload)
            for wn in normals {
                let n = rotation * wn
                out += "vn \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n"
            }
            let hasNormals = normals.count == world.count

            let faces = faceIndices(payload)
            let classes = faceClasses(payload)
            var currentClass: UInt8?
            // Emit faces class by class so each `usemtl` appears once per chunk.
            for cls in Set(classes).sorted() {
                for f in 0..<payload.faceCount where classes[f] == cls {
                    if currentClass != cls {
                        out += "usemtl \(surfaceName(cls))\n"
                        currentClass = cls
                    }
                    let a = Int(faces[f * 3]) + vertexBase
                    let b = Int(faces[f * 3 + 1]) + vertexBase
                    let c = Int(faces[f * 3 + 2]) + vertexBase
                    out += hasNormals ? "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n" : "f \(a) \(b) \(c)\n"
                }
            }
            vertexBase += world.count
            try handle.write(contentsOf: Data(out.utf8))
        }

        if let layout {
            var out = ""
            for (i, surface) in layout.surfaces.enumerated() {
                let size = SIMD3(surface.width, surface.height, max(surface.depth, surface.kind == .floor ? 0.02 : 0.08))
                out += "o room_\(surface.kind.rawValue)_\(i)\nusemtl room_\(surface.kind.rawValue)\n"
                out += box(boxCorners(surface.matrix, size).map(mapFrame.toMap), base: &vertexBase)
            }
            for (i, object) in layout.objects.enumerated() {
                out += "o furniture_\(object.category)_\(i)\nusemtl furniture\n"
                out += box(boxCorners(object.matrix, object.size).map(mapFrame.toMap), base: &vertexBase)
            }
            try handle.write(contentsOf: Data(out.utf8))
        }
    }

    /// Eight corners of an oriented box, index = sx·4 + sy·2 + sz with each s ∈ {0: −, 1: +}.
    static func boxCorners(_ m: simd_float4x4, _ size: SIMD3<Float>) -> [SIMD3<Float>] {
        var corners: [SIMD3<Float>] = []
        for sx: Float in [-1, 1] { for sy: Float in [-1, 1] { for sz: Float in [-1, 1] {
            let w = m * SIMD4(sx * size.x / 2, sy * size.y / 2, sz * size.z / 2, 1)
            corners.append(SIMD3(w.x, w.y, w.z))
        } } }
        return corners
    }

    private static func box(_ corners: [SIMD3<Float>], base: inout Int) -> String {
        var out = corners.map { "v \(fmt($0.x)) \(fmt($0.y)) \(fmt($0.z))\n" }.joined()
        let quads = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
        for q in quads {
            out += "f " + q.map { String($0 + base) }.joined(separator: " ") + "\n"
        }
        base += 8
        return out
    }

    /// Mesh chunks and the room layout (if any) out of a payload list.
    static func split(_ payloads: [MeshChunkPayload]) -> (mesh: [MeshChunkPayload], layout: RoomLayout?) {
        let mesh = payloads.filter { $0.action == .addOrUpdate }
        let layout = payloads.last { $0.action == .layout }.flatMap { RoomLayout(payload: $0) }
        return (mesh, layout)
    }

    static func describe(_ frame: MapFrame) -> String {
        switch frame.mode {
        case .scanOrigin: return "where the iPhone started scanning (raw ARKit frame)."
        case .autoAligned: return "auto-aligned: walls along X/Z, floor at y = 0, plan corner at x = z = 0."
        case .manual: return "set from a measurement: its start is (0,0,0) and its direction is +X."
        }
    }

    private static func writeMTL(to url: URL) throws {
        var mtl = "# Surface classes from ARKit scene reconstruction\n"
        for cls: UInt8 in 0...7 {
            let c = surfaceColor(cls)
            mtl += "newmtl \(surfaceName(cls))\nKd \(c.0) \(c.1) \(c.2)\n"
            if cls == 6 { mtl += "d 0.5\n" }
            mtl += "\n"
        }
        mtl += "# RoomPlan layout\n"
        let layoutColors: [(String, (Double, Double, Double))] = [
            ("room_wall", (0.92, 0.92, 0.92)), ("room_floor", (0.74, 0.62, 0.49)),
            ("room_door", (0.58, 0.30, 0.24)), ("room_openDoor", (0.58, 0.30, 0.24)),
            ("room_window", (0.55, 0.78, 0.92)), ("room_opening", (0.35, 0.75, 0.45)),
            ("furniture", (0.24, 0.40, 0.62)),
        ]
        for (name, c) in layoutColors {
            mtl += "newmtl \(name)\nKd \(c.0) \(c.1) \(c.2)\n\n"
        }
        try Data(mtl.utf8).write(to: url, options: .atomic)
    }

    // MARK: - USDZ (Quick Look, Reality Composer, AR on iPhone/iPad)

    static func writeUSDZ(_ payloads: [MeshChunkPayload], mapFrame: MapFrame = .scanOrigin, to url: URL) throws {
        let (meshPayloads, layout) = split(payloads)
        let scene = SCNScene()
        let content = SCNNode()
        content.simdTransform = mapFrame.worldToMap
        scene.rootNode.addChildNode(content)
        for payload in meshPayloads {
            guard let geometry = MeshGeometryHelper.makeGeometry(from: payload, mode: .realistic) else { continue }
            let node = SCNNode(geometry: geometry)
            node.simdTransform = payload.transform
            content.addChildNode(node)
        }
        if let layout {
            content.addChildNode(RoomLayoutRenderer.makeNode(layout, labels: false))
        }
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw IOError.writeFailed(url.lastPathComponent)
        }
    }

    // MARK: - Geometry helpers (shared with FloorPlanRenderer)

    static func worldVertices(_ payload: MeshChunkPayload) -> [SIMD3<Float>] {
        let count = payload.vertexCount
        guard payload.vertexData.count >= count * 12 else { return [] }
        let t = payload.transform
        return payload.vertexData.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float32.self)
            return (0..<count).map { i in
                let w = t * SIMD4<Float>(f[i * 3], f[i * 3 + 1], f[i * 3 + 2], 1)
                return SIMD3(w.x, w.y, w.z)
            }
        }
    }

    static func worldNormals(_ payload: MeshChunkPayload) -> [SIMD3<Float>] {
        let count = payload.vertexCount
        guard payload.normalData.count >= count * 12 else { return [] }
        let t = payload.transform
        let rotation = simd_float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                                     SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                     SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        return payload.normalData.withUnsafeBytes { raw in
            let f = raw.bindMemory(to: Float32.self)
            return (0..<count).map { i in
                simd_normalize(rotation * SIMD3(f[i * 3], f[i * 3 + 1], f[i * 3 + 2]))
            }
        }
    }

    static func faceIndices(_ payload: MeshChunkPayload) -> [Int32] {
        let count = payload.faceCount * 3
        guard payload.faceData.count >= count * 4 else { return [] }
        return payload.faceData.withUnsafeBytes { Array($0.bindMemory(to: Int32.self).prefix(count)) }
    }

    /// One class byte per face; 0 (unclassified) when the scan had no classification.
    static func faceClasses(_ payload: MeshChunkPayload) -> [UInt8] {
        let count = payload.faceCount
        guard payload.classificationData.count >= count else { return [UInt8](repeating: 0, count: count) }
        return Array(payload.classificationData.prefix(count))
    }

    static func surfaceName(_ cls: UInt8) -> String {
        switch cls {
        case 1: return "wall"
        case 2: return "floor"
        case 3: return "ceiling"
        case 4: return "table"
        case 5: return "seat"
        case 6: return "window"
        case 7: return "door"
        default: return "unclassified"
        }
    }

    /// Same palette as the viewer's realistic mode.
    static func surfaceColor(_ cls: UInt8) -> (Double, Double, Double) {
        switch cls {
        case 1: return (0.91, 0.89, 0.86)
        case 2: return (0.74, 0.62, 0.49)
        case 3: return (0.98, 0.98, 0.98)
        case 4: return (0.62, 0.42, 0.28)
        case 5: return (0.24, 0.36, 0.52)
        case 6: return (0.55, 0.78, 0.92)
        case 7: return (0.58, 0.30, 0.24)
        default: return (0.84, 0.84, 0.85)
        }
    }

    // MARK: - Private

    /// 0.1 mm resolution — far finer than LiDAR accuracy, so nothing measurable is lost.
    private static func fmt(_ v: Float) -> String { String(format: "%.4f", v) }

    private static func appendLE(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLE(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}
