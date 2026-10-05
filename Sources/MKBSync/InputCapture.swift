import AppKit
import CoreGraphics

/// Session-level event tap. The handler returns true to swallow an event.
/// Requires Accessibility permission. Runs on the main run loop.
final class InputCapture {
    var handler: ((CGEventType, CGEvent) -> Bool)?
    fileprivate(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Raw NX event type numbers that have no CGEventType case.
    enum RawType {
        static let systemDefined: UInt32 = 14
        static let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31, 32, 34]
    }

    static let mask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        let raw = types.map(\.rawValue) + [RawType.systemDefined] + RawType.gestureTypes
        return raw.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
    }()

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.mask,
            callback: inputCaptureCallback,
            userInfo: info
        ) else {
            NSLog("MKBSync: could not create event tap (Accessibility permission missing?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private func inputCaptureCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        capture.reenable()
        return Unmanaged.passUnretained(event)
    }
    let swallow = capture.handler?(type, event) ?? false
    return swallow ? nil : Unmanaged.passUnretained(event)
}
