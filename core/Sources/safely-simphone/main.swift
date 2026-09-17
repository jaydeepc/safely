// safely-simphone — a stand-in for the iOS app, for testing the key + extension without a phone.
//
// It runs the very same PhoneEngine the app uses, connects to the key in the phone role, and serves
// a small demo vault. Pairings survive restarts; imported passwords are kept in memory only.
//
//   safely-simphone                 pairing window open, asks y/n for the pairing code
//   safely-simphone --auto-confirm  accepts every pairing code (automated tests)
//   safely-simphone --stdio         no Bluetooth: envelopes as base64 lines on stdin/stdout (protocol tests)

import Foundation
import SafelyCore

let autoConfirm = CommandLine.arguments.contains("--auto-confirm")
let stdioMode = CommandLine.arguments.contains("--stdio")

/// In stdio mode stdout carries envelopes, so human readable lines are marked with "#".
func say(_ message: String) {
    print(stdioMode ? "# " + message : message)
    fflush(stdout)
}

struct SimState: Codable {
    var identity: Data
    var browsers: [PairedBrowser]
}

final class SimStore: PairingStore {
    let url: URL
    var state: SimState

    init() {
        if stdioMode {  // protocol tests start from a clean slate and leave nothing behind
            url = FileManager.default.temporaryDirectory.appendingPathComponent("safely-simphone-\(UUID().uuidString).json")
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Safely")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("simphone.json")
        }
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(SimState.self, from: data) {
            state = saved
        } else {
            state = SimState(identity: Identity().rawRepresentation, browsers: [])
        }
        persist()
    }

    func persist() {
        try? JSONEncoder().encode(state).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func browser(keyId: Data) -> PairedBrowser? { state.browsers.first { $0.keyId == keyId } }

    func save(_ browser: PairedBrowser) {
        state.browsers.removeAll { $0.keyId == browser.keyId }
        state.browsers.append(browser)
        persist()
    }

    func remove(keyId: Data) {
        state.browsers.removeAll { $0.keyId == keyId }
        persist()
    }
}

final class SimPhone: PhoneEngineDelegate {
    var vault: [VaultItem] = [
        VaultItem(title: "GitHub", url: "https://github.com/login", username: "demo@safely.test", password: "demo-Gh-7431!"),
        VaultItem(title: "Safely test page", url: "http://localhost:8765/", username: "tester", password: "demo-Local-2290!"),
        VaultItem(title: "Example", url: "https://example.com", username: "alice", password: "demo-Ex-5512!"),
        VaultItem(title: "Example (work)", url: "https://login.example.com", username: "alice@work", password: "demo-Ex-9983!"),
    ]

    func phoneEngine(_ engine: PhoneEngine, showPairingCode code: String, browserName: String) {
        say("PAIRING CODE \(code)  ← must equal the code shown by “\(browserName)”")
        if autoConfirm {
            engine.confirmPairing(true)
        } else {
            say("Do the codes match? [y/n]")
            DispatchQueue.global().async {
                let answer = readLine()?.lowercased() ?? "n"
                DispatchQueue.main.async { engine.confirmPairing(answer.hasPrefix("y")) }
            }
        }
    }

    func phoneEngine(_ engine: PhoneEngine, pairingEnded result: PairingResult) {
        switch result {
        case .paired(let browser): say("PAIRED \(browser.name) [\(browser.id)]")
        case .failed(let reason): say("PAIRING FAILED \(reason)")
        }
        engine.pairingWindowOpen = true  // the simulator is always willing to pair
    }

    func phoneEngine(_ engine: PhoneEngine, credentialsFor request: CredentialRequest, reply: @escaping (CredentialReply) -> Void) {
        let matches = DomainMatcher.matches(for: request.origin, in: vault)
        say("GET \(request.origin) (\(request.reason)) from \(request.browser.name) → \(matches.count) match(es)")
        reply(.items(matches))
    }

    func phoneEngine(_ engine: PhoneEngine, save item: WireItem, origin: String, from browser: PairedBrowser, reply: @escaping (Bool) -> Void) {
        let summary = vault.merge([item])
        say("SAVE \(item.username) @ \(origin) → imported \(summary.imported) updated \(summary.updated)")
        reply(true)
    }

    func phoneEngine(_ engine: PhoneEngine, importItems items: [WireItem], from browser: PairedBrowser) -> ImportSummary {
        let summary = vault.merge(items)
        say("IMPORT \(items.count) item(s) → imported \(summary.imported) updated \(summary.updated) skipped \(summary.skipped); vault=\(vault.count)")
        return summary
    }

    func phoneEngineVaultCount(_ engine: PhoneEngine) -> Int { vault.count }
}

let store = SimStore()
let identity = try Identity(rawRepresentation: store.state.identity)
let phone = SimPhone()
let engine = PhoneEngine(identity: identity, store: store, deviceName: "Simulated iPhone")
say("Simulated phone ready — \(store.state.browsers.count) paired browser(s), \(phone.vault.count) demo logins")
engine.delegate = phone
engine.pairingWindowOpen = true

if stdioMode {
    // Log lines start with "#", everything else is a base64 envelope.
    engine.send = { envelope in
        print(envelope.base64EncodedString())
        fflush(stdout)
    }
    Thread.detachNewThread {
        while let line = readLine() {
            guard let envelope = Data(base64Encoded: line.trimmingCharacters(in: .whitespaces)) else { continue }
            DispatchQueue.main.async { engine.receive(envelope) }
        }
        exit(0)
    }
} else {
    let link = RelayLink(role: .phone)
    engine.send = { envelope in
        if !link.send(envelope) { say("SEND FAILED key not connected") }
    }
    link.onLog = { say("[ble] \($0)") }
    link.onState = { state in
        say("STATE bluetooth=\(state.bluetooth.rawValue) key=\(state.keyConnected) browser=\(state.peerPresent) rssi=\(state.rssi.map(String.init) ?? "-")")
    }
    link.onMessage = { engine.receive($0) }
    link.start()
    withExtendedLifetime(link) { RunLoop.main.run() }
}

RunLoop.main.run()
