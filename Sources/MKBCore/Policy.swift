import Foundation

/// How MKB Sync behaves next to Apple's Universal Control.
public enum UCMode: String, Codable, CaseIterable, Sendable {
    /// Universal Control wins: never cross between Macs it can pair, and pause while it is in use.
    case automatic
    /// Ignore Universal Control entirely.
    case ignore
}

public enum UniversalControlPolicy {
    /// Two Macs that Universal Control itself can connect (both enabled, same iCloud account).
    /// MKB Sync leaves the edges between such Macs to Universal Control.
    public static func isNativePair(_ a: UCInfo, _ b: UCInfo) -> Bool {
        guard a.enabled, b.enabled, let ta = a.accountTag, let tb = b.accountTag else { return false }
        return ta == tb
    }

    /// Whether MKB Sync should stop forwarding input from this Mac right now.
    /// True while Universal Control drives this Mac, or drives a Mac it could only be
    /// driving from here (a native pair of ours), because then this Mac is the UC source.
    public static func shouldSuspend(local: UCInfo, peers: [UCInfo], mode: UCMode) -> Bool {
        guard mode == .automatic else { return false }
        if local.drivenByUC { return true }
        return peers.contains { $0.drivenByUC && isNativePair(local, $0) }
    }

    /// Whether the cursor may cross from this Mac into `peer`.
    public static func mayEnter(local: UCInfo, peer: UCInfo, mode: UCMode) -> Bool {
        guard mode == .automatic else { return true }
        return !isNativePair(local, peer) && !peer.drivenByUC
    }
}

/// Tracks which keys and buttons are held so they can be released when control moves away.
public struct PressedInputs: Equatable {
    public private(set) var keys: Set<UInt16> = []
    public private(set) var buttons: Set<UInt8> = []
    public private(set) var flags: UInt64 = 0

    public init() {}

    public mutating func apply(_ e: InputEvent) {
        switch e {
        case let .key(code, down, flags, _):
            if down { keys.insert(code) } else { keys.remove(code) }
            self.flags = flags
        case let .mouseButton(b, down, _, _):
            if down { buttons.insert(b) } else { buttons.remove(b) }
        case let .flagsChanged(_, flags):
            self.flags = flags
        default:
            break
        }
    }

    public var isEmpty: Bool { keys.isEmpty && buttons.isEmpty && flags & ModifierMask.deviceIndependent == 0 }

    /// Events that release everything currently held, ending with modifiers cleared.
    public func releaseEvents(at position: VPoint) -> [InputEvent] {
        var out: [InputEvent] = []
        for b in buttons.sorted() {
            out.append(.mouseButton(button: b, down: false, position: position, clickCount: 1))
        }
        for k in keys.sorted() {
            out.append(.key(code: k, down: false, flags: 0, isRepeat: false))
        }
        if flags & ModifierMask.deviceIndependent != 0 {
            for code in ModifierMask.keyCodes(for: flags) {
                out.append(.flagsChanged(code: code, flags: 0))
            }
        }
        return out
    }

    public mutating func reset() { self = PressedInputs() }
}

/// CGEventFlags bits, duplicated here so core logic stays platform independent.
public enum ModifierMask {
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let function: UInt64 = 0x0080_0000
    public static let deviceIndependent: UInt64 = shift | control | option | command | function

    /// Left-hand key codes for the modifiers set in `flags`.
    public static func keyCodes(for flags: UInt64) -> [UInt16] {
        var codes: [UInt16] = []
        if flags & shift != 0 { codes.append(0x38) }
        if flags & control != 0 { codes.append(0x3B) }
        if flags & option != 0 { codes.append(0x3A) }
        if flags & command != 0 { codes.append(0x37) }
        if flags & function != 0 { codes.append(0x3F) }
        return codes
    }
}

/// A space as seen on the network, for the space picker.
public struct SpaceSummary: Equatable, Identifiable, Sendable {
    public var name: String
    public var memberNames: [String]
    public var id: String { name.lowercased() }

    public init(name: String, memberNames: [String]) {
        self.name = name
        self.memberNames = memberNames
    }

    /// Groups advertised (space, device name) pairs case-insensitively.
    public static func group(_ adverts: [(space: String, device: String)]) -> [SpaceSummary] {
        var byKey: [String: SpaceSummary] = [:]
        for a in adverts {
            let trimmed = a.space.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            var s = byKey[key] ?? SpaceSummary(name: trimmed, memberNames: [])
            if !s.memberNames.contains(a.device) { s.memberNames.append(a.device) }
            byKey[key] = s
        }
        return byKey.values
            .map { SpaceSummary(name: $0.name, memberNames: $0.memberNames.sorted()) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}
