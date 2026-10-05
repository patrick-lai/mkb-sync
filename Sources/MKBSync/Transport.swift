import Foundation
import Network
import Security

enum Transport {
    static let serviceType = "_mkbsync._tcp"
    private static let pskIdentity = "mkbsync"

    /// TCP + TLS 1.2 with a pre-shared key derived from the space, low latency settings.
    static func parameters(psk: Data) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let keyData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }
}
