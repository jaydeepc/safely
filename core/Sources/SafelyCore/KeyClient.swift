import CryptoKit
import Foundation

/// What a device remembers about its pairing with the Shhlock Key.
public struct KeyPairing: Codable, Equatable {
    public var keyId: Data          // names this device to the key
    public var sessionKey: Data     // AES-256, static-static ECDH with the key
    public var secret: Data         // unwraps the vault key on the key; never leaves this device otherwise
    public var keyPublicKey: Data
    public var keyName: String
    public var pairedAt: Date
    public var lastCtr: Int64
}

public enum KeyPairingEvent: Equatable {
    case waitingForButton                  // phone: press the button on the key
    case compare(code: String)             // computer: the phone shows the same code
    case paired(keyName: String, vaultCount: Int)
    case failed(String)
}

/// A request from the key to the phone: a computer wants to pair, does its code match?
public struct ApprovalRequest: Identifiable, Equatable {
    public let id: String
    public let code: String
    public let name: String

    public init(id: String, code: String, name: String) {
        self.id = id
        self.code = code
        self.name = name
    }
}

public enum KeyClientError: Error {
    case notPaired, notConnected, timeout, locked, refused(String)
}

/// Client side of protocol v2: pairing with the key, sealed requests, unlocking the vault.
/// Used by the phone app (role .phone), the Mac menu-bar app (role .computer) and the tests.
public final class KeyClient {
    public enum Role: String {
        case phone, computer
    }

    public let role: Role
    public let name: String
    public var send: ((Data) -> Bool)?
    public var onPairingEvent: ((KeyPairingEvent) -> Void)?
    public var onApprovalRequest: ((ApprovalRequest) -> Void)?
    public var onUnpaired: (() -> Void)?
    public var onLog: ((String) -> Void)?

    public private(set) var pairing: KeyPairing? {
        didSet { persist(pairing) }
    }
    private let persist: (KeyPairing?) -> Void
    private let counter = MonotonicCounter()
    private var pending: [String: (Message) -> Void] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    private let queue: DispatchQueue

    private struct Pending {
        var identity: Identity
        var nonce: Data
        var secret: Data
        var keyId: Data
        var sessionKey: SymmetricKey?
        var keyPublicKey: Data?
        var keyName = "Shhlock Key"
        var code: String?
        var userConfirmed = false
        var keyConfirmed = false
        var vaultCount = 0
        var timeout: DispatchWorkItem?
    }
    private var pairingInProgress: Pending?

    public init(role: Role, name: String, stored: KeyPairing?, persist: @escaping (KeyPairing?) -> Void, queue: DispatchQueue = .main) {
        self.role = role
        self.name = name
        self.pairing = stored
        self.persist = persist
        self.queue = queue
    }

    public var isPaired: Bool { pairing != nil }

    // MARK: - Pairing

    public func startPairing() {
        cancelPairing(tellKey: false)
        let identity = Identity()
        let nonce = SafelyCrypto.randomBytes(16)
        var p = Pending(identity: identity, nonce: nonce, secret: SafelyCrypto.randomBytes(32),
                        keyId: SafelyCrypto.keyId(forBrowserPublicKey: identity.publicKey))
        let timeout = DispatchWorkItem { [weak self] in self?.fail("The key did not answer. Is it powered and nearby?") }
        p.timeout = timeout
        queue.asyncAfter(deadline: .now() + 90, execute: timeout)
        pairingInProgress = p

        var commit = Message(t: Message.Kind.pairCommit)
        commit.commit = SafelyCrypto.commitment(browserPublicKey: identity.publicKey, nonce: nonce).base64EncodedString()
        commit.name = name
        commit.role = role.rawValue
        if !(send?(commit.plainEnvelope()) ?? false) { fail("The key is not connected.") }
    }

    /// Computer role: the person confirmed that the phone shows the same code.
    public func confirmPairing() {
        pairingInProgress?.userConfirmed = true
        maybeFinishPairing()
    }

    public func cancelPairing(tellKey: Bool = true) {
        guard pairingInProgress != nil else { return }
        pairingInProgress?.timeout?.cancel()
        pairingInProgress = nil
        if tellKey { _ = send?(Message(t: Message.Kind.pairCancel).plainEnvelope()) }
    }

    private func fail(_ reason: String) {
        pairingInProgress?.timeout?.cancel()
        pairingInProgress = nil
        onPairingEvent?(.failed(reason))
    }

    private func maybeFinishPairing() {
        guard var p = pairingInProgress, let key = p.sessionKey, let keyPub = p.keyPublicKey, p.keyConfirmed else { return }
        if role == .computer && !p.userConfirmed { return }
        p.timeout?.cancel()
        pairingInProgress = nil
        pairing = KeyPairing(keyId: p.keyId, sessionKey: key.withUnsafeBytes { Data($0) }, secret: p.secret,
                             keyPublicKey: keyPub, keyName: p.keyName, pairedAt: Date(), lastCtr: 0)
        onPairingEvent?(.paired(keyName: p.keyName, vaultCount: p.vaultCount))
        // hand over the wrapping secret; the key needs an unlocked vault for that
        var enroll = Message(t: Message.Kind.enroll)
        enroll.secret = p.secret.base64EncodedString()
        request(enroll, timeout: 20) { [weak self] reply in
            self?.log("enroll → \(reply?.status ?? "no answer")")
        }
    }

    // MARK: - Incoming

    public func receive(_ envelope: Data) {
        guard let type = envelope.first.flatMap(EnvelopeType.init(rawValue:)) else { return }
        switch type {
        case .plain:
            guard let message = Message.decode(Data(envelope.dropFirst())) else { return }
            handlePlain(message)
        case .sealed:
            handleSealed(envelope)
        }
    }

    private func handlePlain(_ message: Message) {
        guard var p = pairingInProgress else { return }
        switch message.t {
        case Message.Kind.pairButton:
            onPairingEvent?(.waitingForButton)

        case Message.Kind.pairPub:
            guard let keyPub = message.pub.flatMap({ Data(base64Encoded: $0) }),
                  let key = try? SafelyCrypto.sessionKey(identity: p.identity, peerPublicKey: keyPub,
                                                         browserPublicKey: p.identity.publicKey, phonePublicKey: keyPub) else {
                fail("The key sent an invalid public key.")
                return
            }
            p.sessionKey = key
            p.keyPublicKey = keyPub
            p.keyName = message.name ?? p.keyName
            p.code = SafelyCrypto.sas(browserPublicKey: p.identity.publicKey, phonePublicKey: keyPub, nonce: p.nonce)
            pairingInProgress = p
            var reveal = Message(t: Message.Kind.pairReveal)
            reveal.pub = p.identity.publicKey.base64EncodedString()
            reveal.nonce = p.nonce.base64EncodedString()
            _ = send?(reveal.plainEnvelope())
            if role == .computer, let code = p.code { onPairingEvent?(.compare(code: code)) }

        case Message.Kind.pairCancel:
            fail(message.reason ?? "Pairing was cancelled.")

        default:
            break
        }
    }

    private func handleSealed(_ envelope: Data) {
        guard let keyId = SafelyCrypto.keyId(ofSealed: envelope) else { return }

        if var p = pairingInProgress, keyId == p.keyId, let key = p.sessionKey {
            guard let plain = try? SafelyCrypto.open(envelope, key: key), let message = Message.decode(plain) else { return }
            if message.t == Message.Kind.pairConfirm {
                p.keyConfirmed = true
                p.keyName = message.name ?? p.keyName
                p.vaultCount = message.vaultCount ?? 0
                pairingInProgress = p
                maybeFinishPairing()
            }
            return
        }

        guard var pairing, keyId == pairing.keyId else { return }
        let key = SymmetricKey(data: pairing.sessionKey)
        guard let plain = try? SafelyCrypto.open(envelope, key: key), let message = Message.decode(plain),
              let ctr = message.ctr, ctr > pairing.lastCtr else { return }
        pairing.lastCtr = ctr
        self.pairing = pairing

        switch message.t {
        case Message.Kind.approve:
            if let target = message.target, let code = message.code {
                onApprovalRequest?(ApprovalRequest(id: target, code: code, name: message.name ?? "Computer"))
            }
        case Message.Kind.unpair:
            self.pairing = nil
            onUnpaired?()
        default:
            if let id = message.id, let waiter = pending.removeValue(forKey: id) {
                timers.removeValue(forKey: id)?.cancel()
                waiter(message)
            }
        }
    }

    // MARK: - Requests

    /// Sends a sealed message; the completion gets the reply matched by id, or nil on timeout / no link.
    public func request(_ message: Message, timeout: TimeInterval = 15, completion: @escaping (Message?) -> Void) {
        guard let pairing else { completion(nil); return }
        let id = SafelyCrypto.randomBytes(8).map { String(format: "%02x", $0) }.joined()
        var message = message
        message.id = id
        message.ctr = counter.next()
        guard let envelope = try? SafelyCrypto.seal(message.encoded(), key: SymmetricKey(data: pairing.sessionKey), keyId: pairing.keyId) else {
            completion(nil)
            return
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.pending.removeValue(forKey: id)
            self?.timers.removeValue(forKey: id)
            completion(nil)
        }
        pending[id] = completion
        timers[id] = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        if !(send?(envelope) ?? false) {
            timer.cancel()
            pending.removeValue(forKey: id)
            timers.removeValue(forKey: id)
            completion(nil)
        }
    }

    public func request(_ message: Message, timeout: TimeInterval = 15) async -> Message? {
        await withCheckedContinuation { continuation in
            request(message, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Opens the vault on the key with this device's secret. Call after every connection.
    public func unlock() async -> Message? {
        guard let pairing else { return nil }
        var m = Message(t: Message.Kind.unlock)
        m.secret = pairing.secret.base64EncodedString()
        return await request(m, timeout: 10)
    }

    /// The phone's answer to "does the computer show this code?"
    public func answerApproval(_ approval: ApprovalRequest, ok: Bool) {
        var m = Message(t: Message.Kind.approveReply)
        m.target = approval.id
        m.ok = ok
        request(m, timeout: 10) { _ in }
    }

    public func forgetPairing(tellKey: Bool) {
        if tellKey { request(Message(t: Message.Kind.unpair), timeout: 5) { _ in } }
        pairing = nil
    }

    private func log(_ s: String) { onLog?(s) }
}
