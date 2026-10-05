import AppKit
import CoreGraphics
import MKBCore

/// Posts forwarded input into this Mac's event stream.
final class InputInjector {
    /// Stamped into `eventSourceUserData` so our own event tap can recognise injected events.
    static let marker: Int64 = 0x4D4B_4253_594E

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var position = CGPoint.zero
    private var pressed = PressedInputs()

    init() {
        source?.localEventsSuppressionInterval = 0
    }

    var hasPressedInputs: Bool { !pressed.isEmpty }

    /// Places the cursor without any button state.
    func moveCursor(to p: VPoint) {
        position = CGPoint(x: p.x, y: p.y)
        apply(.mouseMove(position: p, delta: .zero))
    }

    func apply(_ input: InputEvent) {
        pressed.apply(input)
        switch input {
        case let .mouseMove(p, d):
            position = CGPoint(x: p.x, y: p.y)
            let (type, button) = moveType()
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(d.x.rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(d.y.rounded()))
            e.flags = CGEventFlags(rawValue: pressed.flags)
            post(e)

        case let .mouseButton(b, down, p, clicks):
            position = CGPoint(x: p.x, y: p.y)
            let type: CGEventType
            switch b {
            case 0: type = down ? .leftMouseDown : .leftMouseUp
            case 1: type = down ? .rightMouseDown : .rightMouseUp
            default: type = down ? .otherMouseDown : .otherMouseUp
            }
            let button = CGMouseButton(rawValue: UInt32(b)) ?? .center
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b))
            e.flags = CGEventFlags(rawValue: pressed.flags)
            post(e)

        case let .scroll(s):
            guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: s.pointDY, wheel2: s.pointDX, wheel3: 0) else { return }
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: s.continuous ? 1 : 0)
            e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(s.lineDY))
            e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(s.lineDX))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(s.pointDY))
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(s.pointDX))
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.fixedDY)
            e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.fixedDX)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(s.phase))
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(s.momentumPhase))
            e.location = position
            e.flags = CGEventFlags(rawValue: pressed.flags)
            post(e)

        case let .key(code, down, flags, isRepeat):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { return }
            e.flags = CGEventFlags(rawValue: flags)
            e.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
            post(e)

        case let .flagsChanged(code, flags):
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = CGEventFlags(rawValue: flags)
            post(e)

        case let .systemDefined(subtype, d1, d2, flags):
            let ns = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: flags)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: subtype, data1: Int(truncatingIfNeeded: d1), data2: Int(truncatingIfNeeded: d2)
            )
            if let e = ns?.cgEvent { post(e) }
        }
    }

    /// Releases every key and button we are holding down on this Mac.
    func releaseAll() {
        let events = pressed.releaseEvents(at: VPoint(position.x, position.y))
        for e in events { apply(e) }
        pressed.reset()
    }

    private func moveType() -> (CGEventType, CGMouseButton) {
        if pressed.buttons.contains(0) { return (.leftMouseDragged, .left) }
        if pressed.buttons.contains(1) { return (.rightMouseDragged, .right) }
        if let other = pressed.buttons.min() { return (.otherMouseDragged, CGMouseButton(rawValue: UInt32(other)) ?? .center) }
        return (.mouseMoved, .left)
    }

    private func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e.post(tap: .cghidEventTap)
    }
}
