import Foundation
import SceneKit

#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

public enum MeshRenderMode: String, CaseIterable, Identifiable {
    case realistic = "Realistic (PBR)"
    case solid = "Studio Clay"
    case wireframe = "Neon Wireframe"
    case elevation = "Elevation"

    public var id: String { rawValue }
}

public struct MeshGeometryHelper {
    /// Creates a hardware-rendered SCNGeometry from a serialized MeshChunkPayload with realistic materials.
    public static func makeGeometry(from payload: MeshChunkPayload, mode: MeshRenderMode = .realistic) -> SCNGeometry? {
        guard payload.vertexCount > 0, payload.faceCount > 0 else { return nil }

        // 1. Vertex Source (3 floats = 12 bytes stride)
        let vertexSource = SCNGeometrySource(
            data: payload.vertexData,
            semantic: .vertex,
            vectorCount: payload.vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float32>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float32>.size * 3
        )

        var sources: [SCNGeometrySource] = [vertexSource]

        // 2. Normal Source for smooth shading
        if payload.normalData.count >= payload.vertexCount * MemoryLayout<Float32>.size * 3 {
            let normalSource = SCNGeometrySource(
                data: payload.normalData,
                semantic: .normal,
                vectorCount: payload.vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float32>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float32>.size * 3
            )
            sources.append(normalSource)
        }

        // 3. Elevation Mode: Add per-vertex color source for smooth height gradient
        if mode == .elevation {
            let colorData = makeElevationColors(from: payload.vertexData, count: payload.vertexCount)
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: payload.vertexCount,
                usesFloatComponents: false,
                componentsPerVector: 4,
                bytesPerComponent: 1,
                dataOffset: 0,
                dataStride: 4
            )
            sources.append(colorSource)
        }

        // 4. Realistic Mode: Group faces by semantic surface classification
        if mode == .realistic && payload.classificationData.count >= payload.faceCount {
            return makeClassifiedGeometry(sources: sources, payload: payload)
        }

        // 5. Single Element for Solid, Wireframe, or Elevation
        let element = SCNGeometryElement(
            data: payload.faceData,
            primitiveType: .triangles,
            primitiveCount: payload.faceCount,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = makeSingleMaterial(mode: mode)
        geometry.materials = [material]
        return geometry
    }

    // MARK: - Semantic Classification Material Splitting

    private static func makeClassifiedGeometry(
        sources: [SCNGeometrySource],
        payload: MeshChunkPayload
    ) -> SCNGeometry? {
        let faceCount = payload.faceCount
        guard faceCount > 0, payload.faceData.count >= faceCount * 3 * MemoryLayout<Int32>.size else { return nil }

        // Group triangle indices by classification byte (0 to 7)
        var classIndices: [UInt8: [Int32]] = [:]

        payload.faceData.withUnsafeBytes { facePtr in
            let int32Ptr = facePtr.bindMemory(to: Int32.self)
            payload.classificationData.withUnsafeBytes { classPtr in
                let bytePtr = classPtr.bindMemory(to: UInt8.self)

                for f in 0..<faceCount {
                    let c = bytePtr[f]
                    let i0 = int32Ptr[f * 3]
                    let i1 = int32Ptr[f * 3 + 1]
                    let i2 = int32Ptr[f * 3 + 2]

                    if classIndices[c] == nil {
                        classIndices[c] = []
                    }
                    classIndices[c]?.append(i0)
                    classIndices[c]?.append(i1)
                    classIndices[c]?.append(i2)
                }
            }
        }

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []

        // Sort keys so material ordering matches element ordering
        let sortedClasses = classIndices.keys.sorted()

        for c in sortedClasses {
            guard let indices = classIndices[c], !indices.isEmpty else { continue }
            let data = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let elem = SCNGeometryElement(
                data: data,
                primitiveType: .triangles,
                primitiveCount: indices.count / 3,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            elements.append(elem)
            materials.append(materialForClassification(c))
        }

        guard !elements.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: sources, elements: elements)
        geometry.materials = materials
        return geometry
    }

    private static func materialForClassification(_ c: UInt8) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        mat.lightingModel = .physicallyBased

        // ARMeshClassification: 1=Wall, 2=Floor, 3=Ceiling, 4=Table, 5=Seat, 6=Window, 7=Door, 0=None
        switch c {
        case 1: // Wall: Architectural Linen / Off-white
            mat.diffuse.contents = color(r: 0.91, g: 0.89, b: 0.86)
            mat.roughness.contents = 0.85
            mat.metalness.contents = 0.0

        case 2: // Floor: Warm Polished Wood / Stone
            mat.diffuse.contents = color(r: 0.74, g: 0.62, b: 0.49)
            mat.roughness.contents = 0.35
            mat.metalness.contents = 0.05

        case 3: // Ceiling: Crisp White
            mat.diffuse.contents = color(r: 0.98, g: 0.98, b: 0.98)
            mat.roughness.contents = 0.90
            mat.metalness.contents = 0.0

        case 4: // Table / Desk: Walnut / Teak
            mat.diffuse.contents = color(r: 0.62, g: 0.42, b: 0.28)
            mat.roughness.contents = 0.40
            mat.metalness.contents = 0.10

        case 5: // Seat / Couch: Scandinavian Muted Navy
            mat.diffuse.contents = color(r: 0.24, g: 0.36, b: 0.52)
            mat.roughness.contents = 0.70
            mat.metalness.contents = 0.0

        case 6: // Window: Glass Cyan with Subsurface Glaze
            mat.diffuse.contents = color(r: 0.55, g: 0.78, b: 0.92, a: 0.65)
            mat.transparency = 0.65
            mat.roughness.contents = 0.10
            mat.metalness.contents = 0.30

        case 7: // Door: Warm Cherry Mahogany
            mat.diffuse.contents = color(r: 0.58, g: 0.30, b: 0.24)
            mat.roughness.contents = 0.45
            mat.metalness.contents = 0.05

        default: // Unclassified: Studio Chalk Gray
            mat.diffuse.contents = color(r: 0.84, g: 0.84, b: 0.85)
            mat.roughness.contents = 0.65
            mat.metalness.contents = 0.0
        }

        return mat
    }

    private static func makeSingleMaterial(mode: MeshRenderMode) -> SCNMaterial {
        let material = SCNMaterial()
        material.isDoubleSided = true

        switch mode {
        case .realistic, .solid:
            // High-End Studio Matte Clay
            material.diffuse.contents = color(r: 0.88, g: 0.87, b: 0.85)
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.60
            material.metalness.contents = 0.02
            material.fillMode = .fill

        case .wireframe:
            // Glowing Sci-Fi Wireframe
            material.diffuse.contents = color(r: 0.0, g: 0.88, b: 1.0)
            material.emission.contents = color(r: 0.0, g: 0.30, b: 0.50)
            material.lightingModel = .constant
            material.fillMode = .lines

        case .elevation:
            // Smooth Height Gradient using per-vertex colors
            material.diffuse.contents = PlatformColor.white
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.50
            material.metalness.contents = 0.05
            material.fillMode = .fill
        }

        return material
    }

    // Generates RGBA8888 vertex colors based on height (Y coordinate)
    private static func makeElevationColors(from vertexData: Data, count: Int) -> Data {
        var colors = [UInt8](repeating: 255, count: count * 4)

        vertexData.withUnsafeBytes { ptr in
            let floats = ptr.bindMemory(to: Float32.self)

            // Approximate floor-to-ceiling range: -0.5m to +2.5m
            let minY: Float = -0.3
            let maxY: Float = 2.2
            let span = max(maxY - minY, 0.01)

            for i in 0..<count {
                let y = floats[i * 3 + 1]
                let t = min(max((y - minY) / span, 0.0), 1.0)

                // Turbo-style rainbow: Blue (floor) -> Green -> Yellow -> Red (ceiling)
                let r: Float
                let g: Float
                let b: Float

                if t < 0.25 {
                    let u = t / 0.25
                    r = 0.1; g = 0.2 + 0.6 * u; b = 0.9
                } else if t < 0.5 {
                    let u = (t - 0.25) / 0.25
                    r = 0.1 + 0.8 * u; g = 0.8; b = 0.9 - 0.7 * u
                } else if t < 0.75 {
                    let u = (t - 0.5) / 0.25
                    r = 0.9 + 0.1 * u; g = 0.8 - 0.3 * u; b = 0.2
                } else {
                    let u = (t - 0.75) / 0.25
                    r = 1.0; g = 0.5 - 0.4 * u; b = 0.2 - 0.1 * u
                }

                let byteIdx = i * 4
                colors[byteIdx] = UInt8(min(max(r, 0.0), 1.0) * 255.0)
                colors[byteIdx + 1] = UInt8(min(max(g, 0.0), 1.0) * 255.0)
                colors[byteIdx + 2] = UInt8(min(max(b, 0.0), 1.0) * 255.0)
                colors[byteIdx + 3] = 255
            }
        }

        return Data(colors)
    }

    private static func color(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) -> PlatformColor {
        #if os(macOS)
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: a)
        #endif
    }
}
