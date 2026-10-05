import Foundation
import MKBCore
import Network

/// A framed, encrypted connection to another Mac in the space. All callbacks run on main.
final class PeerConnection {
    let connection: NWConnection
    let isOutgoing: Bool
    /// Device id: known up front for outgoing connections, learned from `hello` for incoming.
    var peerID: String?
    private(set) var isReady = false
    private(set) var lastReceived = Date()
    let created = Date()

    var onReady: ((PeerConnection) -> Void)?
    var onMessage: ((PeerConnection, Message) -> Void)?
    var onClose: ((PeerConnection, NWError?) -> Void)?

    private var decoder = FrameDecoder()
    private var closed = false

    init(connection: NWConnection, outgoing: Bool, peerID: String? = nil) {
        self.connection = connection
        self.isOutgoing = outgoing
        self.peerID = peerID
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.lastReceived = Date()
                self.onReady?(self)
                self.receive()
            case .waiting(let error), .failed(let error):
                // Wrong passphrase shows up here as a TLS error; let the reconnect loop retry.
                self.close(error)
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: Message) {
        guard !closed else { return }
        connection.send(content: message.encodedFrame(), completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error) }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                do {
                    for message in try self.decoder.append(data) {
                        guard !self.closed else { return }
                        self.onMessage?(self, message)
                    }
                } catch {
                    NSLog("MKBSync: dropping connection after protocol error: \(error)")
                    self.close(nil)
                    return
                }
            }
            if isComplete || error != nil {
                self.close(error)
            } else {
                self.receive()
            }
        }
    }

    func close(_ error: NWError? = nil) {
        guard !closed else { return }
        closed = true
        isReady = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(self, error)
    }
}
