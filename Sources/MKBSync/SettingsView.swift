import MKBCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var space = ""
    @State private var passphrase = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Space") {
                TextField("Space name", text: $space)
                SecureField("Passphrase (optional)", text: $passphrase)
                Text("Macs connect only when both the space name and the passphrase match. Traffic is encrypted with TLS using a key derived from both. Without a passphrase, anyone on your network who knows the space name can join.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Apply") { model.joinSpace(space, passphrase: passphrase) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(space.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Universal Control") {
                Picker("When Universal Control is available", selection: $model.ucMode) {
                    Text("Let Universal Control win (recommended)").tag(UCMode.automatic)
                    Text("Ignore Universal Control").tag(UCMode.ignore)
                }
                Text(model.universalControlSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("MKB Sync never takes an edge between two Macs that Universal Control can join itself (Universal Control on, same iCloud account). It also pauses whenever Universal Control is driving this Mac or one paired with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Share clipboard with Macs in this space", isOn: $model.shareClipboard)
                Toggle("Open at login", isOn: $model.launchAtLogin)
                LabeledContent("This Mac", value: model.deviceName)
                LabeledContent("Bring keyboard & mouse home", value: "⌃⌥⌘⎋")
            }

            Section("Permissions") {
                LabeledContent("Accessibility", value: Permissions.accessibility ? "Granted" : "Not granted")
                LabeledContent("Post events", value: Permissions.postEvents ? "Granted" : "Not granted")
                HStack {
                    Button("Open Accessibility Settings") {
                        Permissions.request()
                        Permissions.openAccessibilitySettings()
                    }
                    Button("Local Network Settings") { Permissions.openLocalNetworkSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            space = model.spaceName
            passphrase = model.passphrase()
        }
        .onChange(of: model.spaceName) { newValue in
            space = newValue
            passphrase = model.passphrase()
        }
    }
}
