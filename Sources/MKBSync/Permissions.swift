import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// Needed to create the event tap that captures and swallows input.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Needed to post synthesized events when this Mac is being controlled.
    static var postEvents: Bool { CGPreflightPostEventAccess() }

    static var allGranted: Bool { accessibility && postEvents }

    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !postEvents { _ = CGRequestPostEventAccess() }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openLocalNetworkSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
