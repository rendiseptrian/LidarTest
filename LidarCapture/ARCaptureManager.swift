import Foundation
import ARKit
import AVFoundation
import CoreImage
import UIKit
import Combine
import QuartzCore
import ImageIO

@MainActor
public final class ARCaptureManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published public private(set) var isLidarSupported: Bool = false
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var centerDistance: Float = 0.0
    @Published public private(set) var minDistance: Float = 0.0
    @Published public private(set) var maxDistance: Float = 0.0
    @Published public private(set) var depthWidth: Int = 0
    @Published public private(set) var depthHeight: Int = 0
    @Published public private(set) var previewImage: UIImage?
    @Published public var useSmoothedDepth: Bool = false
    @Published public var isStreamingEnabled: Bool = true

    public let session = ARSession()
    private let streamer: NetworkStreamer
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var frameIndex: UInt64 = 0
    private var lastCaptureTimestamp: TimeInterval = 0
    private let minFrameInterval: TimeInterval = 1.0 / 30.0 // Cap at ~30 FPS

    public init(streamer: NetworkStreamer) {
        self.streamer = streamer
        super.init()
        self.isLidarSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    public func start() {
        guard isLidarSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        var semantics: ARConfiguration.FrameSemantics = [.sceneDepth]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            semantics.insert(.smoothedSceneDepth)
        }
        configuration.frameSemantics = semantics

        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
    }

    public func stop() {
        session.pause()
        isRunning = false
    }

    // MARK: - ARSessionDelegate

    nonisolated public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            self.processFrame(frame)
        }
    }

    private func processFrame(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        guard now - lastCaptureTimestamp >= minFrameInterval else { return }
        lastCaptureTimestamp = now

        // 1. Extract LiDAR Depth Map
        let depthDataObj = useSmoothedDepth ? (frame.smoothedSceneDepth ?? frame.sceneDepth) : frame.sceneDepth
        guard let sceneDepth = depthDataObj else { return }

        let depthPixelBuffer = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)
        self.depthWidth = width
        self.depthHeight = height

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
        let totalPixels = width * height

        // Compute Center Pixel Distance
        let centerPixelIndex = (height / 2) * width + (width / 2)
        let rawCenterDist = floatBuffer[centerPixelIndex]
        if !rawCenterDist.isNaN && !rawCenterDist.isInfinite && rawCenterDist > 0.05 {
            self.centerDistance = rawCenterDist
        }

        // Compute Min & Max Distances
        var minVal: Float = 100.0
        var maxVal: Float = 0.0
        for i in stride(from: 0, to: totalPixels, by: 4) { // Fast sample
            let val = floatBuffer[i]
            if !val.isNaN && !val.isInfinite && val > 0.1 && val < 10.0 {
                if val < minVal { minVal = val }
                if val > maxVal { maxVal = val }
            }
        }
        self.minDistance = minVal < 100.0 ? minVal : 0.0
        self.maxDistance = maxVal

        // Package raw depth float bytes
        let depthByteCount = totalPixels * MemoryLayout<Float32>.size
        let depthPayload = Data(bytes: baseAddress, count: depthByteCount)

        // 2. Extract RGB camera image and downsample for streaming
        let capturedImage = frame.capturedImage
        let originalWidth = CVPixelBufferGetWidth(capturedImage)
        let originalHeight = CVPixelBufferGetHeight(capturedImage)

        // Target streaming resolution (e.g., ~640x480 landscape or portrait)
        let scale: CGFloat = 0.33
        let targetWidth = Int(CGFloat(originalWidth) * scale)
        let targetHeight = Int(CGFloat(originalHeight) * scale)

        let ciImage = CIImage(cvPixelBuffer: capturedImage)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            return
        }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.65) else {
            return
        }

        // Local preview update (every ~3 frames to save UI cycles)
        if frameIndex % 3 == 0 {
            self.previewImage = uiImage
        }

        // 3. Extract and scale Camera Intrinsics
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0, 0] * Float(scale)
        let fy = intrinsics[1, 1] * Float(scale)
        let cx = intrinsics[2, 0] * Float(scale)
        let cy = intrinsics[2, 1] * Float(scale)

        frameIndex += 1

        guard isStreamingEnabled else { return }

        // 4. Construct LidarPacket and send over network
        let header = LidarPacket.Header(
            frameIndex: frameIndex,
            timestamp: frame.timestamp,
            rgbWidth: UInt32(targetWidth),
            rgbHeight: UInt32(targetHeight),
            depthWidth: UInt32(width),
            depthHeight: UInt32(height),
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy,
            minDepth: self.minDistance,
            maxDepth: self.maxDistance,
            centerDepth: self.centerDistance,
            rgbSize: UInt32(jpegData.count),
            depthSize: UInt32(depthPayload.count)
        )

        // Depth frames are not part of the mesh stream the Mac app reads, and mixing them into it
        // would corrupt its framing. Kept for local use; not transmitted.
        _ = LidarPacket(header: header, rgbData: jpegData, depthData: depthPayload)
    }
}
