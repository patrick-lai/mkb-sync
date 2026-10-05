import Foundation
import Network

/// A Mac running MKB Sync seen over Bonjour (in any space).
struct Advertisement: Equatable {
    let id: String
    let name: String
    let space: String
    let spaceTag: String
    let endpoint: NWEndpoint
}

/// Advertises this Mac and browses for others with Bonjour. Callbacks run on main.
final class Discovery {
    var onAdvertisementsChanged: (([Advertisement]) -> Void)?
    var onIncomingConnection: ((NWConnection) -> Void)?
    var onListenerFailed: ((NWError) -> Void)?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var selfID = ""

    func start(deviceID: String, deviceName: String, space: String, parameters: NWParameters) {
        stop()
        selfID = deviceID

        do {
            let listener = try NWListener(using: parameters)
            let txt = NWTXTRecord([
                "v": "1",
                "id": deviceID,
                "n": String(deviceName.prefix(60)),
                "s": String(space.prefix(60)),
                "t": SpaceCrypto.spaceTag(space),
            ])
            listener.service = NWListener.Service(name: deviceID, type: Transport.serviceType, domain: nil, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                self?.onIncomingConnection?(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    NSLog("MKBSync: listener failed: \(error)")
                    self?.onListenerFailed?(error)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("MKBSync: could not create listener: \(error)")
        }

        let browseParams = NWParameters()
        browseParams.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Transport.serviceType, domain: nil), using: browseParams)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.publish(results)
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("MKBSync: browser failed: \(error)")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        onAdvertisementsChanged?([])
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        var byID: [String: Advertisement] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let id = txt["id"], id != selfID,
                  let tag = txt["t"] else { continue }
            if byID[id] != nil { continue } // same Mac on several interfaces
            byID[id] = Advertisement(id: id, name: txt["n"] ?? "Mac", space: txt["s"] ?? "", spaceTag: tag, endpoint: result.endpoint)
        }
        onAdvertisementsChanged?(byID.values.sorted { $0.id < $1.id })
    }
}
