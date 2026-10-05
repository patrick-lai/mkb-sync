import AppKit
import Combine
import MKBCore
import Network
import ServiceManagement

/// A connected Mac in the current space.
private final class Session {
    let id: String
    let connection: PeerConnection
    var name: String
    var model: String
    var displays: [VRect]
    var status: PeerStatus

    init(hello: Hello, connection: PeerConnection) {
        id = hello.id
        self.connection = connection
        name = hello.name
        model = hello.model
        displays = hello.displays
        status = hello.status
    }
}

struct PeerRow: Identifiable, Equatable {
    enum State: Equatable { case connecting, connected, authFailed }
    let id: String
    var name: String
    var state: State
    /// Universal Control handles this pair, so MKB Sync leaves its edges alone.
    var nativePair: Bool
    var drivenByUC: Bool
    var weControlIt: Bool
    var itControlsUs: Bool
}

/// A device as drawn in the arrangement editor (virtual coordinates).
struct LayoutDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var origin: VPoint
    /// Displays relative to `origin`.
    var displays: [VRect]
    var isLocal: Bool
    var nativePair: Bool

    var size: VRect {
        VRect.union(of: displays) ?? VRect(x: 0, y: 0, width: 1440, height: 900)
    }

    var frame: VRect { size.offsetBy(dx: origin.x, dy: origin.y) }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            prefs.isEnabled = isEnabled
            isEnabled ? goOnline() : goOffline()
            refreshStatus()
        }
    }

    @Published var shareClipboard: Bool {
        didSet {
            prefs.shareClipboard = shareClipboard
            clipboard.isEnabled = shareClipboard
        }
    }

    @Published var ucMode: UCMode {
        didSet {
            prefs.ucMode = ucMode
            applyUniversalControlPolicy()
        }
    }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MKBSync: launch at login change failed: \(error)")
            }
        }
    }

    @Published private(set) var spaceName: String
    @Published private(set) var hasPassphrase: Bool
    @Published private(set) var peers: [PeerRow] = []
    @Published private(set) var spaces: [SpaceSummary] = []
    @Published private(set) var layoutDevices: [LayoutDevice] = []
    @Published private(set) var statusLine = ""
    @Published private(set) var menuBarSymbol = "cursorarrow"
    @Published private(set) var permissionsGranted = Permissions.allGranted
    @Published private(set) var universalControlSummary = ""

    let deviceID: String
    let deviceName: String
    private let prefs = Preferences()
    private let discovery = Discovery()
    private let uc: UniversalControlMonitor
    private let clipboard = ClipboardSync()
    private let engine: ControlEngine

    private var adverts: [Advertisement] = []
    private var sessions: [String: Session] = [:]
    private var pending: [ObjectIdentifier: PeerConnection] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var firstSeen: [String: Date] = [:]
    private var authFailures: Set<String> = []
    private var layout: SpaceLayout
    private var desktop = VirtualDesktop(devices: [], layout: SpaceLayout())
    private var localDisplays = DisplayInfo.current()
    private var parameters: NWParameters
    private var lastStatusSent: PeerStatus?
    private var timer: Timer?
    private var tickCount = 0
    private var online = false

    private init() {
        let p = Preferences()
        let id = p.deviceID
        deviceID = id
        deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let space = p.spaceName
        let passphrase = p.passphrase(for: space)
        spaceName = space
        hasPassphrase = !passphrase.isEmpty
        isEnabled = p.isEnabled
        shareClipboard = p.shareClipboard
        ucMode = p.ucMode
        layout = p.layout(for: space)
        parameters = Transport.parameters(psk: SpaceCrypto.preSharedKey(space: space, passphrase: passphrase))
        let monitor = UniversalControlMonitor()
        uc = monitor
        engine = ControlEngine(localID: id, uc: monitor)
    }

    // MARK: - Lifecycle

    func start() {
        clipboard.isEnabled = shareClipboard
        clipboard.onLocalChange = { [weak self] items in
            guard let self, self.shareClipboard else { return }
            self.broadcast(.clipboard(items))
        }

        engine.send = { [weak self] id, message in
            self?.sessions[id]?.connection.send(message)
        }
        engine.onStateChange = { [weak self] in
            self?.sendStatusIfChanged()
            self?.refreshStatus()
        }
        engine.onUniversalControlActivity = { [weak self] in
            self?.applyUniversalControlPolicy()
        }
        engine.router.isBlocked = { [weak self] id in
            guard let self, let session = self.sessions[id] else { return true }
            return !UniversalControlPolicy.mayEnter(local: self.uc.info, peer: session.status.uc, mode: self.ucMode)
        }

        discovery.onAdvertisementsChanged = { [weak self] ads in
            self?.advertisementsChanged(ads)
        }
        discovery.onIncomingConnection = { [weak self] connection in
            self?.accept(connection)
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displaysChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.goOffline()
            self.goOnline()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }

        if !Permissions.allGranted { Permissions.request() }
        if isEnabled { goOnline() }
        refreshStatus()
    }

    func shutdown() {
        goOffline()
    }

    private func goOnline() {
        guard !online else { return }
        online = true
        let passphrase = prefs.passphrase(for: spaceName)
        parameters = Transport.parameters(psk: SpaceCrypto.preSharedKey(space: spaceName, passphrase: passphrase))
        localDisplays = DisplayInfo.current()
        discovery.start(deviceID: deviceID, deviceName: deviceName, space: spaceName, parameters: parameters)
        if Permissions.accessibility { engine.start() }
        clipboard.start()
        rebuildDesktop()
    }

    private func goOffline() {
        guard online else { return }
        online = false
        engine.stop()
        discovery.stop()
        clipboard.stop()
        for s in sessions.values { s.connection.close() }
        for p in pending.values { p.close() }
        sessions.removeAll()
        pending.removeAll()
        lastStatusSent = nil
        authFailures.removeAll()
        rebuildDesktop()
        publishPeers()
    }

    // MARK: - Space

    func joinSpace(_ name: String, passphrase: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let wasOnline = online
        goOffline()
        prefs.spaceName = trimmed
        if let passphrase { prefs.setPassphrase(passphrase, for: trimmed) }
        spaceName = trimmed
        hasPassphrase = !prefs.passphrase(for: trimmed).isEmpty
        layout = prefs.layout(for: trimmed)
        if wasOnline || isEnabled { goOnline() }
        publishSpaces()
        refreshStatus()
    }

    func passphrase() -> String { prefs.passphrase(for: spaceName) }

    // MARK: - Discovery and connections

    private func advertisementsChanged(_ ads: [Advertisement]) {
        adverts = ads
        for ad in ads where firstSeen[ad.id] == nil { firstSeen[ad.id] = Date() }
        publishSpaces()
        connectMissing()
        publishPeers()
    }

    private var spaceTag: String { SpaceCrypto.spaceTag(spaceName) }

    private func connectMissing() {
        guard online else { return }
        let now = Date()
        for ad in adverts where ad.spaceTag == spaceTag {
            guard sessions[ad.id] == nil, !pending.values.contains(where: { $0.peerID == ad.id }) else { continue }
            // The Mac with the smaller id dials; the other side dials too if nothing arrives.
            let waitedLong = now.timeIntervalSince(firstSeen[ad.id] ?? now) > 8
            guard deviceID < ad.id || waitedLong else { continue }
            let backoff: TimeInterval = authFailures.contains(ad.id) ? 15 : 3
            if let last = lastAttempt[ad.id], now.timeIntervalSince(last) < backoff { continue }
            lastAttempt[ad.id] = now
            let pc = PeerConnection(connection: NWConnection(to: ad.endpoint, using: parameters), outgoing: true, peerID: ad.id)
            wire(pc)
            pending[ObjectIdentifier(pc)] = pc
            pc.start()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard online else { connection.cancel(); return }
        let pc = PeerConnection(connection: connection, outgoing: false)
        wire(pc)
        pending[ObjectIdentifier(pc)] = pc
        pc.start()
    }

    private func wire(_ pc: PeerConnection) {
        pc.onReady = { [weak self] pc in
            guard let self else { return }
            pc.send(.hello(self.makeHello()))
        }
        pc.onMessage = { [weak self] pc, message in
            self?.received(message, on: pc)
        }
        pc.onClose = { [weak self] pc, error in
            self?.closed(pc, error: error)
        }
    }

    private func makeHello() -> Hello {
        Hello(id: deviceID, name: deviceName, model: DisplayInfo.modelIdentifier(),
              appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
              displays: localDisplays, layout: layout, status: currentStatus())
    }

    private func received(_ message: Message, on pc: PeerConnection) {
        if case let .hello(hello) = message {
            handshake(hello, on: pc)
            return
        }
        guard let id = pc.peerID, let session = sessions[id], session.connection === pc else { return }
        switch message {
        case let .displays(d):
            session.displays = d
            rebuildDesktop()
        case let .layout(l):
            if l.supersedes(layout) { adopt(l) }
        case let .status(s):
            session.status = s
            applyUniversalControlPolicy()
            publishPeers()
        case let .enter(p):
            engine.peerEntered(id, at: p)
        case .leave:
            engine.peerLeft(id)
        case let .takeover(reason):
            engine.takeover(from: id, reason: reason)
        case let .input(e):
            engine.peerInput(id, e)
        case let .clipboard(items):
            if shareClipboard { clipboard.apply(items) }
        case .ping:
            pc.send(.pong)
        case .pong, .hello:
            break
        }
    }

    private func handshake(_ hello: Hello, on pc: PeerConnection) {
        guard hello.protocolVersion == mkbProtocolVersion, hello.id != deviceID else {
            pc.close()
            return
        }
        if let expected = pc.peerID, expected != hello.id {
            pc.close()
            return
        }
        pc.peerID = hello.id
        pending[ObjectIdentifier(pc)] = nil
        authFailures.remove(hello.id)

        if let existing = sessions[hello.id], existing.connection !== pc {
            // One connection per pair: keep the one dialled by the smaller id.
            let keepNew = pc.isOutgoing == (deviceID < hello.id)
            guard keepNew else { pc.close(); return }
            sessions[hello.id] = nil
            existing.connection.close()
        }

        sessions[hello.id] = Session(hello: hello, connection: pc)
        if hello.layout.supersedes(layout) {
            adopt(hello.layout)
        } else if layout.supersedes(hello.layout) {
            pc.send(.layout(layout))
        }
        applyUniversalControlPolicy()
        rebuildDesktop()
        publishPeers()
        refreshStatus()
    }

    private func closed(_ pc: PeerConnection, error: NWError?) {
        pending[ObjectIdentifier(pc)] = nil
        if case .some(.tls) = error, let id = pc.peerID, pc.isOutgoing {
            authFailures.insert(id)
        }
        if let id = pc.peerID, let session = sessions[id], session.connection === pc {
            sessions[id] = nil
            engine.peerDisconnected(id)
            rebuildDesktop()
            applyUniversalControlPolicy()
            refreshStatus()
        }
        publishPeers()
    }

    private func broadcast(_ message: Message) {
        for s in sessions.values { s.connection.send(message) }
    }

    // MARK: - Periodic work

    private func tick() {
        tickCount += 1
        if tickCount % 2 == 0 { uc.refresh() }

        let granted = Permissions.allGranted
        if granted != permissionsGranted { permissionsGranted = granted }
        if online && !engine.isCapturing && Permissions.accessibility { engine.start() }

        let now = Date()
        for s in sessions.values {
            if now.timeIntervalSince(s.connection.lastReceived) > 8 {
                s.connection.close()
            } else {
                s.connection.send(.ping)
            }
        }
        for p in pending.values where now.timeIntervalSince(p.created) > 10 { p.close() }

        connectMissing()
        applyUniversalControlPolicy()
        refreshStatus()
    }

    private func displaysChanged() {
        localDisplays = DisplayInfo.current()
        broadcast(.displays(localDisplays))
        rebuildDesktop()
    }

    // MARK: - Universal Control

    private func applyUniversalControlPolicy() {
        let local = uc.info
        let suspend = UniversalControlPolicy.shouldSuspend(local: local, peers: sessions.values.map(\.status.uc), mode: ucMode)
        engine.setSuspended(suspend)
        sendStatusIfChanged()

        var summary: String
        if !uc.settingEnabled {
            summary = "Universal Control is off on this Mac."
        } else if !uc.isEnabled {
            summary = "Universal Control is allowed but not running."
        } else {
            let pairs = sessions.values.filter { UniversalControlPolicy.isNativePair(local, $0.status.uc) }.map(\.name)
            summary = pairs.isEmpty
                ? "Universal Control is on; no Macs in this space share its iCloud account."
                : "Universal Control handles: " + pairs.sorted().joined(separator: ", ") + "."
        }
        if local.drivenByUC { summary += " In use right now." }
        if ucMode == .ignore { summary += " (Ignored by MKB Sync.)" }
        if summary != universalControlSummary { universalControlSummary = summary }
    }

    private func currentStatus() -> PeerStatus {
        PeerStatus(uc: uc.info, controlling: engine.controlling, controlledBy: engine.controlledBy)
    }

    private func sendStatusIfChanged() {
        let status = currentStatus()
        guard status != lastStatusSent else { return }
        lastStatusSent = status
        broadcast(.status(status))
        publishPeers()
    }

    // MARK: - Layout

    private func adopt(_ newLayout: SpaceLayout) {
        layout = newLayout
        prefs.setLayout(newLayout, for: spaceName)
        rebuildDesktop()
    }

    /// Save an edit from the arrangement editor and share it with the space.
    func moveDevice(_ id: String, to origin: VPoint) {
        let updated = desktop.pinnedLayout(base: layout, overrides: [id: origin], author: deviceID)
        adopt(updated)
        broadcast(.layout(updated))
    }

    func resetLayout() {
        let fresh = SpaceLayout(origins: [:], version: layout.version + 1, author: deviceID)
        adopt(fresh)
        broadcast(.layout(fresh))
    }

    private func rebuildDesktop() {
        var devices = [DeviceGeometry(id: deviceID, displays: localDisplays)]
        for s in sessions.values { devices.append(DeviceGeometry(id: s.id, displays: s.displays)) }
        desktop = VirtualDesktop(devices: devices, layout: layout)
        engine.updateDesktop(desktop)

        let local = uc.info
        layoutDevices = desktop.ids.map { id in
            let geometry = desktop.devices[id]!
            let bounds = geometry.bounds
            let session = sessions[id]
            return LayoutDevice(
                id: id,
                name: id == deviceID ? deviceName : (session?.name ?? "Mac"),
                origin: desktop.origins[id] ?? .zero,
                displays: geometry.displays.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) },
                isLocal: id == deviceID,
                nativePair: session.map { ucMode == .automatic && UniversalControlPolicy.isNativePair(local, $0.status.uc) } ?? false
            )
        }
    }

    // MARK: - Published state

    private func publishSpaces() {
        var entries = adverts.map { (space: $0.space, device: $0.name) }
        entries.append((space: spaceName, device: deviceName))
        spaces = SpaceSummary.group(entries)
    }

    private func publishPeers() {
        let local = uc.info
        var rows: [PeerRow] = sessions.values.map { s in
            PeerRow(id: s.id, name: s.name, state: .connected,
                    nativePair: UniversalControlPolicy.isNativePair(local, s.status.uc),
                    drivenByUC: s.status.uc.drivenByUC,
                    weControlIt: engine.controlling == s.id,
                    itControlsUs: engine.controlledBy == s.id)
        }
        for ad in adverts where ad.spaceTag == spaceTag && sessions[ad.id] == nil {
            rows.append(PeerRow(id: ad.id, name: ad.name, state: authFailures.contains(ad.id) ? .authFailed : .connecting,
                                nativePair: false, drivenByUC: false, weControlIt: false, itControlsUs: false))
        }
        rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if rows != peers { peers = rows }
    }

    private func name(of id: String?) -> String {
        guard let id else { return "" }
        return sessions[id]?.name ?? "another Mac"
    }

    private func refreshStatus() {
        let line: String
        let symbol: String
        if !isEnabled {
            line = "Off"
            symbol = "cursorarrow.slash"
        } else if !Permissions.accessibility {
            line = "Needs Accessibility permission"
            symbol = "exclamationmark.triangle"
        } else if engine.isSuspended {
            line = "Paused: Universal Control is in use"
            symbol = "pause.circle"
        } else if let c = engine.controlling {
            line = "Controlling \(name(of: c))"
            symbol = "cursorarrow.rays"
        } else if let c = engine.controlledBy {
            line = "Controlled by \(name(of: c))"
            symbol = "cursorarrow.motionlines"
        } else if sessions.isEmpty {
            line = "Looking for Macs in “\(spaceName)”…"
            symbol = "cursorarrow"
        } else {
            line = sessions.count == 1 ? "1 Mac connected" : "\(sessions.count) Macs connected"
            symbol = "cursorarrow"
        }
        if line != statusLine { statusLine = line }
        if symbol != menuBarSymbol { menuBarSymbol = symbol }
    }
}
