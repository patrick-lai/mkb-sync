import Foundation

/// A point in display coordinates (points, top-left origin, y grows downward),
/// matching the CoreGraphics global display space used by event taps.
public struct VPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.init(x, y)
    }

    public static let zero = VPoint(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }

    public static func + (a: VPoint, b: VPoint) -> VPoint { VPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: VPoint, b: VPoint) -> VPoint { VPoint(a.x - b.x, a.y - b.y) }
    public static func * (a: VPoint, s: Double) -> VPoint { VPoint(a.x * s, a.y * s) }
}

public struct VRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: VPoint, width: Double, height: Double) {
        self.init(x: origin.x, y: origin.y, width: width, height: height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var origin: VPoint { VPoint(x, y) }
    public var center: VPoint { VPoint(x + width / 2, y + height / 2) }

    /// Half-open containment: the right and bottom edges belong to the neighbour.
    public func contains(_ p: VPoint) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func intersects(_ o: VRect) -> Bool {
        minX < o.maxX && o.minX < maxX && minY < o.maxY && o.minY < maxY
    }

    public func offsetBy(dx: Double, dy: Double) -> VRect {
        VRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func moved(to origin: VPoint) -> VRect {
        VRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    public func union(_ o: VRect) -> VRect {
        let nx = min(minX, o.minX), ny = min(minY, o.minY)
        return VRect(x: nx, y: ny, width: max(maxX, o.maxX) - nx, height: max(maxY, o.maxY) - ny)
    }

    /// The nearest point inside the rect (cursor positions are inclusive of maxX - 1).
    public func clamped(_ p: VPoint) -> VPoint {
        VPoint(min(max(p.x, minX), max(minX, maxX - 1)),
               min(max(p.y, minY), max(minY, maxY - 1)))
    }

    public func distanceSquared(to p: VPoint) -> Double {
        let c = clamped(p)
        let dx = c.x - p.x, dy = c.y - p.y
        return dx * dx + dy * dy
    }

    public static func union(of rects: [VRect]) -> VRect? {
        guard var r = rects.first else { return nil }
        for o in rects.dropFirst() { r = r.union(o) }
        return r
    }
}
