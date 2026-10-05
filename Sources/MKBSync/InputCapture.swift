import AppKit
import ApplicationServices
import CoreGraphics

/// Session-level event tap. The handler returns true to swallow an event.
/// Requires Accessibility permission. Runs on the main run loop.
///
/// An active (filtering) tap must never outlive the Accessibility permission: if the
/// permission is revoked while the tap is installed, macOS keeps the tap in the event path
/// but stops letting it pass clicks and keystrokes through, so the whole Mac loses its
/// keyboard and mouse buttons. The tap therefore watches the permission and removes itself
/// the moment it is revoked.
final class InputCapture {
    var handler: ((CGEventType, CGEvent) -> Bool)?
    /// Called (on main) after the tap removed itself because Accessibility was revoked.
    var onPermissionLost: (() -> Void)?
    fileprivate(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var accessibilityObserver: NSObjectProtocol?

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
        guard AXIsProcessTrusted() else { return false }
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
        startWatchdog()
        return true
    }

    func stop() {
        stopWatchdog()
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
        guard let tap else { return }
        // macOS also disables taps when trust is withdrawn; never fight that.
        guard AXIsProcessTrusted() else {
            permissionLost()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Takes the tap out of the event path right away (safe to call from inside the
    /// callback); the mach port itself is torn down on the next run loop pass.
    fileprivate func permissionLost() {
        guard let tap else { return }
        NSLog("MKBSync: Accessibility permission revoked; removing event tap")
        CGEvent.tapEnable(tap: tap, enable: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tap != nil else { return }
            self.stop()
            self.onPermissionLost?()
        }
    }

    fileprivate func checkPermission() {
        if tap != nil && !AXIsProcessTrusted() { permissionLost() }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkPermission() }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        // Posted when any app's Accessibility permission changes; the new value can lag
        // slightly behind the notification, so re-check a few times.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            for delay in [0.0, 0.1, 0.3, 0.6, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.checkPermission() }
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
    }
}

private func inputCaptureCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let capture = Unmanaged<InputCapture>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        capture.reenable()
        return Unmanaged.passUnretained(event)
    }
    // Belt and braces: verify trust on discrete presses (cheap, and these are exactly the
    // events that would be lost if the permission were gone).
    switch type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown:
        if !AXIsProcessTrusted() {
            capture.permissionLost()
            return Unmanaged.passUnretained(event)
        }
    default:
        break
    }
    let swallow = capture.handler?(type, event) ?? false
    return swallow ? nil : Unmanaged.passUnretained(event)
}
