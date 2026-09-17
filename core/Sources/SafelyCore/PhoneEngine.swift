import CryptoKit
import Foundation

public struct PairedBrowser: Codable, Identifiable, Equatable {
    public var keyId: Data
    public var name: String
    public var publicKey: Data
    public var pairedAt: Date
    public var lastSeenAt: Date?
    /// Highest message counter accepted from this browser. Anything at or below is a replay.
    public var lastCtr: Int64

    public var id: String { keyId.map { String(format: "%02x", $0) }.joined() }
}

public protocol PairingStore: AnyObject {
    func browser(keyId: Data) -> PairedBrowser?
    func save(_ browser: PairedBrowser)
    func remove(keyId: Data)
}

public struct CredentialRequest {
    public let id: String
    public let origin: String
    public let url: String?
    /// "auto" when a login page was detected, "user" when the person clicked the Safely icon.
    public let reason: String
    public let browser: PairedBrowser
}

public enum CredentialReply {
    case items([VaultItem])
    case denied
    case locked
}

public enum PairingResult {
    case paired(PairedBrowser)
    case failed(String)
}

public protocol PhoneEngineDelegate: AnyObject {
    func phoneEngine(_ engine: PhoneEngine, showPairingCode code: String, browserName: String)
    func phoneEngine(_ engine: PhoneEngine, pairingEnded result: PairingResult)
    func phoneEngine(_ engine: PhoneEngine, credentialsFor request: CredentialRequest, reply: @escaping (CredentialReply) -> Void)
    func phoneEngine(_ engine: PhoneEngine, save item: WireItem, origin: String, from browser: PairedBrowser, reply: @escaping (Bool) -> Void)
    func phoneEngine(_ engine: PhoneEngine, importItems items: [WireItem], from browser: PairedBrowser) -> ImportSummary
    func phoneEngineVaultCount(_ engine: PhoneEngine) -> Int
}

/// Phone side of the Safely protocol: pairing, decrypting requests, replay and rate protection.
/// Transport and storage are injected, so the same code runs in the iOS app and in safely-simphone.
public final class PhoneEngine {
    public weak var delegate: PhoneEngineDelegate?
    /// Hands a finished envelope to the transport.
    public var send: ((Data) -> Void)?
    /// Pairing requests are ignored unless the person opened "Pair a browser" in the app.
    public var pairingWindowOpen = false {
        didSet { if !pairingWindowOpen { pending = nil } }
    }

    private let identity: Identity
    private let store: PairingStore
    private let deviceName: String
    private let counter = MonotonicCounter()
    private var sessionKeys: [Data: SymmetricKey] = [:]
    private var recentRequests: [Data: [Date]] = [:]
    private let maxRequestsPerMinute = 40

    private struct PendingPairing {
        var commit: Data
        var browserName: String
        var browserPublicKey: Data?
        var key: SymmetricKey?
    }
    private var pending: PendingPairing?

    public init(identity: Identity, store: PairingStore, deviceName: String) {
        self.identity = identity
        self.store = store
        self.deviceName = deviceName
    }

    // MARK: - Incoming

    public func receive(_ envelope: Data) {
        guard let type = envelope.first.flatMap(EnvelopeType.init(rawValue:)) else { return }
        switch type {
        case .plain:
            guard let message = Message.decode(Data(envelope.dropFirst())) else { return }
            handlePairing(message)
        case .sealed:
            handleSealed(envelope)
        }
    }

    private func handlePairing(_ message: Message) {
        switch message.t {
        case Message.Kind.pairCommit:
            guard pairingWindowOpen, let commit = message.commit.flatMap({ Data(base64Encoded: $0) }), commit.count == 32 else {
                var cancel = Message(t: Message.Kind.pairCancel)
                cancel.reason = "Open Safely on your phone and tap “Pair a browser” first."
                send?(cancel.plainEnvelope())
                return
            }
            pending = PendingPairing(commit: commit, browserName: String((message.name ?? "Browser").prefix(60)))
            var reply = Message(t: Message.Kind.pairPub)
            reply.pub = identity.publicKey.base64EncodedString()
            reply.name = deviceName
            send?(reply.plainEnvelope())

        case Message.Kind.pairReveal:
            guard var p = pending, p.browserPublicKey == nil,
                  let pub = message.pub.flatMap({ Data(base64Encoded: $0) }),
                  let nonce = message.nonce.flatMap({ Data(base64Encoded: $0) }) else { return }
            guard SafelyCrypto.commitment(browserPublicKey: pub, nonce: nonce) == p.commit,
                  let key = try? SafelyCrypto.sessionKey(identity: identity, peerPublicKey: pub,
                                                         browserPublicKey: pub, phonePublicKey: identity.publicKey) else {
                pending = nil
                delegate?.phoneEngine(self, pairingEnded: .failed("The browser's key did not match its commitment."))
                return
            }
            p.browserPublicKey = pub
            p.key = key
            pending = p
            let code = SafelyCrypto.sas(browserPublicKey: pub, phonePublicKey: identity.publicKey, nonce: nonce)
            delegate?.phoneEngine(self, showPairingCode: code, browserName: p.browserName)

        case Message.Kind.pairCancel:
            guard pending != nil else { return }
            pending = nil
            delegate?.phoneEngine(self, pairingEnded: .failed(message.reason ?? "Cancelled in the browser."))

        default:
            break
        }
    }

    /// Called when the person says whether the code on the phone equals the code in the browser.
    public func confirmPairing(_ matches: Bool) {
        guard let p = pending, let pub = p.browserPublicKey, let key = p.key else { return }
        pending = nil
        guard matches else {
            var cancel = Message(t: Message.Kind.pairCancel)
            cancel.reason = "Rejected on the phone."
            send?(cancel.plainEnvelope())
            delegate?.phoneEngine(self, pairingEnded: .failed("Codes did not match."))
            return
        }
        let keyId = SafelyCrypto.keyId(forBrowserPublicKey: pub)
        let browser = PairedBrowser(keyId: keyId, name: p.browserName, publicKey: pub, pairedAt: Date(), lastSeenAt: Date(), lastCtr: 0)
        store.save(browser)
        sessionKeys[keyId] = key
        var confirm = Message(t: Message.Kind.pairConfirm)
        confirm.name = deviceName
        confirm.vaultCount = delegate?.phoneEngineVaultCount(self)
        sendSealed(confirm, to: browser)
        pairingWindowOpen = false
        delegate?.phoneEngine(self, pairingEnded: .paired(browser))
    }

    public func forget(_ browser: PairedBrowser) {
        sendSealed(Message(t: Message.Kind.unpair), to: browser)
        store.remove(keyId: browser.keyId)
        sessionKeys[browser.keyId] = nil
    }

    private func handleSealed(_ envelope: Data) {
        guard let keyId = SafelyCrypto.keyId(ofSealed: envelope),
              var browser = store.browser(keyId: keyId),
              let key = sessionKey(for: browser),
              let plaintext = try? SafelyCrypto.open(envelope, key: key),
              let message = Message.decode(plaintext),
              let ctr = message.ctr, ctr > browser.lastCtr else { return }

        browser.lastCtr = ctr
        browser.lastSeenAt = Date()
        store.save(browser)

        let id = message.id ?? ""
        switch message.t {
        case Message.Kind.ping:
            var pong = Message(t: Message.Kind.pong, id: id)
            pong.name = deviceName
            pong.vaultCount = delegate?.phoneEngineVaultCount(self)
            sendSealed(pong, to: browser)

        case Message.Kind.get:
            guard let origin = message.origin, !origin.isEmpty else { return }
            guard allowRequest(from: browser) else {
                var reply = Message(t: Message.Kind.creds, id: id)
                reply.status = Message.Status.busy
                sendSealed(reply, to: browser)
                return
            }
            let request = CredentialRequest(id: id, origin: origin, url: message.url, reason: message.reason ?? "auto", browser: browser)
            guard let delegate else { return }
            delegate.phoneEngine(self, credentialsFor: request) { [weak self] decision in
                guard let self else { return }
                var reply = Message(t: Message.Kind.creds, id: id)
                switch decision {
                case .items(let items):
                    reply.status = items.isEmpty ? Message.Status.none : Message.Status.ok
                    reply.items = items.map(\.wire)
                case .denied: reply.status = Message.Status.denied
                case .locked: reply.status = Message.Status.locked
                }
                self.sendSealed(reply, to: browser)
            }

        case Message.Kind.save:
            guard let item = message.item, let origin = message.origin, let delegate else { return }
            delegate.phoneEngine(self, save: item, origin: origin, from: browser) { [weak self] saved in
                var ack = Message(t: Message.Kind.ack, id: id)
                ack.status = saved ? Message.Status.ok : Message.Status.denied
                self?.sendSealed(ack, to: browser)
            }

        case Message.Kind.importBatch:
            guard let items = message.items, let delegate else { return }
            let summary = delegate.phoneEngine(self, importItems: items, from: browser)
            var ack = Message(t: Message.Kind.ack, id: id)
            ack.status = Message.Status.ok
            ack.batch = message.batch
            ack.imported = summary.imported
            ack.updated = summary.updated
            ack.skipped = summary.skipped
            ack.vaultCount = delegate.phoneEngineVaultCount(self)
            sendSealed(ack, to: browser)

        case Message.Kind.unpair:
            store.remove(keyId: browser.keyId)
            sessionKeys[browser.keyId] = nil

        default:
            break
        }
    }

    // MARK: - Helpers

    private func sessionKey(for browser: PairedBrowser) -> SymmetricKey? {
        if let key = sessionKeys[browser.keyId] { return key }
        let key = try? SafelyCrypto.sessionKey(identity: identity, peerPublicKey: browser.publicKey,
                                               browserPublicKey: browser.publicKey, phonePublicKey: identity.publicKey)
        sessionKeys[browser.keyId] = key
        return key
    }

    private func sendSealed(_ message: Message, to browser: PairedBrowser) {
        guard let key = sessionKey(for: browser) else { return }
        var message = message
        message.ctr = counter.next()
        guard let envelope = try? SafelyCrypto.seal(message.encoded(), key: key, keyId: browser.keyId) else { return }
        send?(envelope)
    }

    private func allowRequest(from browser: PairedBrowser) -> Bool {
        let now = Date()
        var recent = (recentRequests[browser.keyId] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < maxRequestsPerMinute else { return false }
        recent.append(now)
        recentRequests[browser.keyId] = recent
        return true
    }
}
