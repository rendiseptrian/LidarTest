import Foundation
import AppKit

public enum ColorMapType: String, CaseIterable, Identifiable {
    case turbo = "Turbo"
    case viridis = "Viridis"
    case ironbow = "Ironbow"
    case grayscale = "Grayscale"

    public var id: String { rawValue }
}

public struct ColorMaps {
    public static func renderDepthImage(
        from depthData: Data,
        width: Int,
        height: Int,
        minRange: Float,
        maxRange: Float,
        colormap: ColorMapType
    ) -> NSImage? {
        guard width > 0, height > 0 else { return nil }
        let totalPixels = width * height
        guard depthData.count >= totalPixels * MemoryLayout<Float32>.size else { return nil }

        let range = max(maxRange - minRange, 0.001)

        // Allocate RGBA8888 buffer
        var rgba = [UInt8](repeating: 0, count: totalPixels * 4)

        depthData.withUnsafeBytes { rawBuffer in
            let floats = rawBuffer.bindMemory(to: Float32.self)

            for i in 0..<totalPixels {
                let depth = floats[i]
                let byteIndex = i * 4

                if depth.isNaN || depth.isInfinite || depth <= 0.05 {
                    // Invalid / Out of range: dark slate
                    rgba[byteIndex + 0] = 18
                    rgba[byteIndex + 1] = 20
                    rgba[byteIndex + 2] = 24
                    rgba[byteIndex + 3] = 255
                    continue
                }

                // Normalized 0.0 (near) to 1.0 (far)
                let t = min(max((depth - minRange) / range, 0.0), 1.0)
                let (r, g, b) = sampleColor(t: t, colormap: colormap)

                rgba[byteIndex + 0] = r
                rgba[byteIndex + 1] = g
                rgba[byteIndex + 2] = b
                rgba[byteIndex + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private static func sampleColor(t: Float, colormap: ColorMapType) -> (UInt8, UInt8, UInt8) {
        switch colormap {
        case .turbo:
            return sampleTurbo(t)
        case .viridis:
            return sampleViridis(t)
        case .ironbow:
            return sampleIronbow(t)
        case .grayscale:
            let v = UInt8(t * 255.0)
            return (v, v, v)
        }
    }

    // Google Turbo Colormap (polynomial approximation)
    private static func sampleTurbo(_ x: Float) -> (UInt8, UInt8, UInt8) {
        let r = 0.1357 + x * ( 4.5974 - x * ( 42.3277 - x * ( 130.5887 - x * ( 150.5668 - x * 58.1375 ))))
        let g = 0.0914 + x * ( 2.1856 + x * ( 4.8052 - x * ( 14.0195 - x * ( 4.2109 - x * 2.7747 ))))
        let b = 0.1067 + x * ( 12.5732 - x * ( 80.1472 - x * ( 201.3095 - x * ( 211.2894 - x * 75.9523 ))))

        let ru = UInt8(min(max(r, 0.0), 1.0) * 255.0)
        let gu = UInt8(min(max(g, 0.0), 1.0) * 255.0)
        let bu = UInt8(min(max(b, 0.0), 1.0) * 255.0)
        return (ru, gu, bu)
    }

    // Viridis Colormap
    private static func sampleViridis(_ t: Float) -> (UInt8, UInt8, UInt8) {
        // Linear piece interpolation: Purple -> Blue -> Green -> Yellow
        let r: Float
        let g: Float
        let b: Float

        if t < 0.25 {
            let u = t / 0.25
            r = 0.26 + 0.02 * u
            g = 0.0 + 0.28 * u
            b = 0.33 + 0.2 * u
        } else if t < 0.5 {
            let u = (t - 0.25) / 0.25
            r = 0.28 - 0.15 * u
            g = 0.28 + 0.3 * u
            b = 0.53 + 0.05 * u
        } else if t < 0.75 {
            let u = (t - 0.5) / 0.25
            r = 0.13 + 0.35 * u
            g = 0.58 + 0.24 * u
            b = 0.58 - 0.25 * u
        } else {
            let u = (t - 0.75) / 0.25
            r = 0.48 + 0.51 * u
            g = 0.82 + 0.17 * u
            b = 0.33 - 0.2 * u
        }

        return (
            UInt8(min(max(r, 0.0), 1.0) * 255.0),
            UInt8(min(max(g, 0.0), 1.0) * 255.0),
            UInt8(min(max(b, 0.0), 1.0) * 255.0)
        )
    }

    // Ironbow Thermal Colormap
    private static func sampleIronbow(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let r: Float
        let g: Float
        let b: Float

        if t < 0.33 {
            let u = t / 0.33
            r = 0.1 + 0.7 * u
            g = 0.0
            b = 0.2 + 0.4 * u
        } else if t < 0.66 {
            let u = (t - 0.33) / 0.33
            r = 0.8 + 0.2 * u
            g = 0.0 + 0.7 * u
            b = 0.6 - 0.6 * u
        } else {
            let u = (t - 0.66) / 0.34
            r = 1.0
            g = 0.7 + 0.3 * u
            b = 0.0 + 0.8 * u
        }

        return (
            UInt8(min(max(r, 0.0), 1.0) * 255.0),
            UInt8(min(max(g, 0.0), 1.0) * 255.0),
            UInt8(min(max(b, 0.0), 1.0) * 255.0)
        )
    }
}
