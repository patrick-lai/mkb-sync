import Foundation

/// The arrangement of every Mac in a space, shared by all members.
///
/// Each device's display bounding box is placed at `origins[id]` in a shared virtual
/// plane. Conflicting edits resolve last-writer-wins on (`version`, `author`).
public struct SpaceLayout: Codable, Equatable, Sendable {
    public var origins: [String: VPoint]
    public var version: UInt64
    public var author: String

    public init(origins: [String: VPoint] = [:], version: UInt64 = 0, author: String = "") {
        self.origins = origins
        self.version = version
        self.author = author
    }

    public func supersedes(_ other: SpaceLayout) -> Bool {
        if version != other.version { return version > other.version }
        return author > other.author
    }
}

/// One Mac's displays, expressed in that Mac's own global display coordinates.
public struct DeviceGeometry: Codable, Equatable, Sendable {
    public var id: String
    public var displays: [VRect]

    public init(id: String, displays: [VRect]) {
        self.id = id
        self.displays = displays.isEmpty ? [VRect(x: 0, y: 0, width: 1440, height: 900)] : displays
    }

    public var bounds: VRect { VRect.union(of: displays) ?? VRect(x: 0, y: 0, width: 1440, height: 900) }
}

/// All devices of a space placed on one virtual plane.
public struct VirtualDesktop: Equatable {
    public private(set) var devices: [String: DeviceGeometry]
    /// Resolved origin for every device (stored origin or a deterministic auto-placement).
    public private(set) var origins: [String: VPoint]

    public init(devices: [DeviceGeometry], layout: SpaceLayout) {
        var devs: [String: DeviceGeometry] = [:]
        for d in devices { devs[d.id] = d }
        self.devices = devs

        var resolved: [String: VPoint] = [:]
        var placed: [VRect] = []
        for id in devs.keys.sorted() {
            if let o = layout.origins[id] {
                resolved[id] = o
                placed.append(devs[id]!.bounds.moved(to: o))
            }
        }
        // Devices without a stored position are appended left-to-right in id order so
        // every member computes the same arrangement without coordination.
        let top = placed.map(\.minY).min() ?? 0
        var nextX = placed.map(\.maxX).max() ?? 0
        for id in devs.keys.sorted() where resolved[id] == nil {
            resolved[id] = VPoint(nextX, top)
            nextX += devs[id]!.bounds.width
        }
        self.origins = resolved
    }

    public var ids: [String] { devices.keys.sorted() }

    /// Offset that maps a device-local point into the virtual plane.
    private func offset(_ id: String) -> VPoint? {
        guard let d = devices[id], let o = origins[id] else { return nil }
        return o - d.bounds.origin
    }

    public func virtualDisplays(_ id: String) -> [VRect] {
        guard let d = devices[id], let off = offset(id) else { return [] }
        return d.displays.map { $0.offsetBy(dx: off.x, dy: off.y) }
    }

    public func virtualBounds(_ id: String) -> VRect? {
        VRect.union(of: virtualDisplays(id))
    }

    public func toVirtual(_ p: VPoint, from id: String) -> VPoint {
        p + (offset(id) ?? .zero)
    }

    public func toLocal(_ p: VPoint, on id: String) -> VPoint {
        p - (offset(id) ?? .zero)
    }

    public func contains(_ p: VPoint, device id: String) -> Bool {
        virtualDisplays(id).contains { $0.contains(p) }
    }

    public func device(at p: VPoint, excluding: Set<String> = []) -> String? {
        ids.first { !excluding.contains($0) && contains(p, device: $0) }
    }

    /// The nearest point to `p` that lies on one of `id`'s displays.
    public func clamp(_ p: VPoint, to id: String) -> VPoint {
        let rects = virtualDisplays(id)
        guard let best = rects.min(by: { $0.distanceSquared(to: p) < $1.distanceSquared(to: p) }) else { return p }
        return best.clamped(p)
    }

    /// A layout that pins every currently resolved origin (used when the user saves edits).
    public func pinnedLayout(base: SpaceLayout, overrides: [String: VPoint], author: String) -> SpaceLayout {
        var origins = base.origins
        for (id, o) in self.origins { origins[id] = o }
        for (id, o) in overrides { origins[id] = o }
        return SpaceLayout(origins: origins, version: base.version + 1, author: author)
    }
}

public enum LayoutMath {
    /// Snaps `moving` to the edges of `others` (within `threshold`) and then pushes it
    /// out of any overlap, so devices end up edge-to-edge like macOS display arrangement.
    public static func snap(_ moving: VRect, others: [VRect], threshold: Double) -> VRect {
        var r = moving

        func bestDelta(_ candidates: [Double]) -> Double? {
            candidates.filter { abs($0) <= threshold }.min { abs($0) < abs($1) }
        }

        var dxs: [Double] = [], dys: [Double] = []
        for o in others {
            dxs += [o.maxX - r.minX, o.minX - r.maxX, o.minX - r.minX, o.maxX - r.maxX]
            dys += [o.maxY - r.minY, o.minY - r.maxY, o.minY - r.minY, o.maxY - r.maxY]
        }
        if let dx = bestDelta(dxs) { r = r.offsetBy(dx: dx, dy: 0) }
        if let dy = bestDelta(dys) { r = r.offsetBy(dx: 0, dy: dy) }

        for _ in 0..<16 {
            guard let o = others.first(where: { $0.intersects(r) }) else { break }
            let pushes: [(Double, Double)] = [
                (o.maxX - r.minX, 0), (o.minX - r.maxX, 0),
                (0, o.maxY - r.minY), (0, o.minY - r.maxY),
            ]
            let p = pushes.min { abs($0.0) + abs($0.1) < abs($1.0) + abs($1.1) }!
            r = r.offsetBy(dx: p.0, dy: p.1)
        }
        return r
    }

    /// True when `r` shares a stretch of edge with at least one of `others`.
    public static func isAdjacent(_ r: VRect, to others: [VRect], tolerance: Double = 6) -> Bool {
        others.contains { o in
            let overlapY = min(r.maxY, o.maxY) - max(r.minY, o.minY) > 0
            let overlapX = min(r.maxX, o.maxX) - max(r.minX, o.minX) > 0
            let touchX = abs(r.maxX - o.minX) <= tolerance || abs(o.maxX - r.minX) <= tolerance
            let touchY = abs(r.maxY - o.minY) <= tolerance || abs(o.maxY - r.minY) <= tolerance
            return (overlapY && touchX) || (overlapX && touchY)
        }
    }
}
