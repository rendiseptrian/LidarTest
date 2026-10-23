import AppKit
import SceneKit
import simd

/// Builds SceneKit nodes for a RoomPlan layout: walls, floors, doors, windows and openings as thin
/// boxes, furniture as labelled translucent boxes. Used by the live viewer and the USDZ export.
///
/// Every node is a real, hit-testable box in world metres, so the measuring tool can snap to a
/// wall face or the top of a table exactly.
nonisolated enum RoomLayoutRenderer {
    static func makeNode(_ layout: RoomLayout, labels: Bool = true) -> SCNNode {
        let root = SCNNode()
        root.name = "roomLayout"

        for surface in layout.surfaces {
            let thickness: CGFloat
            switch surface.kind {
            case .floor: thickness = 0.02
            case .wall: thickness = 0.08
            case .door, .openDoor, .window: thickness = 0.12 // proud of the wall so it stays visible
            case .opening: thickness = 0.1
            }
            let box = SCNBox(width: CGFloat(surface.width), height: CGFloat(surface.height),
                             length: max(CGFloat(surface.depth), thickness), chamferRadius: 0)
            box.materials = [material(for: surface.kind)]
            let node = SCNNode(geometry: box)
            node.simdTransform = surface.matrix
            node.castsShadow = false
            node.name = surface.kind.rawValue
            root.addChildNode(node)
        }

        for object in layout.objects {
            let size = object.size
            let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0.01)
            box.materials = [objectMaterial(object.category)]
            let node = SCNNode(geometry: box)
            node.simdTransform = object.matrix
            node.castsShadow = false
            node.name = object.category
            root.addChildNode(node)

            if labels {
                root.addChildNode(makeLabel(for: object))
            }
        }
        return root
    }

    /// "Sofa · 2.10 × 0.92 m", floating above the object and always facing the camera.
    private static func makeLabel(for object: RoomLayout.Object) -> SCNNode {
        let text = SCNText(string: "\(object.displayName) · \(format(object.size.x)) × \(format(object.size.z))", extrusionDepth: 0)
        text.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        text.flatness = 0.2
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.lightingModel = .constant
        material.readsFromDepthBuffer = false
        text.materials = [material]

        let textNode = SCNNode(geometry: text)
        let (lo, hi) = text.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, lo.y, 0)
        textNode.scale = SCNVector3(0.01, 0.01, 0.01)
        textNode.renderingOrder = 100

        let holder = SCNNode()
        holder.addChildNode(textNode)
        holder.simdPosition = object.center + SIMD3(0, object.size.y / 2 + 0.08, 0)
        holder.constraints = [SCNBillboardConstraint()]
        holder.name = "label"
        return holder
    }

    private static func format(_ metres: Float) -> String { String(format: "%.2f", metres) + " m" }

    private static func material(for kind: RoomLayout.SurfaceKind) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.8
        m.isDoubleSided = true
        switch kind {
        case .wall:
            m.diffuse.contents = NSColor(white: 0.92, alpha: 1)
            m.transparency = 0.8
        case .floor:
            m.diffuse.contents = NSColor(red: 0.74, green: 0.62, blue: 0.49, alpha: 1)
        case .door, .openDoor:
            m.diffuse.contents = NSColor(red: 0.58, green: 0.30, blue: 0.24, alpha: 1)
        case .window:
            m.diffuse.contents = NSColor(red: 0.55, green: 0.78, blue: 0.92, alpha: 1)
            m.transparency = 0.55
        case .opening:
            m.diffuse.contents = NSColor(red: 0.35, green: 0.75, blue: 0.45, alpha: 1)
            m.transparency = 0.3
        }
        return m
    }

    private static func objectMaterial(_ category: String) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.6
        m.diffuse.contents = objectColor(category)
        m.transparency = 0.85
        return m
    }

    /// Shared with the floor plan so the two read as one map.
    static func objectColor(_ category: String) -> NSColor {
        switch category {
        case "sofa", "chair", "bed": return NSColor(red: 0.24, green: 0.40, blue: 0.62, alpha: 1)
        case "table", "storage": return NSColor(red: 0.62, green: 0.42, blue: 0.28, alpha: 1)
        case "refrigerator", "stove", "oven", "dishwasher", "washerDryer", "sink":
            return NSColor(red: 0.45, green: 0.50, blue: 0.55, alpha: 1)
        case "toilet", "bathtub": return NSColor(red: 0.40, green: 0.62, blue: 0.70, alpha: 1)
        case "television", "fireplace": return NSColor(red: 0.30, green: 0.30, blue: 0.34, alpha: 1)
        case "stairs": return NSColor(red: 0.55, green: 0.45, blue: 0.62, alpha: 1)
        default: return NSColor(red: 0.50, green: 0.55, blue: 0.60, alpha: 1)
        }
    }
}
