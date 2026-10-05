import AppKit
import MKBCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var newSpace = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.permissionsGranted { permissionBanner }
            Divider()
            spaceSection
            Divider()
            peerSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("MKB Sync").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Permissions.accessibility
                  ? "Almost there: relaunch MKB Sync so macOS applies the Accessibility permission."
                  : "MKB Sync needs Accessibility access (System Settings ▸ Privacy & Security ▸ Accessibility) to share your keyboard and mouse.",
                  systemImage: "lock.shield")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings…") {
                    Permissions.request()
                    Permissions.openAccessibilitySettings()
                }
                Button("Relaunch") { Permissions.relaunch() }
                Spacer()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }

    private var spaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Space").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(model.spaces) { space in
                        Button {
                            model.joinSpace(space.name)
                        } label: {
                            Text("\(space.name) (\(space.memberNames.count))")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if model.hasPassphrase { Image(systemName: "lock.fill") }
                        Text(model.spaceName).fontWeight(.semibold)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HStack {
                TextField("Join or create a space…", text: $newSpace)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(join)
                Button("Join", action: join)
                    .disabled(newSpace.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Every Mac in the same space on this network shares one keyboard and mouse.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var peerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Macs in this space").font(.subheadline).foregroundStyle(.secondary)
            PeerLine(name: "This Mac", detail: model.deviceName, symbol: "laptopcomputer", tint: .accentColor)
            if model.peers.isEmpty {
                Text("No other Macs yet. Install MKB Sync on another Mac and pick the same space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.peers) { peer in
                PeerLine(name: peer.name, detail: detail(for: peer), symbol: symbol(for: peer), tint: tint(for: peer))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Arrange…") { show(WindowID.layout) }
            Button("Settings…") { show(WindowID.settings) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private func join() {
        let name = newSpace.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.joinSpace(name)
        newSpace = ""
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func detail(for peer: PeerRow) -> String {
        switch peer.state {
        case .connecting: return "Connecting…"
        case .authFailed: return "Can't connect: passphrase differs"
        case .connected:
            if peer.weControlIt { return "Using this Mac's keyboard & mouse" }
            if peer.itControlsUs { return "Controlling this Mac" }
            if peer.drivenByUC { return "Universal Control in use" }
            if peer.cannotBeControlled { return "Needs Accessibility permission on that Mac" }
            if peer.nativePair && model.ucMode == .automatic { return "Handled by Universal Control" }
            return "Connected"
        }
    }

    private func symbol(for peer: PeerRow) -> String {
        switch peer.state {
        case .connecting: return "ellipsis.circle"
        case .authFailed: return "lock.trianglebadge.exclamationmark"
        case .connected: return peer.nativePair && model.ucMode == .automatic ? "link.circle" : "desktopcomputer"
        }
    }

    private func tint(for peer: PeerRow) -> Color {
        switch peer.state {
        case .connecting: return .secondary
        case .authFailed: return .red
        case .connected: return peer.weControlIt || peer.itControlsUs ? .green : .primary
        }
    }
}

private struct PeerLine: View {
    let name: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }
}
