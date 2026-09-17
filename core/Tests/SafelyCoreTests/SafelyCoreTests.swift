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
}
