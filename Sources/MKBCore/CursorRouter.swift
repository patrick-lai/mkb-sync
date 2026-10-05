import Foundation

/// Tracks where the shared cursor is on the virtual desktop and decides when it crosses
/// from one Mac to another. Runs on the Mac whose physical mouse is being used.
public final class CursorRouter {
    public enum Action: Equatable {
        case none
        /// Cursor left this Mac and entered `device` at a device-local point.
        case enter(device: String, at: VPoint)
        /// Cursor moved within the remote `device`.
        case move(device: String, to: VPoint)
        /// Cursor went straight from one remote Mac to another.
        case transfer(from: String, to: String, at: VPoint)
        /// Cursor came back to this Mac at a local point.
        case returnLocal(at: VPoint)
    }

    public let localID: String
    public private(set) var desktop: VirtualDesktop
    /// Device that currently owns the cursor.
    public private(set) var active: String
    /// Cursor position on the virtual plane while remote.
    public private(set) var cursor: VPoint = .zero
    /// Where the cursor left this Mac (local coordinates), used when control is yanked back.
    public private(set) var lastLocalExit: VPoint = .zero
    /// Devices the cursor may not enter (e.g. Macs handled by Universal Control).
    public var isBlocked: (String) -> Bool = { _ in false }
    /// Gaps between devices smaller than this are jumped over.
    public var gapTolerance: Double = 8

    public init(localID: String, desktop: VirtualDesktop) {
        self.localID = localID
        self.desktop = desktop
        self.active = localID
    }

    public var isRemote: Bool { active != localID }

    /// Replace the desktop. Returns `.returnLocal` if the active remote device disappeared.
    @discardableResult
    public func update(desktop: VirtualDesktop) -> Action {
        self.desktop = desktop
        guard isRemote else { return .none }
        if desktop.devices[active] == nil || isBlocked(active) {
            return forceLocal()
        }
        cursor = desktop.clamp(cursor, to: active)
        return .none
    }

    /// Mouse moved while the cursor is on this Mac. `location` is the OS cursor position
    /// (already clamped to the screens), `delta` the raw device movement.
    public func localMove(location: VPoint, delta: VPoint) -> Action {
        guard !isRemote, delta.x != 0 || delta.y != 0 else { return .none }
        let v = desktop.toVirtual(location, from: localID)
        // Only hand off when the cursor is pinned against an outer edge in the direction of travel.
        let step = VPoint(sign(delta.x), sign(delta.y))
        guard !desktop.contains(v + step, device: localID) else { return .none }
        guard case let (target, p)? = findTarget(from: v, delta: delta, excluding: [localID]) else { return .none }
        lastLocalExit = location
        active = target
        cursor = p
        return .enter(device: target, at: desktop.toLocal(p, on: target))
    }

    /// Raw mouse movement while the cursor is on a remote Mac.
    public func remoteMove(delta: VPoint) -> Action {
        guard isRemote else { return .none }
        let candidate = cursor + delta
        if desktop.contains(candidate, device: active) {
            cursor = candidate
            return .move(device: active, to: desktop.toLocal(candidate, on: active))
        }
        if case let (target, p)? = findTarget(from: cursor, delta: delta, excluding: [active]) {
            if target == localID {
                active = localID
                cursor = p
                return .returnLocal(at: desktop.toLocal(p, on: localID))
            }
            let from = active
            active = target
            cursor = p
            return .transfer(from: from, to: target, at: desktop.toLocal(p, on: target))
        }
        let clamped = desktop.clamp(candidate, to: active)
        if clamped == cursor { return .none }
        cursor = clamped
        return .move(device: active, to: desktop.toLocal(clamped, on: active))
    }

    /// Bring the cursor home immediately (hotkey, takeover, disconnect).
    public func forceLocal() -> Action {
        guard isRemote else { return .none }
        active = localID
        cursor = desktop.toVirtual(lastLocalExit, from: localID)
        return .returnLocal(at: lastLocalExit)
    }

    /// Current position on the active device in its local coordinates.
    public var activeLocalPosition: VPoint { desktop.toLocal(cursor, on: active) }

    private func findTarget(from v: VPoint, delta: VPoint, excluding: Set<String>) -> (String, VPoint)? {
        let candidate = v + delta
        func accept(_ p: VPoint) -> (String, VPoint)? {
            guard let id = desktop.device(at: p, excluding: excluding) else { return nil }
            if id != localID && isBlocked(id) { return nil }
            return (id, desktop.clamp(p, to: id))
        }
        if let hit = accept(candidate) { return hit }
        let len = delta.length
        guard len > 0 else { return nil }
        let unit = delta * (1 / len)
        var d = 1.0
        while d <= gapTolerance {
            if let hit = accept(candidate + unit * d) { return hit }
            d += 1
        }
        return nil
    }

    private func sign(_ v: Double) -> Double { v > 0 ? 1 : (v < 0 ? -1 : 0) }
}
