import AppKit
import SwiftUI

@main
struct MKBSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Arrange Macs", id: WindowID.layout) {
            LayoutEditorView(model: model)
        }
        .defaultSize(width: 720, height: 460)

        Window("MKB Sync Settings", id: WindowID.settings) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let layout = "layout"
    static let settings = "settings"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
