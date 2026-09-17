// shhlock-keytest — drives a Shhlock Key over USB serial through the real KeyClient, no Bluetooth needed.
//
// Flash the key with -DSHHLOCK_SERIAL_TEST (firmware/flash.sh --test), then:
//   swift run shhlock-keytest [/dev/cu.usbmodemXXXX]
//
// The serial build accepts "P <base64>" / "C <base64>" (envelope from a virtual phone / computer),
// "BTN" (button press), "RESET" (factory reset) and "REBOOT", and prints "P> …" / "C> …" back.

import Darwin
import Foundation
import SafelyCore

// ── serial port ──

final class Serial {
    let fd: Int32
    private var buffer = Data()
    var onLine: ((String) -> Void)?

    init(path: String) {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { fatalError("cannot open \(path)") }
        var tty = termios()
        tcgetattr(fd, &tty)
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &tty)
        Thread.detachNewThread { [self] in
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n])
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        DispatchQueue.main.async { self.onLine?(line) }
                    }
                } else {
                    usleep(5000)
                }
            }
        }
    }

    func write(_ line: String) {
        var data = Array((line + "\n").utf8)
        while !data.isEmpty {
            let n = Darwin.write(fd, data, data.count)
            if n > 0 { data.removeFirst(n) } else { usleep(2000) }
        }
    }
}

// ── harness ──

let port = CommandLine.arguments.dropFirst().first ?? (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
    .filter { $0.hasPrefix("cu.usbmodem") }.first.map { "/dev/" + $0 } ?? "/dev/cu.usbmodem1101"
let serial = Serial(path: port)
var keyLog: [String] = []
var pass = 0

func check(_ ok: Bool, _ what: String) {
    if ok { pass += 1; print("  ✓ \(what)") } else { print("  ✗ \(what)"); print("  key log:\n    " + keyLog.suffix(70).joined(separator: "\n    ")); exit(1) }
}

var phonePairing: KeyPairing?
var computerPairing: KeyPairing?
let phone = KeyClient(role: .phone, name: "Test iPhone", stored: nil, persist: { phonePairing = $0 })
let computer = KeyClient(role: .computer, name: "Test Mac", stored: nil, persist: { computerPairing = $0 })
phone.send = { serial.write("P " + $0.base64EncodedString()); return true }
computer.send = { serial.write("C " + $0.base64EncodedString()); return true }

var lastEnvelopeToKey: Data?
serial.onLine = { line in
    if line.hasPrefix("P> ") { Data(base64Encoded: String(line.dropFirst(3))).map(phone.receive) }
    else if line.hasPrefix("C> ") { Data(base64Encoded: String(line.dropFirst(3))).map(computer.receive) }
    else if !line.isEmpty { keyLog.append(line) }
}

func sleep(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

func waitFor(_ what: String, _ seconds: Double = 15, _ test: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if test() { return true }
        await sleep(0.05)
    }
    print("  timed out waiting for \(what)")
    return false
}

func items(_ n: Int, prefix: String) -> [WireItem] {
    (0..<n).map { WireItem(title: "\(prefix) \($0)", url: "https://\(prefix.lowercased())\($0).test/login", username: "user\($0)@example.com", password: "pw-\(prefix)-\($0)-" + String(repeating: "x", count: 20)) }
}

Task { @MainActor in
    print("Shhlock Key protocol test on \(port)")
    serial.write("RESET")
    await sleep(1.5)

    print("1. phone pairs by pressing the button")
    var events: [KeyPairingEvent] = []
    phone.onPairingEvent = { events.append($0) }
    phone.startPairing()
    check(await waitFor("pair_button", 10) { events.contains(.waitingForButton) }, "key asks for the button")
    serial.write("BTN")
    check(await waitFor("paired", 15) { phonePairing != nil }, "phone paired: \(phonePairing?.keyName ?? "-")")
    await sleep(1.0)  // enroll round trip

    print("2. unlock and load the vault")
    var reply = await phone.unlock()
    check(reply?.status == "ok" && reply?.vaultCount == 0, "fresh vault unlocked, 0 logins")
    let vault = items(120, prefix: "Site") + [WireItem(title: "GitHub", url: "https://github.com/login", username: "demo@shhlock.test", password: "gh-secret-1"),
                                             WireItem(title: "Example", url: "https://example.com", username: "alice", password: "ex-1"),
                                             WireItem(title: "Example work", url: "https://login.example.com", username: "alice@work", password: "ex-2", updatedAt: 2_000_000_000)]
    let batches = stride(from: 0, to: vault.count, by: 25).map { Array(vault[$0..<min($0 + 25, vault.count)]) }
    var putOk = true
    for (i, batch) in batches.enumerated() {
        var m = Message(t: Message.Kind.vaultPut)
        m.batch = i + 1
        m.totalBatches = batches.count
        m.items = batch
        let r = await phone.request(m, timeout: 30)
        putOk = putOk && r?.status == "ok"
        if i == batches.count - 1 { check(r?.vaultCount == vault.count, "vault_put stored \(r?.vaultCount ?? -1) logins in \(batches.count) batches") }
    }
    check(putOk, "every batch acknowledged")

    print("3. a computer pairs; the phone approves the code")
    var computerEvents: [KeyPairingEvent] = []
    var approval: ApprovalRequest?
    computer.onPairingEvent = { computerEvents.append($0) }
    phone.onApprovalRequest = { approval = $0 }
    computer.startPairing()
    check(await waitFor("codes", 20) { approval != nil && computerEvents.contains { if case .compare = $0 { return true } else { return false } } }, "both sides have a code")
    let computerCode: String? = computerEvents.compactMap { if case .compare(let c) = $0 { return c } else { return nil } }.first
    check(computerCode == approval?.code, "codes match: \(computerCode ?? "-") == \(approval?.code ?? "-")")
    phone.answerApproval(approval!, ok: true)
    computer.confirmPairing()
    check(await waitFor("computer paired", 15) { computerPairing != nil }, "computer paired")
    await sleep(1.0)

    print("4. the computer unlocks and fetches logins")
    reply = await computer.unlock()
    check(reply?.status == "ok", "computer unlock (vault already open)")
    var get = Message(t: Message.Kind.get)
    get.origin = "https://github.com"
    get.reason = "auto"
    reply = await computer.request(get)
    check(reply?.status == "ok" && reply?.items?.first?.password == "gh-secret-1", "github.com → 1 login")
    get.origin = "https://login.example.com"
    reply = await computer.request(get)
    check(reply?.items?.map(\.username) == ["alice@work", "alice"], "subdomain match, exact host first")
    get.origin = "https://nothing.invalid"
    reply = await computer.request(get)
    check(reply?.status == "none", "unknown site → none")

    print("5. the computer saves a new login; the phone reads it back")
    var save = Message(t: Message.Kind.save)
    save.origin = "https://new.site"
    save.item = WireItem(title: "new.site", url: "https://new.site/login", username: "me", password: "pässwörd ✓ \"quoted\"")
    reply = await computer.request(save)
    check(reply?.status == "ok" && reply?.vaultCount == vault.count + 1, "saved, vault now \(reply?.vaultCount ?? -1)")
    var pull = Message(t: Message.Kind.vaultPull)
    pull.offset = vault.count
    pull.limit = 10
    reply = await phone.request(pull)
    check(reply?.items?.first?.password == "pässwörd ✓ \"quoted\"" && reply?.total == vault.count + 1, "vault_pull returns it with unicode intact")

    print("6. replay protection")
    var seen = false
    let realSend = computer.send!
    var captured: Data?
    computer.send = { env in captured = env; return realSend(env) }
    _ = await computer.request(Message(t: Message.Kind.ping))
    computer.send = realSend
    let before = keyLog.count
    if let captured { serial.write("C " + captured.base64EncodedString()) }
    await sleep(0.8)
    seen = keyLog[before...].contains { $0.contains("[get]") }
    check(!seen, "a replayed envelope is ignored")

    print("7. survives a reboot: vault is locked until a paired device unlocks it")
    serial.write("REBOOT")
    await sleep(3.5)
    reply = await computer.request(get, timeout: 5)
    check(reply?.status == "locked", "after reboot the vault is locked")
    reply = await computer.unlock()
    check(reply?.status == "ok" && reply?.vaultCount == vault.count + 1, "computer's secret unlocks it: \(reply?.vaultCount ?? -1) logins persisted")
    get.origin = "https://github.com"
    reply = await computer.request(get)
    check(reply?.items?.first?.password == "gh-secret-1", "logins readable again")

    print("8. the phone manages paired devices")
    reply = await phone.request(Message(t: Message.Kind.clientsList))
    check(reply?.clients?.count == 2, "clients_list → 2 devices")
    var remove = Message(t: Message.Kind.clientsRemove)
    remove.target = computerPairing!.keyId.base64EncodedString()
    reply = await phone.request(remove)
    check(reply?.status == "ok", "computer removed")
    reply = await computer.request(get, timeout: 3)
    check(reply == nil, "removed computer gets no answer")

    print("\nPASS — \(pass) checks: pairing, approval, vault sync, matching, save, replay, persistence across reboot.")
    exit(0)
}

RunLoop.main.run()
