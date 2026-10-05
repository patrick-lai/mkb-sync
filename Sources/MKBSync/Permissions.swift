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

    /// macOS only applies a new Accessibility grant to a freshly launched process.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
