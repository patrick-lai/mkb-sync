import Foundation
import MKBCore
import Security

/// Persistent settings. The space passphrase lives in the Keychain.
struct Preferences {
    private let defaults = UserDefaults.standard

    var deviceID: String {
        if let id = defaults.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceID")
        return id
    }

    var spaceName: String {
        get { defaults.string(forKey: "spaceName") ?? "Home" }
        nonmutating set { defaults.set(newValue, forKey: "spaceName") }
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "enabled") }
    }

    var shareClipboard: Bool {
        get { defaults.object(forKey: "shareClipboard") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "shareClipboard") }
    }

    var ucMode: UCMode {
        get { UCMode(rawValue: defaults.string(forKey: "ucMode") ?? "") ?? .automatic }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "ucMode") }
    }

    func layout(for space: String) -> SpaceLayout {
        guard let data = defaults.data(forKey: layoutKey(space)),
              let layout = try? JSONDecoder().decode(SpaceLayout.self, from: data) else { return SpaceLayout() }
        return layout
    }

    func setLayout(_ layout: SpaceLayout, for space: String) {
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: layoutKey(space))
        }
    }

    private func layoutKey(_ space: String) -> String { "layout." + SpaceCrypto.spaceTag(space) }

    // MARK: Keychain

    private static let service = "MKBSync.space-passphrase"

    func passphrase(for space: String) -> String {
        var query = baseQuery(space)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func setPassphrase(_ passphrase: String, for space: String) {
        let query = baseQuery(space)
        SecItemDelete(query as CFDictionary)
        guard !passphrase.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(passphrase.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private func baseQuery(_ space: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: SpaceCrypto.normalize(space),
        ]
    }
}
