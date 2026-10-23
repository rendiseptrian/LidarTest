import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Renders a to-scale, top-down 2D floor plan (PNG) plus a JSON sidecar that maps pixels back
/// to metres, so the image can be measured, traced in CAD, or used as a map later.
///
/// Projection: looking straight down (−Y). Image right = map +X, image down = map +Z.
/// Ceilings are dropped. Floors are filled, furniture and other horizontal surfaces are filled
/// darker, and vertical surfaces (walls, doors, windows) are stroked, because a wall seen from
/// above has almost no area and would otherwise vanish.
nonisolated enum FloorPlanRenderer {
    struct Metadata: Codable {
        var pixelsPerMeter: Double
        /// Map X/Z (metres) of the image's top-left pixel corner.
        var originX: Double
        var originZ: Double
        var imageWidth: Int
        var imageHeight: Int
        var floorWidthMeters: Double
        var floorDepthMeters: Double
        var coordinateFrame: String
        var mapFrame: SavedFrame
        var projection = "top-down; image +x = map +X, image +y (down) = map +Z; units metres"
        var pixelToMap = "x = originX + px / pixelsPerMeter; z = originZ + py / pixelsPerMeter"
        var measurements: [SavedMeasurement] = []
        var walls: [SavedSegment] = []
        var doors: [SavedSegment] = []
        var windows: [SavedSegment] = []
        var objects: [SavedObject] = []
    }

    /// How map coordinates relate to the raw ARKit scan: map = rotateY(−yaw) · (world − origin).
    struct SavedFrame: Codable {
        var mode: String
        var originWorld: [Float]
        var yawDegrees: Float
    }

    /// A measurement from the viewer, in map metres, as drawn on the plan.
    struct SavedMeasurement: Codable {
        var start: [Float]
        var end: [Float]
        var distanceMeters: Float
        var horizontalMeters: Float
        var verticalMeters: Float
    }

    /// A wall/door/window centre line on the floor plane, map metres.
    struct SavedSegment: Codable {
        var from: [Float] // x, z
        var to: [Float]
        var lengthMeters: Float
        var heightMeters: Float
    }

    struct SavedObject: Codable {
        var name: String
        var center: [Float] // x, y, z in map metres
        var size: [Float] // width, height, depth
        var rotationDegrees: Float
    }

    enum RenderError: LocalizedError {
        case empty
        case encodeFailed
        var errorDescription: String? {
            switch self {
            case .empty: return "There is no scanned floor area to draw."
            case .encodeFailed: return "Could not encode the floor plan image."
            }
        }
    }

    /// 1 px = 1 cm, reduced only if the room would exceed `maxDimension` pixels.
    static let preferredPixelsPerMeter: Double = 100
    static let maxDimension: Double = 12000
    static let marginMeters: Double = 0.5

    /// Everything is drawn in map coordinates (see `MapFrame`), so an auto-aligned plan has its
    /// walls square to the image edges. The RoomPlan layout, when present, is the main drawing;
    /// the LiDAR mesh is drawn underneath, lighter, to show what RoomPlan does not recognise.
    static func write(_ payloads: [MeshChunkPayload], measurements: [RoomMeasurement] = [],
                      mapFrame: MapFrame = .scanOrigin, to pngURL: URL) throws {
        let (meshPayloads, layout) = ScanFileIO.split(payloads)
        let hasLayout = !(layout?.isEmpty ?? true)
        var floor = CGMutablePath()
        var objects = CGMutablePath()
        var walls = CGMutablePath()
        var openings = CGMutablePath()
        var lo = SIMD2<Double>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Double>(repeating: -.greatestFiniteMagnitude)
        func include(_ p: SIMD3<Float>) {
            lo = simd_min(lo, SIMD2(Double(p.x), Double(p.z)))
            hi = simd_max(hi, SIMD2(Double(p.x), Double(p.z)))
        }

        // Pass 1: mesh triangles in map metres, classified, and the plan bounds.
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, Category)] = []
        for payload in meshPayloads {
            let v = ScanFileIO.worldVertices(payload).map(mapFrame.toMap)
            let faces = ScanFileIO.faceIndices(payload)
            let classes = ScanFileIO.faceClasses(payload)
            guard !v.isEmpty, faces.count == payload.faceCount * 3 else { continue }

            for f in 0..<payload.faceCount {
                let ia = Int(faces[f * 3]), ib = Int(faces[f * 3 + 1]), ic = Int(faces[f * 3 + 2])
                guard ia < v.count, ib < v.count, ic < v.count else { continue }
                let a = v[ia], b = v[ib], c = v[ic]
                let category = categorize(cls: classes[f], a, b, c)
                guard category != .skip else { continue }
                triangles.append((a, b, c, category))
                include(a); include(b); include(c)
            }
        }
        let plan = layout.map { MapLayout($0, frame: mapFrame) }
        plan?.allPoints.forEach(include)
        guard !triangles.isEmpty || hasLayout else { throw RenderError.empty }

        let size = hi - lo
        let ppm = min(preferredPixelsPerMeter, maxDimension / (max(size.x, size.y) + 2 * marginMeters))
        let origin = lo - SIMD2(repeating: marginMeters)
        let width = Int(((size.x + 2 * marginMeters) * ppm).rounded(.up))
        let height = Int(((size.y + 2 * marginMeters) * ppm).rounded(.up))

        func point(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: (Double(p.x) - origin.x) * ppm, y: (Double(p.z) - origin.y) * ppm)
        }

        // Pass 2: build one path per category.
        for (a, b, c, category) in triangles {
            let tri = [point(a), point(b), point(c)]
            switch category {
            case .floor: floor.addLines(between: tri); floor.closeSubpath()
            case .object: objects.addLines(between: tri); objects.closeSubpath()
            case .wall: walls.addLines(between: tri); walls.closeSubpath()
            case .opening: openings.addLines(between: tri); openings.closeSubpath()
            case .skip: break
            }
        }

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.encodeFailed
        }
        // Top-left origin, so pixel (px, py) maps to the metadata formula directly.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawGrid(ctx, width: width, height: height, ppm: ppm, origin: origin)

        // With a RoomPlan layout the mesh becomes a faint background layer.
        let meshAlpha: CGFloat = hasLayout ? 0.35 : 1
        let wallStroke = max(2.0, 0.04 * ppm) // ~4 cm
        fill(ctx, &floor, CGColor(red: 0.90, green: 0.86, blue: 0.80, alpha: meshAlpha), stroke: 0.6)
        fill(ctx, &objects, CGColor(red: 0.55, green: 0.62, blue: 0.72, alpha: meshAlpha), stroke: 0.6)
        stroke(ctx, &walls, CGColor(gray: 0.12, alpha: meshAlpha), width: wallStroke)
        // Doors and windows lie in the wall line, so they go on top or the wall stroke hides them.
        stroke(ctx, &openings, CGColor(red: 0.20, green: 0.55, blue: 0.85, alpha: meshAlpha), width: wallStroke)

        if let plan {
            drawLayout(ctx, plan, ppm: ppm, point: point)
        }
        drawMeasurements(ctx, measurements.map { RoomMeasurement(start: mapFrame.toMap($0.start), end: mapFrame.toMap($0.end)) },
                         ppm: ppm, origin: origin)
        drawLegend(ctx, ppm: ppm, size: size, imageHeight: height)

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.encodeFailed }
        // Physical DPI encodes the scale too: at 100 px/m, 1 inch on paper = 1 inch × (ppm × 0.0254) px.
        let dpi = ppm * 0.0254
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed }

        var metadata = Metadata(pixelsPerMeter: ppm, originX: origin.x, originZ: origin.y,
                                imageWidth: width, imageHeight: height,
                                floorWidthMeters: size.x, floorDepthMeters: size.y,
                                coordinateFrame: ScanFileIO.describe(mapFrame),
                                mapFrame: SavedFrame(mode: mapFrame.mode.rawValue,
                                                     originWorld: [mapFrame.origin.x, mapFrame.origin.y, mapFrame.origin.z],
                                                     yawDegrees: mapFrame.yaw * 180 / .pi))
        metadata.measurements = measurements.map {
            let a = mapFrame.toMap($0.start), b = mapFrame.toMap($0.end)
            return SavedMeasurement(start: [a.x, a.y, a.z], end: [b.x, b.y, b.z],
                                    distanceMeters: $0.distance, horizontalMeters: $0.horizontal, verticalMeters: $0.vertical)
        }
        if let plan {
            metadata.walls = plan.walls.map(\.saved)
            metadata.doors = plan.doors.map(\.saved)
            metadata.windows = plan.windows.map(\.saved)
            metadata.objects = plan.objects.map {
                SavedObject(name: $0.name, center: [$0.center.x, $0.center.y, $0.center.z],
                            size: [$0.size.x, $0.size.y, $0.size.z], rotationDegrees: $0.rotationDegrees)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: pngURL.deletingPathExtension().appendingPathExtension("json"),
                                           options: .atomic)
    }

    // MARK: - RoomPlan layout, in map coordinates

    private struct Segment {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var height: Float
        var saved: SavedSegment {
            SavedSegment(from: [a.x, a.z], to: [b.x, b.z], lengthMeters: simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z)),
                         heightMeters: height)
        }
    }

    private struct PlanObject {
        var name: String
        var category: String
        var footprint: [SIMD3<Float>]
        var center: SIMD3<Float>
        var size: SIMD3<Float>
        var rotationDegrees: Float
    }

    private struct MapLayout {
        var floors: [[SIMD3<Float>]] = []
        var walls: [Segment] = []
        var doors: [Segment] = []
        var windows: [Segment] = []
        var openings: [Segment] = []
        var objects: [PlanObject] = []

        init(_ layout: RoomLayout, frame: MapFrame) {
            for surface in layout.surfaces {
                if surface.kind == .floor {
                    floors.append(convexHullXZ(surface.boxCorners.map(frame.toMap)))
                    continue
                }
                let (a, b) = surface.endpoints
                let segment = Segment(a: frame.toMap(a), b: frame.toMap(b), height: surface.height)
                switch surface.kind {
                case .wall: walls.append(segment)
                case .door, .openDoor: doors.append(segment)
                case .window: windows.append(segment)
                case .opening: openings.append(segment)
                case .floor: break
                }
            }
            for object in layout.objects {
                let m = frame.worldToMap * object.matrix
                let right = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
                objects.append(PlanObject(name: object.displayName, category: object.category,
                                          footprint: object.footprint.map(frame.toMap),
                                          center: frame.toMap(object.center), size: object.size,
                                          rotationDegrees: atan2(-right.z, right.x) * 180 / .pi))
            }
        }

        var allPoints: [SIMD3<Float>] {
            floors.flatMap { $0 } + (walls + doors + windows + openings).flatMap { [$0.a, $0.b] }
                + objects.flatMap(\.footprint)
        }
    }

    private static func drawLayout(_ ctx: CGContext, _ plan: MapLayout, ppm: Double, point: (SIMD3<Float>) -> CGPoint) {
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)

        for outline in plan.floors where outline.count >= 3 {
            ctx.addLines(between: outline.map(point))
            ctx.closePath()
        }
        ctx.setFillColor(CGColor(red: 0.93, green: 0.89, blue: 0.82, alpha: 0.9))
        ctx.fillPath()

        for object in plan.objects {
            ctx.addLines(between: object.footprint.map(point))
            ctx.closePath()
            ctx.setFillColor(RoomLayoutRenderer.objectColor(object.category).withAlphaComponent(0.75).cgColor)
            ctx.setStrokeColor(RoomLayoutRenderer.objectColor(object.category).cgColor)
            ctx.setLineWidth(max(1, 0.01 * ppm))
            ctx.drawPath(using: .fillStroke)
        }

        func strokeSegments(_ segments: [Segment], _ color: CGColor, width: Double, dash: [CGFloat] = []) {
            for s in segments {
                ctx.move(to: point(s.a))
                ctx.addLine(to: point(s.b))
            }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.setLineDash(phase: 0, lengths: dash)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let wallWidth = max(3, 0.10 * ppm) // drawn 10 cm thick
        strokeSegments(plan.walls, CGColor(gray: 0.1, alpha: 1), width: wallWidth)
        // Openings, doors and windows cut the wall line, then draw their own symbol.
        strokeSegments(plan.openings + plan.doors + plan.windows, CGColor(gray: 1, alpha: 1), width: wallWidth + 2)
        strokeSegments(plan.openings, CGColor(red: 0.35, green: 0.70, blue: 0.45, alpha: 1), width: max(1.5, 0.02 * ppm),
                       dash: [CGFloat(0.08 * ppm), CGFloat(0.05 * ppm)])
        strokeSegments(plan.windows, CGColor(red: 0.25, green: 0.60, blue: 0.90, alpha: 1), width: max(2, 0.04 * ppm))
        strokeSegments(plan.doors, CGColor(red: 0.58, green: 0.30, blue: 0.24, alpha: 1), width: max(2, 0.05 * ppm))
        // Door swing: a quarter arc from one jamb, so doors read as doors on the plan.
        for door in plan.doors {
            let a = point(door.a), b = point(door.b)
            let radius = hypot(b.x - a.x, b.y - a.y)
            let angle = atan2(b.y - a.y, b.x - a.x)
            ctx.addArc(center: a, radius: radius, startAngle: angle, endAngle: angle + .pi / 2, clockwise: false)
        }
        ctx.setStrokeColor(CGColor(red: 0.58, green: 0.30, blue: 0.24, alpha: 0.6))
        ctx.setLineWidth(max(1, 0.01 * ppm))
        ctx.strokePath()

        drawObjectLabels(ctx, plan.objects, ppm: ppm, point: point)
    }

    private static func drawObjectLabels(_ ctx: CGContext, _ objects: [PlanObject], ppm: Double,
                                         point: (SIMD3<Float>) -> CGPoint) {
        guard !objects.isEmpty else { return }
        let fontSize = max(9, 0.09 * ppm)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        for object in objects {
            let label = "\(object.name)\n\(String(format: "%.2f × %.2f m", object.size.x, object.size.z))"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ])
            let c = point(object.center)
            let size = text.size()
            text.draw(in: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// Floors from RoomPlan: the convex hull of the floor box, projected onto the plan.
    private static func convexHullXZ(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        let sorted = points.sorted { ($0.x, $0.z) < ($1.x, $1.z) }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            (a.x - o.x) * (b.z - o.z) - (a.z - o.z) * (b.x - o.x)
        }
        var lower: [SIMD3<Float>] = [], upper: [SIMD3<Float>] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // MARK: - Classification

    private enum Category { case floor, object, wall, opening, skip }

    private static func categorize(cls: UInt8, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Category {
        let normal = simd_cross(b - a, c - a)
        let len = simd_length(normal)
        guard len > 1e-9 else { return .skip }
        let ny = normal.y / len

        switch cls {
        case 3: return .skip // ceiling
        case 1: return .wall
        case 6, 7: return .opening
        case 2: return .floor
        case 4, 5: return .object
        default:
            // Unclassified: decide by orientation.
            if ny < -0.7 { return .skip } // faces pointing down are ceilings/undersides
            if abs(ny) < 0.3 { return .wall }
            return .object
        }
    }

    // MARK: - Drawing

    private static func fill(_ ctx: CGContext, _ path: inout CGMutablePath, _ color: CGColor, stroke: CGFloat) {
        guard !path.isEmpty else { return }
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(stroke) // closes hairline cracks between adjacent triangles
        ctx.drawPath(using: .fillStroke)
    }

    private static func stroke(_ ctx: CGContext, _ path: inout CGMutablePath, _ color: CGColor, width: CGFloat) {
        guard !path.isEmpty else { return }
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        ctx.drawPath(using: .fillStroke)
    }

    /// 1 m grid lines aligned to whole world metres, so grid crossings are real coordinates.
    private static func drawGrid(_ ctx: CGContext, width: Int, height: Int, ppm: Double, origin: SIMD2<Double>) {
        ctx.setStrokeColor(CGColor(gray: 0.88, alpha: 1))
        ctx.setLineWidth(1)
        var x = ceil(origin.x)
        while (x - origin.x) * ppm < Double(width) {
            let px = (x - origin.x) * ppm
            ctx.move(to: CGPoint(x: px, y: 0)); ctx.addLine(to: CGPoint(x: px, y: Double(height)))
            x += 1
        }
        var z = ceil(origin.y)
        while (z - origin.y) * ppm < Double(height) {
            let py = (z - origin.y) * ppm
            ctx.move(to: CGPoint(x: 0, y: py)); ctx.addLine(to: CGPoint(x: Double(width), y: py))
            z += 1
        }
        ctx.strokePath()
    }

    /// Dimension lines in red. The label is the length you would measure on the plan (ΔXZ); when
    /// the two points were at different heights the true 3D distance is added in brackets, and a
    /// purely vertical measurement is labelled as a height.
    private static func drawMeasurements(_ ctx: CGContext, _ measurements: [RoomMeasurement], ppm: Double, origin: SIMD2<Double>) {
        guard !measurements.isEmpty else { return }
        let red = NSColor(red: 0.85, green: 0.12, blue: 0.15, alpha: 1)
        func point(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: (Double(p.x) - origin.x) * ppm, y: (Double(p.z) - origin.y) * ppm)
        }

        let fontSize = max(10, 0.11 * ppm)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        for m in measurements {
            let a = point(m.start), b = point(m.end)
            ctx.setStrokeColor(red.cgColor)
            ctx.setFillColor(red.cgColor)
            ctx.setLineWidth(max(1.5, 0.015 * ppm))
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            let r = max(3, 0.03 * ppm)
            for p in [a, b] { ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }

            let label: String
            if m.horizontal < 0.05 {
                // Straight up/down (floor to table top, floor to ceiling): it is a point on the plan.
                label = "height \(RoomMeasurement.format(m.vertical))"
            } else if m.vertical > 0.05 {
                label = "\(RoomMeasurement.format(m.horizontal)) (3D \(RoomMeasurement.format(m.distance)))"
            } else {
                label = RoomMeasurement.format(m.horizontal)
            }
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: red,
                .backgroundColor: NSColor(white: 1, alpha: 0.85),
            ])
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let textSize = text.size()
            text.draw(at: CGPoint(x: mid.x - textSize.width / 2, y: mid.y - textSize.height - r))
        }
    }

    private static func drawLegend(_ ctx: CGContext, ppm: Double, size: SIMD2<Double>, imageHeight: Int) {
        let pad = 0.12 * ppm
        let barY = Double(imageHeight) - pad - 6

        // 1 m scale bar, bottom-left.
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: pad, y: barY, width: ppm, height: 6))

        let fontSize = max(10, 0.12 * ppm)
        let text = String(format: "1 m   ·   plan %.2f m × %.2f m   ·   grid 1 m", size.x, size.y)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ]
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: CGPoint(x: pad, y: barY - fontSize * 1.5))
        NSGraphicsContext.restoreGraphicsState()
    }
}
