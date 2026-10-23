import Foundation
import ARKit
import RoomPlan
import Combine
import QuartzCore

/// RoomPlan capture, room by room, merged into one floor plan.
///
/// Runs on the same `ARSession` as `ARMeshManager`, so room layouts and the detail mesh share one
/// world frame. Each room ends with `stop(pauseARSession: false)`: the session keeps tracking, so
/// the next room (or a switch to detail-mesh mode) continues in the same coordinates, which is
/// what `StructureBuilder` needs to merge rooms.
///
/// The phone streams one `RoomLayout` (all finished rooms, merged once there are two or more, plus
/// the room being scanned) through `NetworkStreamer`, latest wins.
@MainActor
final class RoomScanManager: NSObject, ObservableObject {
    @Published private(set) var isScanningRoom = false
    @Published private(set) var isProcessing = false
    @Published private(set) var finishedRoomCount = 0
    @Published private(set) var objectCount = 0
    @Published private(set) var instruction: String = ""
    @Published private(set) var message: String?

    let isSupported = RoomCaptureSession.isSupported
    let captureView: RoomCaptureView

    private let streamer: NetworkStreamer
    private let viewDelegate = CaptureViewDelegate()
    private var finishedRooms: [CapturedRoom] = []
    private var merged: CapturedStructure?
    private var liveRoom: CapturedRoom?
    private var lastLivePublish: TimeInterval = 0
    /// RoomPlan updates several times a second; the Mac does not need every one.
    private let livePublishInterval: TimeInterval = 0.5

    init(session: ARSession, streamer: NetworkStreamer) {
        self.streamer = streamer
        captureView = RoomCaptureView(frame: .zero, arSession: session)
        super.init()
        captureView.delegate = viewDelegate
        captureView.captureSession.delegate = self
    }

    // MARK: - Control

    func startRoom() {
        guard isSupported, !isScanningRoom, !isProcessing else { return }
        message = nil
        liveRoom = nil
        isScanningRoom = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Ends the current room. Tracking keeps running so the next room lines up with this one.
    func finishRoom() {
        guard isScanningRoom else { return }
        isScanningRoom = false
        isProcessing = true
        captureView.captureSession.stop(pauseARSession: false)
    }

    /// Leaves room capture without keeping the room in progress (switching to detail mode).
    func cancelRoom() {
        guard isScanningRoom else { return }
        isScanningRoom = false
        liveRoom = nil
        captureView.captureSession.stop(pauseARSession: false)
        publish()
    }

    /// New scan: forget every room. The caller resets tracking and the stream.
    func reset() {
        cancelRoom()
        finishedRooms.removeAll()
        merged = nil
        liveRoom = nil
        finishedRoomCount = 0
        objectCount = 0
        message = nil
    }

    // MARK: - Results

    private func roomEnded(data: CapturedRoomData, error: Error?) {
        if let error {
            message = Self.describe(error)
        }
        Task {
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                finishedRooms.append(room)
                finishedRoomCount = finishedRooms.count
                liveRoom = nil
                await mergeRooms()
            } catch {
                message = "Could not build the room: \(error.localizedDescription)"
            }
            isProcessing = false
            publish()
        }
    }

    private func mergeRooms() async {
        guard finishedRooms.count >= 2 else {
            merged = nil
            return
        }
        do {
            merged = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: finishedRooms)
        } catch {
            // Keep the rooms unmerged rather than losing them; shared walls then appear twice.
            merged = nil
            message = "Rooms kept separate (merge failed: \(error.localizedDescription))"
        }
    }

    private func publish() {
        var layout = RoomLayout()
        layout.rooms = finishedRooms.enumerated().map { index, room in
            .init(id: room.identifier, name: "Room \(index + 1)", isComplete: true)
        }

        if let merged {
            layout.isMerged = true
            append(walls: merged.walls, doors: merged.doors, windows: merged.windows, openings: merged.openings,
                   floors: merged.floors, objects: merged.objects, sections: merged.sections, to: &layout)
        } else {
            for room in finishedRooms {
                append(room, to: &layout)
            }
        }
        if let liveRoom {
            layout.rooms.append(.init(id: liveRoom.identifier, name: "Room \(finishedRooms.count + 1) (scanning)",
                                      isComplete: false))
            append(liveRoom, to: &layout)
        }

        objectCount = layout.objects.count
        if layout.isEmpty && layout.rooms.isEmpty {
            streamer.remove(id: RoomLayout.payloadID)
        } else {
            streamer.upsert(layout.payload())
        }
        lastLivePublish = CACurrentMediaTime()
    }

    // MARK: - Conversion (RoomPlan → RoomLayout)

    private func append(_ room: CapturedRoom, to layout: inout RoomLayout) {
        append(walls: room.walls, doors: room.doors, windows: room.windows, openings: room.openings,
               floors: room.floors, objects: room.objects, sections: room.sections, to: &layout)
    }

    private func append(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface], windows: [CapturedRoom.Surface],
                        openings: [CapturedRoom.Surface], floors: [CapturedRoom.Surface],
                        objects: [CapturedRoom.Object], sections: [CapturedRoom.Section],
                        to layout: inout RoomLayout) {
        for surface in floors + walls + openings + windows + doors {
            layout.surfaces.append(Self.convert(surface))
        }
        for object in objects {
            layout.objects.append(.init(
                id: object.identifier,
                category: String(describing: object.category),
                dimensions: object.dimensions,
                transform: object.transform,
                confidence: String(describing: object.confidence),
                attributes: object.attributes.map { $0.rawValue }, // not `\.rawValue`: that key path on an existential crashes the Swift 6.4 compiler
                story: object.story
            ))
        }
        for section in sections {
            layout.sections.append(.init(label: section.label.rawValue, center: section.center, story: section.story))
        }
    }

    private static func convert(_ surface: CapturedRoom.Surface) -> RoomLayout.Surface {
        let kind: RoomLayout.SurfaceKind
        switch surface.category {
        case .wall: kind = .wall
        case .opening: kind = .opening
        case .window: kind = .window
        case .door(let isOpen): kind = isOpen ? .openDoor : .door
        case .floor: kind = .floor
        @unknown default: kind = .wall
        }
        return .init(
            id: surface.identifier,
            kind: kind,
            dimensions: surface.dimensions,
            transform: surface.transform,
            confidence: String(describing: surface.confidence),
            story: surface.story,
            polygonCorners: surface.polygonCorners,
            curveRadius: surface.curve?.radius
        )
    }

    private static func describe(_ error: Error) -> String {
        if let captureError = error as? RoomCaptureSession.CaptureError {
            switch captureError {
            case .exceedSceneSizeLimit:
                return "This room reached RoomPlan's size limit. It was kept; scan the rest as the next room."
            case .deviceTooHot:
                return "The iPhone is too hot. Let it cool down, then continue with the next room."
            case .worldTrackingFailure:
                return "Tracking was lost. Move slower and point at textured surfaces."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    nonisolated private static func describe(_ instruction: RoomCaptureSession.Instruction) -> String {
        switch instruction {
        case .moveCloseToWall: return "Move closer to the wall"
        case .moveAwayFromWall: return "Move away from the wall"
        case .slowDown: return "Slow down"
        case .turnOnLight: return "Turn on more light"
        case .lowTexture: return "Low detail here — aim at textured surfaces"
        case .normal: return ""
        @unknown default: return ""
        }
    }
}

// MARK: - RoomCaptureSessionDelegate

extension RoomScanManager: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isScanningRoom else { return }
                self.liveRoom = room
                if CACurrentMediaTime() - self.lastLivePublish >= self.livePublishInterval {
                    self.publish()
                }
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text = Self.describe(instruction)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.instruction = text }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // A cancelled room (mode switch) ends here too; only finished rooms are kept.
                guard self.isProcessing else { return }
                self.roomEnded(data: data, error: error)
            }
        }
    }
}

/// `RoomCaptureView` would otherwise run its own post-processing and present a result sheet
/// after every room. This app builds and merges the rooms itself, so it declines.
@objc(LidarCaptureViewDelegate)
final class CaptureViewDelegate: NSObject, RoomCaptureViewDelegate {
    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool { false }
    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {}
}
