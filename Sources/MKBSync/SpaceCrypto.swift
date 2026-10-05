import CryptoKit
import Foundation

/// Key material derived from a space's name and passphrase.
enum SpaceCrypto {
    static func normalize(_ space: String) -> String {
        space.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Short public tag advertised over Bonjour so peers can filter by space.
    static func spaceTag(_ space: String) -> String {
        hex(SHA256.hash(data: Data(("mkbsync-space|" + normalize(space)).utf8)), bytes: 8)
    }

    /// TLS pre-shared key. Only Macs with the same space name and passphrase can connect.
    static func preSharedKey(space: String, passphrase: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(("mkbsync-psk|" + passphrase).utf8)),
            salt: Data(("mkbsync-space|" + normalize(space)).utf8),
            info: Data("mkbsync tls psk v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Hash of the iCloud account identifier; only ever sent inside the encrypted session.
    static func accountTag(_ raw: String) -> String {
        hex(SHA256.hash(data: Data(("mkbsync-acct|" + raw).utf8)), bytes: 12)
    }

    private static func hex<D: Sequence>(_ digest: D, bytes: Int) -> String where D.Element == UInt8 {
        digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
