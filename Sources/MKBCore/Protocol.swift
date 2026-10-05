import Foundation

public let mkbProtocolVersion = 1

/// Scroll wheel / trackpad scroll, carrying the fields macOS needs for smooth scrolling.
public struct ScrollEvent: Equatable, Sendable {
    public var lineDX: Int32
    public var lineDY: Int32
    public var pointDX: Int32
    public var pointDY: Int32
    public var fixedDX: Double
    public var fixedDY: Double
    public var continuous: Bool
    public var phase: UInt8
    public var momentumPhase: UInt8

    public init(lineDX: Int32 = 0, lineDY: Int32 = 0, pointDX: Int32 = 0, pointDY: Int32 = 0,
                fixedDX: Double = 0, fixedDY: Double = 0, continuous: Bool = false,
                phase: UInt8 = 0, momentumPhase: UInt8 = 0) {
        self.lineDX = lineDX
        self.lineDY = lineDY
        self.pointDX = pointDX
        self.pointDY = pointDY
        self.fixedDX = fixedDX
        self.fixedDY = fixedDY
        self.continuous = continuous
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

/// An input event forwarded from the controlling Mac to the Mac under the cursor.
/// Positions are in the receiving Mac's global display coordinates.
public enum InputEvent: Equatable, Sendable {
    case mouseMove(position: VPoint, delta: VPoint)
    case mouseButton(button: UInt8, down: Bool, position: VPoint, clickCount: Int32)
    case scroll(ScrollEvent)
    case key(code: UInt16, down: Bool, flags: UInt64, isRepeat: Bool)
    case flagsChanged(code: UInt16, flags: UInt64)
    /// NX_SYSDEFINED events: media keys, brightness, volume.
    case systemDefined(subtype: Int16, data1: Int64, data2: Int64, flags: UInt64)
}

/// Universal Control facts a Mac shares with its space.
public struct UCInfo: Codable, Equatable, Sendable {
    /// Universal Control is switched on and its agent is running.
    public var enabled: Bool
    /// Salted hash of the iCloud account; equal tags mean Universal Control can pair the two Macs.
    public var accountTag: String?
    /// Universal Control is currently injecting input into this Mac.
    public var drivenByUC: Bool

    public init(enabled: Bool = false, accountTag: String? = nil, drivenByUC: Bool = false) {
        self.enabled = enabled
        self.accountTag = accountTag
        self.drivenByUC = drivenByUC
    }
}

public struct PeerStatus: Codable, Equatable, Sendable {
    public var uc: UCInfo
    /// Device this Mac is currently sending its keyboard and mouse to.
    public var controlling: String?
    /// Device whose keyboard and mouse currently drive this Mac.
    public var controlledBy: String?

    public init(uc: UCInfo = UCInfo(), controlling: String? = nil, controlledBy: String? = nil) {
        self.uc = uc
        self.controlling = controlling
        self.controlledBy = controlledBy
    }
}

public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var id: String
    public var name: String
    public var model: String
    public var appVersion: String
    public var displays: [VRect]
    public var layout: SpaceLayout
    public var status: PeerStatus

    public init(protocolVersion: Int = mkbProtocolVersion, id: String, name: String, model: String = "",
                appVersion: String = "", displays: [VRect], layout: SpaceLayout, status: PeerStatus) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.name = name
        self.model = model
        self.appVersion = appVersion
        self.displays = displays
        self.layout = layout
        self.status = status
    }
}

public struct ClipboardItem: Equatable, Sendable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public enum TakeoverReason: UInt8, Sendable {
    /// Someone used this Mac's own keyboard or mouse.
    case localInput = 1
    /// Universal Control started driving this Mac; the native feature wins.
    case universalControl = 2
    /// Another Mac in the space took control.
    case otherController = 3
}

public enum Message: Equatable, Sendable {
    case hello(Hello)
    case displays([VRect])
    case layout(SpaceLayout)
    case status(PeerStatus)
    /// Sender is taking control of the receiver; cursor appears at the given local point.
    case enter(VPoint)
    /// Sender releases control of the receiver.
    case leave
    /// Receiver must stop controlling the sender.
    case takeover(TakeoverReason)
    case input(InputEvent)
    case clipboard([ClipboardItem])
    case ping
    case pong
}

// MARK: - Encoding

private enum Tag: UInt8 {
    case hello = 1, displays, layout, status, enter, leave, takeover, input, clipboard, ping, pong
}

private enum InputTag: UInt8 {
    case mouseMove = 1, mouseButton, scroll, key, flagsChanged, systemDefined
}

extension Message {
    /// Length-prefixed frame: u32 length, then u8 type tag and payload.
    public func encodedFrame() -> Data {
        var body = BinaryWriter()
        switch self {
        case .hello(let h): body.u8(Tag.hello.rawValue); body.raw(json(h))
        case .displays(let d): body.u8(Tag.displays.rawValue); body.raw(json(d))
        case .layout(let l): body.u8(Tag.layout.rawValue); body.raw(json(l))
        case .status(let s): body.u8(Tag.status.rawValue); body.raw(json(s))
        case .enter(let p): body.u8(Tag.enter.rawValue); body.f64(p.x); body.f64(p.y)
        case .leave: body.u8(Tag.leave.rawValue)
        case .takeover(let r): body.u8(Tag.takeover.rawValue); body.u8(r.rawValue)
        case .input(let e): body.u8(Tag.input.rawValue); encode(e, into: &body)
        case .clipboard(let items):
            body.u8(Tag.clipboard.rawValue)
            body.u32(UInt32(items.count))
            for item in items {
                body.string(item.type)
                body.blob(item.data)
            }
        case .ping: body.u8(Tag.ping.rawValue)
        case .pong: body.u8(Tag.pong.rawValue)
        }
        var frame = BinaryWriter()
        frame.u32(UInt32(body.bytes.count))
        frame.raw(body.bytes)
        return Data(frame.bytes)
    }

    /// Decode one frame body (without the length prefix).
    public static func decode(body: ArraySlice<UInt8>) throws -> Message {
        var r = BinaryReader(body)
        let raw = try r.u8()
        guard let tag = Tag(rawValue: raw) else { throw CodecError.unknownType(raw) }
        switch tag {
        case .hello: return .hello(try unjson(r.remaining))
        case .displays: return .displays(try unjson(r.remaining))
        case .layout: return .layout(try unjson(r.remaining))
        case .status: return .status(try unjson(r.remaining))
        case .enter: return .enter(VPoint(try r.f64(), try r.f64()))
        case .leave: return .leave
        case .takeover:
            let v = try r.u8()
            guard let reason = TakeoverReason(rawValue: v) else { throw CodecError.invalid("takeover reason \(v)") }
            return .takeover(reason)
        case .input: return .input(try decodeInput(&r))
        case .clipboard:
            let n = Int(try r.u32())
            guard n <= 64 else { throw CodecError.invalid("too many clipboard items") }
            var items: [ClipboardItem] = []
            for _ in 0..<n {
                let type = try r.string()
                items.append(ClipboardItem(type: type, data: try r.blob()))
            }
            return .clipboard(items)
        case .ping: return .ping
        case .pong: return .pong
        }
    }
}

private func json<T: Encodable>(_ v: T) -> [UInt8] {
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    return Array((try? enc.encode(v)) ?? Data())
}

private func unjson<T: Decodable>(_ bytes: ArraySlice<UInt8>) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: Data(bytes))
    } catch {
        throw CodecError.invalid("json: \(error)")
    }
}

private func encode(_ e: InputEvent, into w: inout BinaryWriter) {
    switch e {
    case let .mouseMove(p, d):
        w.u8(InputTag.mouseMove.rawValue)
        w.f64(p.x); w.f64(p.y); w.f64(d.x); w.f64(d.y)
    case let .mouseButton(button, down, p, clicks):
        w.u8(InputTag.mouseButton.rawValue)
        w.u8(button); w.bool(down); w.f64(p.x); w.f64(p.y); w.i32(clicks)
    case let .scroll(s):
        w.u8(InputTag.scroll.rawValue)
        w.i32(s.lineDX); w.i32(s.lineDY); w.i32(s.pointDX); w.i32(s.pointDY)
        w.f64(s.fixedDX); w.f64(s.fixedDY); w.bool(s.continuous); w.u8(s.phase); w.u8(s.momentumPhase)
    case let .key(code, down, flags, isRepeat):
        w.u8(InputTag.key.rawValue)
        w.u16(code); w.bool(down); w.u64(flags); w.bool(isRepeat)
    case let .flagsChanged(code, flags):
        w.u8(InputTag.flagsChanged.rawValue)
        w.u16(code); w.u64(flags)
    case let .systemDefined(subtype, d1, d2, flags):
        w.u8(InputTag.systemDefined.rawValue)
        w.i16(subtype); w.i64(d1); w.i64(d2); w.u64(flags)
    }
}

private func decodeInput(_ r: inout BinaryReader) throws -> InputEvent {
    let raw = try r.u8()
    guard let tag = InputTag(rawValue: raw) else { throw CodecError.unknownType(raw) }
    switch tag {
    case .mouseMove:
        let p = VPoint(try r.f64(), try r.f64())
        return .mouseMove(position: p, delta: VPoint(try r.f64(), try r.f64()))
    case .mouseButton:
        let b = try r.u8(), down = try r.bool()
        let p = VPoint(try r.f64(), try r.f64())
        return .mouseButton(button: b, down: down, position: p, clickCount: try r.i32())
    case .scroll:
        let s = ScrollEvent(lineDX: try r.i32(), lineDY: try r.i32(), pointDX: try r.i32(), pointDY: try r.i32(),
                            fixedDX: try r.f64(), fixedDY: try r.f64(), continuous: try r.bool(),
                            phase: try r.u8(), momentumPhase: try r.u8())
        return .scroll(s)
    case .key:
        return .key(code: try r.u16(), down: try r.bool(), flags: try r.u64(), isRepeat: try r.bool())
    case .flagsChanged:
        return .flagsChanged(code: try r.u16(), flags: try r.u64())
    case .systemDefined:
        return .systemDefined(subtype: try r.i16(), data1: try r.i64(), data2: try r.i64(), flags: try r.u64())
    }
}

/// Reassembles frames from a byte stream.
public struct FrameDecoder {
    public static let maxFrameSize = 48 << 20

    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ data: Data) throws -> [Message] {
        buffer.append(contentsOf: data)
        var out: [Message] = []
        while buffer.count - start >= 4 {
            let len = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard len > 0, len <= Self.maxFrameSize else { throw CodecError.frameTooLarge(len) }
            guard buffer.count - start - 4 >= len else { break }
            out.append(try Message.decode(body: buffer[(start + 4)..<(start + 4 + len)]))
            start += 4 + len
        }
        if start > 0 && (start == buffer.count || start > 1 << 16) {
            buffer.removeFirst(start)
            start = 0
        }
        return out
    }
}
