import AppKit
import CoreGraphics
import MKBCore

enum DisplayInfo {
    /// Active, non-mirrored displays in global display coordinates (points, top-left origin).
    static func current() -> [VRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == 0 }
            .map { CGDisplayBounds($0) }
            .map { VRect(x: Double($0.origin.x), y: Double($0.origin.y), width: Double($0.width), height: Double($0.height)) }
    }

    /// Centre of the main display: where the hidden cursor is parked while remote,
    /// away from hot corners and the Dock.
    static func parkPoint() -> CGPoint {
        let b = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: b.midX, y: b.midY)
    }

    static func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
