import AppKit
import CoreGraphics
import MKBCore

/// Owns input capture and routing. On the Mac whose hardware is in use it decides when the
/// keyboard and mouse move to another Mac and forwards input there; on the Mac being
/// controlled it plays received input back. Everything runs on the main thread.
final class ControlEngine {
    /// Send a message to a peer.
    var send: ((String, Message) -> Void)?
    /// Control state changed (controlling / controlledBy).
    var onStateChange: (() -> Void)?
    /// Universal Control was just seen injecting input.
    var onUniversalControlActivity: (() -> Void)?

    let localID: String
    let router: CursorRouter
    private let uc: UniversalControlMonitor
    private let capture = InputCapture()
    private let injector = InputInjector()
    private let localInjector = InputInjector()
    private let cursor = CursorController()

    /// Peer this Mac is currently driving.
    private(set) var controlling: String?
    /// Peer currently driving this Mac.
    private(set) var controlledBy: String?
    /// Universal Control is in charge; no handoffs while set.
    private(set) var isSuspended = false

    /// Keys/buttons held on this Mac's own hardware while the cursor is local.
    private var physical = PressedInputs()
    /// Keys/buttons forwarded to `controlling` that still need releasing.
    private var forwarded = PressedInputs()

    /// macOS reports our own cursor warps as movement in the next motion event; this is the
    /// jump to strip from it. Without this, parking the cursor (edge → centre) reads as a
    /// big swipe back toward home and the cursor ping-pongs between Macs.
    private var pendingWarp: VPoint?
    private var warpedAt = Date.distantPast
    /// No crossings for a moment after each crossing, so one jerk can't bounce the cursor back.
    private var lastTransition = Date.distantPast
    private static let transitionCooldown: TimeInterval = 0.3
    /// If the hidden cursor drifts this far from its park point (association can be ignored
    /// for background apps), put it back.
    private static let reparkDistance: Double = 120

    init(localID: String, uc: UniversalControlMonitor) {
        self.localID = localID
        self.uc = uc
        self.router = CursorRouter(localID: localID, desktop: VirtualDesktop(devices: [], layout: SpaceLayout()))
        capture.handler = { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }
        capture.onPermissionLost = { [weak self] in
            self?.permissionLost()
        }
    }

    /// Accessibility was revoked: the tap is already gone, put the local cursor back and
    /// drop any remote session so nothing is left hidden, frozen or held down.
    private func permissionLost() {
        returnHome()
        cursor.attach(at: CGEvent(source: nil)?.location ?? DisplayInfo.parkPoint())
        if let driver = controlledBy {
            injector.releaseAll()
            controlledBy = nil
            send?(driver, .takeover(.localInput))
        }
        onStateChange?()
    }

    var isCapturing: Bool { capture.isRunning }

    @discardableResult
    func start() -> Bool { capture.start() }

    func stop() {
        returnHome()
        if controlledBy != nil {
            injector.releaseAll()
            controlledBy = nil
        }
        capture.stop()
        onStateChange?()
    }

    func updateDesktop(_ desktop: VirtualDesktop) {
        if case let .returnLocal(at) = router.update(desktop: desktop) {
            finishRemote(at: at)
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { returnHome() }
        onStateChange?()
    }

    /// Bring the keyboard and mouse back to this Mac.
    func returnHome() {
        if case let .returnLocal(at) = router.forceLocal() {
            finishRemote(at: at)
        } else if controlling != nil {
            finishRemote(at: router.lastLocalExit)
        }
    }

    // MARK: - Messages from peers

    func peerEntered(_ peer: String, at point: VPoint) {
        guard Permissions.postEvents else {
            // We could not replay anything; send the cursor straight back.
            send?(peer, .takeover(.localInput))
            return
        }
        if isSuspended || uc.isDrivingThisMac {
            send?(peer, .takeover(.universalControl))
            return
        }
        returnHome()
        if let previous = controlledBy, previous != peer {
            injector.releaseAll()
            send?(previous, .takeover(.otherController))
        }
        controlledBy = peer
        injector.moveCursor(to: point)
        onStateChange?()
    }

    func peerLeft(_ peer: String) {
        guard controlledBy == peer else { return }
        injector.releaseAll()
        controlledBy = nil
        onStateChange?()
    }

    func peerInput(_ peer: String, _ input: InputEvent) {
        guard controlledBy == peer else { return }
        injector.apply(input)
    }

    func takeover(from peer: String, reason: TakeoverReason) {
        guard controlling == peer else { return }
        NSLog("MKBSync: \(peer) took back control (\(reason))")
        returnHome()
    }

    func peerDisconnected(_ peer: String) {
        if controlling == peer { returnHome() }
        if controlledBy == peer { peerLeft(peer) }
    }

    // MARK: - Event tap

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Our own injected events pass straight through.
        if event.getIntegerValueField(.eventSourceUserData) == InputInjector.marker { return false }

        // Native Universal Control always wins.
        if uc.observe(event) {
            yieldToUniversalControl()
            return false
        }

        if type == .keyDown && isHomeHotkey(event) && controlling != nil {
            returnHome()
            return true
        }

        if controlling != nil {
            forward(type: type, event: event)
            return true
        }

        trackPhysical(type: type, event: event)

        if let driver = controlledBy, isDeliberateLocalInput(type: type, event: event) {
            // Someone is using this Mac's own keyboard or mouse: they win.
            injector.releaseAll()
            controlledBy = nil
            send?(driver, .takeover(.localInput))
            onStateChange?()
        }

        guard !isSuspended, controlledBy == nil, type == .mouseMoved, physical.buttons.isEmpty else { return false }
        let location = event.location
        router.transitionsLocked = inCooldown
        let action = router.localMove(location: VPoint(location.x, location.y), delta: motionDelta(of: event))
        if case let .enter(device, at) = action {
            beginRemote(device, at: at)
            return true
        }
        return false
    }

    private func yieldToUniversalControl() {
        var changed = false
        if let driver = controlledBy {
            injector.releaseAll()
            controlledBy = nil
            send?(driver, .takeover(.universalControl))
            changed = true
        }
        if controlling != nil {
            returnHome()
            changed = true
        }
        onUniversalControlActivity?()
        if changed { onStateChange?() }
    }

    private func beginRemote(_ device: String, at point: VPoint) {
        controlling = device
        forwarded.reset()
        // Modifiers held while crossing go with the cursor; release them here.
        let heldFlags = physical.flags & ModifierMask.deviceIndependent
        if heldFlags != 0 {
            for code in ModifierMask.keyCodes(for: heldFlags) {
                localInjector.apply(.flagsChanged(code: code, flags: 0))
            }
        }
        physical.reset()
        lastTransition = Date()
        let park = DisplayInfo.parkPoint()
        warp(to: park) { self.cursor.detach(parkAt: park) }
        send?(device, .enter(point))
        if heldFlags != 0, let code = ModifierMask.keyCodes(for: heldFlags).first {
            sendInput(.flagsChanged(code: code, flags: heldFlags))
        }
        onStateChange?()
    }

    private func finishRemote(at point: VPoint) {
        if let device = controlling {
            for e in forwarded.releaseEvents(at: router.activeLocalPosition) {
                send?(device, .input(e))
            }
            send?(device, .leave)
        }
        controlling = nil
        forwarded.reset()
        lastTransition = Date()
        let target = CGPoint(x: point.x, y: point.y)
        warp(to: target) { self.cursor.attach(at: target) }
        onStateChange?()
    }

    private func transfer(from: String, to: String, at point: VPoint) {
        for e in forwarded.releaseEvents(at: point) { send?(from, .input(e)) }
        send?(from, .leave)
        let carriedFlags = forwarded.flags & ModifierMask.deviceIndependent
        forwarded.reset()
        controlling = to
        lastTransition = Date()
        send?(to, .enter(point))
        if carriedFlags != 0, let code = ModifierMask.keyCodes(for: carriedFlags).first {
            sendInput(.flagsChanged(code: code, flags: carriedFlags))
        }
        onStateChange?()
    }

    private func sendInput(_ input: InputEvent) {
        guard let device = controlling else { return }
        forwarded.apply(input)
        send?(device, .input(input))
    }

    private func forward(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let d = motionDelta(of: event)
            reparkIfDrifted(event)
            router.transitionsLocked = inCooldown
            switch router.remoteMove(delta: d) {
            case let .move(_, to):
                sendInput(.mouseMove(position: to, delta: d))
            case let .transfer(from, to, at):
                transfer(from: from, to: to, at: at)
            case let .returnLocal(at):
                finishRemote(at: at)
            case .enter, .none:
                break
            }

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let button = UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber))
            let clicks = Int32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventClickState))
            sendInput(.mouseButton(button: button, down: down, position: router.activeLocalPosition, clickCount: clicks))

        case .scrollWheel:
            let s = ScrollEvent(
                lineDX: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                lineDY: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                pointDX: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                pointDY: Int32(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                fixedDX: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                fixedDY: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                phase: UInt8(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventScrollPhase)),
                momentumPhase: UInt8(truncatingIfNeeded: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
            )
            sendInput(.scroll(s))

        case .keyDown, .keyUp:
            sendInput(.key(
                code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                down: type == .keyDown,
                flags: event.flags.rawValue,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            ))

        case .flagsChanged:
            sendInput(.flagsChanged(
                code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags.rawValue
            ))

        default:
            if type.rawValue == InputCapture.RawType.systemDefined, let ns = NSEvent(cgEvent: event) {
                sendInput(.systemDefined(
                    subtype: ns.subtype.rawValue,
                    data1: Int64(ns.data1),
                    data2: Int64(ns.data2),
                    flags: UInt64(ns.modifierFlags.rawValue)
                ))
            }
            // Trackpad gestures are swallowed while remote but cannot be replayed.
        }
    }

    private func trackPhysical(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let button = UInt8(truncatingIfNeeded: event.getIntegerValueField(.mouseEventButtonNumber))
            physical.apply(.mouseButton(button: button, down: down, position: .zero, clickCount: 1))
        case .flagsChanged:
            physical.apply(.flagsChanged(code: 0, flags: event.flags.rawValue))
        default:
            break
        }
    }

    private func isDeliberateLocalInput(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            return true
        case .mouseMoved:
            let d = delta(of: event)
            return abs(d.x) + abs(d.y) >= 4
        default:
            return false
        }
    }

    /// ⌃⌥⌘⎋ always brings the keyboard and mouse home.
    private func isHomeHotkey(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let needed: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        return code == 53 && event.flags.contains(needed)
    }

    private var inCooldown: Bool {
        Date().timeIntervalSince(lastTransition) < Self.transitionCooldown
    }

    /// Runs a cursor warp and remembers the jump so the next motion event can be corrected.
    private func warp(to target: CGPoint, _ body: () -> Void) {
        let before = CGEvent(source: nil)?.location
        body()
        guard let before else { return }
        let jump = VPoint(target.x - before.x, target.y - before.y)
        pendingWarp = jump.length > 0.5 ? jump : nil
        warpedAt = Date()
    }

    /// Movement of a motion event with any warp we caused removed. The correction is only
    /// applied when it makes the delta smaller, so it is harmless on macOS versions that do
    /// not fold warps into the next event.
    private func motionDelta(of event: CGEvent) -> VPoint {
        let raw = delta(of: event)
        guard let jump = pendingWarp else { return raw }
        pendingWarp = nil
        guard Date().timeIntervalSince(warpedAt) < 1 else { return raw }
        let corrected = raw - jump
        return corrected.length < raw.length ? corrected : raw
    }

    private func reparkIfDrifted(_ event: CGEvent) {
        let park = DisplayInfo.parkPoint()
        let location = event.location
        let drift = VPoint(location.x - park.x, location.y - park.y)
        guard drift.length > Self.reparkDistance else { return }
        warp(to: park) { CGWarpMouseCursorPosition(park) }
    }

    private func delta(of event: CGEvent) -> VPoint {
        VPoint(event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY))
    }
}
