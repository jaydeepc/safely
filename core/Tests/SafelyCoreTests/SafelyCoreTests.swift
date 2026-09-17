import XCTest
@testable import SafelyCore

final class SafelyCoreTests: XCTestCase {
    func testChunkRoundTrip() {
        for size in [0, 1, 156, 157, 158, 5000, Chunker.maxMessageSize] {
            let message = SafelyCrypto.randomBytes(size)
            let frames = Chunker.split(message, msgId: 7)
            XCTAssertTrue(frames.allSatisfy { $0.count <= SafelyBLE.frameSize })
            let reassembler = Reassembler()
            var result: Data?
            for frame in frames { result = reassembler.feed(frame) ?? result }
            XCTAssertEqual(result, message, "size \(size)")
        }
        XCTAssertTrue(Chunker.split(Data(count: Chunker.maxMessageSize + 1), msgId: 0).isEmpty)
    }

    func testInterleavedMessages() {
        let a = SafelyCrypto.randomBytes(400), b = SafelyCrypto.randomBytes(400)
        let fa = Chunker.split(a, msgId: 1), fb = Chunker.split(b, msgId: 2)
        let reassembler = Reassembler()
        var done: [Data] = []
        for i in 0..<fa.count {
            if let m = reassembler.feed(fa[i]) { done.append(m) }
            if let m = reassembler.feed(fb[i]) { done.append(m) }
        }
        XCTAssertEqual(done, [a, b])
    }

    func testSessionKeysAgreeAndSealOpens() throws {
        let browser = Identity(), phone = Identity()
        let k1 = try SafelyCrypto.sessionKey(identity: browser, peerPublicKey: phone.publicKey, browserPublicKey: browser.publicKey, phonePublicKey: phone.publicKey)
        let k2 = try SafelyCrypto.sessionKey(identity: phone, peerPublicKey: browser.publicKey, browserPublicKey: browser.publicKey, phonePublicKey: phone.publicKey)
        let keyId = SafelyCrypto.keyId(forBrowserPublicKey: browser.publicKey)
        let sealed = try SafelyCrypto.seal(Data("hello".utf8), key: k1, keyId: keyId)
        XCTAssertEqual(try SafelyCrypto.open(sealed, key: k2), Data("hello".utf8))

        var tampered = sealed
        tampered[3] ^= 1  // key id is authenticated
        XCTAssertThrowsError(try SafelyCrypto.open(tampered, key: k2))
    }

    func testDomainMatching() {
        let items = [
            VaultItem(title: "Google", url: "https://accounts.google.com/signin", username: "a", password: "p"),
            VaultItem(title: "Evil", url: "https://google.com.evil.io", username: "b", password: "p"),
            VaultItem(title: "Alice pages", url: "https://alice.github.io", username: "c", password: "p"),
            VaultItem(title: "BBC", url: "https://www.bbc.co.uk", username: "d", password: "p"),
        ]
        XCTAssertEqual(DomainMatcher.matches(for: "https://mail.google.com", in: items).map(\.title), ["Google"])
        XCTAssertEqual(DomainMatcher.matches(for: "https://bob.github.io", in: items).map(\.title), [])
        XCTAssertEqual(DomainMatcher.matches(for: "https://account.bbc.co.uk", in: items).map(\.title), ["BBC"])
        XCTAssertEqual(DomainMatcher.matches(for: "https://other.co.uk", in: items).map(\.title), [])
        XCTAssertEqual(DomainMatcher.matches(for: "https://evil.io", in: items).map(\.title), ["Evil"])
    }

    func testCSVFormats() {
        let chrome = "name,url,username,password,note\ngithub.com,https://github.com/login,me,\"p,w\"\"x\",\"line1\nline2\"\n,https://x.com,,,\n"
        let parsed = PasswordCSV.parse(chrome)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].password, "p,w\"x")
        XCTAssertEqual(parsed[0].notes, "line1\nline2")

        let safari = "Title,URL,Username,Password,Notes,OTPAuth\r\nApple,https://apple.com,me@icloud.com,secret,,\r\n"
        XCTAssertEqual(PasswordCSV.parse(safari).first?.username, "me@icloud.com")
    }

    func testMergeDeduplicates() {
        var vault: [VaultItem] = []
        let first = vault.merge([WireItem(title: "", url: "https://a.com/login", username: "Me", password: "1")])
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(vault[0].title, "a.com")
        let again = vault.merge([
            WireItem(title: "A", url: "https://www.a.com", username: "me", password: "1"),
            WireItem(title: "A", url: "https://a.com", username: "me", password: "2"),
        ])
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(again.updated, 1)
        XCTAssertEqual(vault.count, 1)
    }

    /// Full pairing + request cycle with an in-memory browser speaking the wire protocol.
    func testPairingAndGet() throws {
        final class Store: PairingStore {
            var items: [Data: PairedBrowser] = [:]
            func browser(keyId: Data) -> PairedBrowser? { items[keyId] }
            func save(_ browser: PairedBrowser) { items[browser.keyId] = browser }
            func remove(keyId: Data) { items[keyId] = nil }
        }
        final class Phone: PhoneEngineDelegate {
            var code: String?
            func phoneEngine(_ engine: PhoneEngine, showPairingCode code: String, browserName: String) { self.code = code }
            func phoneEngine(_ engine: PhoneEngine, pairingEnded result: PairingResult) {}
            func phoneEngine(_ engine: PhoneEngine, credentialsFor request: CredentialRequest, reply: @escaping (CredentialReply) -> Void) {
                reply(.items([VaultItem(title: "T", url: request.origin, username: "u", password: "pw")]))
            }
            func phoneEngine(_ engine: PhoneEngine, save item: WireItem, origin: String, from browser: PairedBrowser, reply: @escaping (Bool) -> Void) { reply(true) }
            func phoneEngine(_ engine: PhoneEngine, importItems items: [WireItem], from browser: PairedBrowser) -> ImportSummary { ImportSummary() }
            func phoneEngineVaultCount(_ engine: PhoneEngine) -> Int { 1 }
        }

        let phoneIdentity = Identity(), browser = Identity()
        let store = Store(), phone = Phone()
        let engine = PhoneEngine(identity: phoneIdentity, store: store, deviceName: "Test")
        engine.delegate = phone
        var outbox: [Data] = []
        engine.send = { outbox.append($0) }

        let nonce = SafelyCrypto.randomBytes(16)
        var commit = Message(t: Message.Kind.pairCommit)
        commit.commit = SafelyCrypto.commitment(browserPublicKey: browser.publicKey, nonce: nonce).base64EncodedString()

        engine.receive(commit.plainEnvelope())  // window closed → refused
        XCTAssertEqual(Message.decode(Data(outbox.removeFirst().dropFirst()))?.t, Message.Kind.pairCancel)

        engine.pairingWindowOpen = true
        engine.receive(commit.plainEnvelope())
        let pairPub = try XCTUnwrap(Message.decode(Data(outbox.removeFirst().dropFirst())))
        let phonePub = try XCTUnwrap(pairPub.pub.flatMap { Data(base64Encoded: $0) })

        var reveal = Message(t: Message.Kind.pairReveal)
        reveal.pub = browser.publicKey.base64EncodedString()
        reveal.nonce = nonce.base64EncodedString()
        engine.receive(reveal.plainEnvelope())
        XCTAssertEqual(phone.code, SafelyCrypto.sas(browserPublicKey: browser.publicKey, phonePublicKey: phonePub, nonce: nonce))

        engine.confirmPairing(true)
        let key = try SafelyCrypto.sessionKey(identity: browser, peerPublicKey: phonePub, browserPublicKey: browser.publicKey, phonePublicKey: phonePub)
        let confirm = try XCTUnwrap(Message.decode(try SafelyCrypto.open(outbox.removeFirst(), key: key)))
        XCTAssertEqual(confirm.t, Message.Kind.pairConfirm)

        let keyId = SafelyCrypto.keyId(forBrowserPublicKey: browser.publicKey)
        var get = Message(t: Message.Kind.get, id: "r1")
        get.origin = "https://example.com"
        get.ctr = 1000
        let sealedGet = try SafelyCrypto.seal(get.encoded(), key: key, keyId: keyId)
        engine.receive(sealedGet)
        let creds = try XCTUnwrap(Message.decode(try SafelyCrypto.open(outbox.removeFirst(), key: key)))
        XCTAssertEqual(creds.items?.first?.password, "pw")

        engine.receive(sealedGet)  // replay
        XCTAssertTrue(outbox.isEmpty)
    }
}
