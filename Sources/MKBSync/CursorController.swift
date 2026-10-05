import AppKit
import CoreGraphics

/// Hides and parks the local cursor while input is being sent to another Mac.
final class CursorController {
    private var hidden = false
    private var detached = false

    init() {
        Self.allowBackgroundCursorControl()
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        let permitAll: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source?.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateSuppressionInterval)
        source?.setLocalEventsFilterDuringSuppressionState(permitAll, state: .eventSuppressionStateRemoteMouseDrag)
    }

    /// Freeze the cursor at `park` (hidden) while raw deltas keep arriving in the event tap.
    func detach(parkAt park: CGPoint) {
        CGWarpMouseCursorPosition(park)
        CGAssociateMouseAndMouseCursorPosition(0)
        detached = true
        if !hidden {
            CGDisplayHideCursor(CGMainDisplayID())
            hidden = true
        }
    }

    func attach(at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        if detached {
            CGAssociateMouseAndMouseCursorPosition(1)
            detached = false
        }
        if hidden {
            CGDisplayShowCursor(CGMainDisplayID())
            hidden = false
        }
    }

    /// Background apps may not hide the cursor unless this connection property is set.
    /// It is a private WindowServer property that Synergy/Barrier-style tools rely on;
    /// if it is unavailable we still work, the cursor just stays visible at the park point.
    private static func allowBackgroundCursorControl() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY) else { return }
        guard let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSym, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
