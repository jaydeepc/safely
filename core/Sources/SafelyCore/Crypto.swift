import CryptoKit
import Foundation

public enum SafelyCryptoError: Error {
    case badEnvelope
    case badKey
    case authenticationFailed
}

/// A long-lived P-256 key agreement identity. The phone has one, every paired browser has one.
public struct Identity {
    public let privateKey: P256.KeyAgreement.PrivateKey

    public init() { privateKey = P256.KeyAgreement.PrivateKey() }

    public init(rawRepresentation: Data) throws {
        privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    /// Uncompressed X9.63 point (65 bytes) — the same bytes WebCrypto exports as "raw".
    public var publicKey: Data { privateKey.publicKey.x963Representation }
}

public enum SafelyCrypto {
    static let sessionSalt = Data("safely/v1/session".utf8)
    static let commitLabel = Data("safely/v1/commit".utf8)
    static let sasLabel = Data("safely/v1/sas".utf8)

    /// A pairing is addressed by the first 8 bytes of SHA-256(browser public key).
    public static func keyId(forBrowserPublicKey pub: Data) -> Data {
        Data(SHA256.hash(data: pub).prefix(8))
    }

    /// Static-static ECDH → HKDF-SHA256 → AES-256 key, bound to both public keys.
    public static func sessionKey(identity: Identity, peerPublicKey: Data, browserPublicKey: Data, phonePublicKey: Data) throws -> SymmetricKey {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey) else {
            throw SafelyCryptoError.badKey
        }
        let shared = try identity.privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: sessionSalt,
            sharedInfo: browserPublicKey + phonePublicKey,
            outputByteCount: 32
        )
    }

    /// The browser commits to its key before seeing the phone's key, so a man in the middle
    /// cannot grind keys until the 6 digit codes collide.
    public static func commitment(browserPublicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: commitLabel + browserPublicKey + nonce))
    }

    /// Short authentication string both screens show during pairing.
    public static func sas(browserPublicKey: Data, phonePublicKey: Data, nonce: Data) -> String {
        let digest = SHA256.hash(data: sasLabel + browserPublicKey + phonePublicKey + nonce)
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey, keyId: Data) throws -> Data {
        var header = Data([EnvelopeType.sealed.rawValue])
        header.append(keyId)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: header)
        guard let combined = box.combined else { throw SafelyCryptoError.badEnvelope }
        return header + combined
    }

    public static func keyId(ofSealed envelope: Data) -> Data? {
        guard envelope.count > 9 + 28, envelope.first == EnvelopeType.sealed.rawValue else { return nil }
        return Data(envelope.dropFirst().prefix(8))
    }

    public static func open(_ envelope: Data, key: SymmetricKey) throws -> Data {
        guard envelope.count > 9 + 28, envelope.first == EnvelopeType.sealed.rawValue else {
            throw SafelyCryptoError.badEnvelope
        }
        let header = Data(envelope.prefix(9))
        do {
            let box = try AES.GCM.SealedBox(combined: Data(envelope.dropFirst(9)))
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw SafelyCryptoError.authenticationFailed
        }
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
