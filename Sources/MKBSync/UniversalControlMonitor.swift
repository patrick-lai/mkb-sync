import AppKit
import Darwin
import MKBCore

/// Detects Apple's Universal Control so MKB Sync can stay out of its way.
///
/// Signals used:
/// * Settings: `com.apple.universalcontrol` → `Disable` (System Settings ▸ Displays ▸ Advanced).
/// * The `UniversalControl` agent process must be running for the feature to be live.
/// * iCloud account (from `MobileMeAccounts`): Universal Control only pairs Macs on the same
///   Apple ID, so two Macs with matching account tags are a "native pair".
/// * Live use: events whose source PID is the Universal Control agent mean it is driving this Mac.
final class UniversalControlMonitor {
    static let bundleIdentifier = "com.apple.universalcontrol"
    static let processName = "UniversalControl"
    /// How long after the last Universal Control event we still consider it in use.
    static let activeWindow: TimeInterval = 2.5

    private(set) var pids: Set<pid_t> = []
    private(set) var settingEnabled = true
    private(set) var accountTag: String?
    private var lastUCEvent: Date?

    init() { refresh() }

    /// Re-read settings and the agent process list (cheap; called every ~2s).
    func refresh() {
        let defaults = UserDefaults(suiteName: Self.bundleIdentifier)
        settingEnabled = !(defaults?.bool(forKey: "Disable") ?? false)
        pids = Self.findAgentPIDs()
        if accountTag == nil, let raw = Self.iCloudAccountIdentifier() {
            accountTag = SpaceCrypto.accountTag(raw)
        }
    }

    var isEnabled: Bool { settingEnabled && !pids.isEmpty }

    var isDrivingThisMac: Bool {
        guard let last = lastUCEvent else { return false }
        return Date().timeIntervalSince(last) < Self.activeWindow
    }

    var info: UCInfo {
        UCInfo(enabled: isEnabled, accountTag: accountTag, drivenByUC: isDrivingThisMac)
    }

    /// Call from the event tap. Returns true if the event was injected by Universal Control.
    func observe(_ event: CGEvent) -> Bool {
        guard !pids.isEmpty else { return false }
        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid != 0, pids.contains(pid) else { return false }
        lastUCEvent = Date()
        return true
    }

    private static func findAgentPIDs() -> Set<pid_t> {
        var found = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map(\.processIdentifier))
        if found.isEmpty {
            // The agent is not always registered as an NSRunningApplication; scan processes.
            let count = proc_listallpids(nil, 0)
            if count > 0 {
                var list = [pid_t](repeating: 0, count: Int(count) + 64)
                let n = proc_listallpids(&list, Int32(list.count * MemoryLayout<pid_t>.size))
                for pid in list.prefix(Int(max(0, n))) where pid > 0 {
                    var name = [CChar](repeating: 0, count: 256)
                    if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == processName {
                        found.insert(pid)
                    }
                }
            }
        }
        return found
    }

    private static func iCloudAccountIdentifier() -> String? {
        var accounts = UserDefaults(suiteName: "MobileMeAccounts")?.array(forKey: "Accounts") as? [[String: Any]]
        if accounts == nil {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/MobileMeAccounts.plist")
            if let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                accounts = dict["Accounts"] as? [[String: Any]]
            }
        }
        guard let primary = accounts?.first else { return nil }
        return (primary["AccountDSID"] as? String) ?? (primary["AccountID"] as? String)
    }
}
