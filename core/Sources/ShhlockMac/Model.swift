import AppKit
import Combine
import SafelyCore
import Security
import SwiftUI

/// The Mac side of Shhlock: Bluetooth link to the key, pairing, watching the focused form, filling.
@MainActor
final class MacModel: ObservableObject {
    enum PairingUI: Equatable {
        case idle, waiting, compare(String), paired, failed(String)
    }

    @Published var link = RelayLink.State()
    @Published var paired = false
    @Published var unlocked = false
    @Published var vaultCount: Int?
    @Published var pairingUI: PairingUI = .idle
    @Published var accessibilityGranted = AX.trusted
    @Published var autofill = UserDefaults.standard.object(forKey: "autofill") as? Bool ?? true { didSet { UserDefaults.standard.set(autofill, forKey: "autofill") } }
    @Published var lastFill: String?
    @Published var log: [String] = []

    private let relay = RelayLink(role: .browser)
    private var client: KeyClient!
    private var watcher: Timer?
    private var currentForm: FocusedForm?
    private var cache: [String: (Date, [WireItem])] = [:]
    private var asking: Set<String> = []
    private let chooser = ChooserPanel()
    private var unlockTask: Task<Void, Never>?

    init() {
        client = KeyClient(role: .computer, name: "\(Host.current().localizedName ?? "Mac")",
                           stored: PairingStore.load(), persist: { PairingStore.save($0) })
        paired = client.isPaired
        client.send = { [relay] in relay.send($0) }
        client.onLog = { [weak self] in self?.note($0) }
        client.onPairingEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .waitingForButton: pairingUI = .waiting
            case .compare(let code): pairingUI = .compare(code)
            case .paired(_, let count):
                pairingUI = .paired
                paired = true
                vaultCount = count
                Task { await self.unlockKey() }
            case .failed(let reason): pairingUI = .failed(reason)
            }
        }
        client.onUnpaired = { [weak self] in
            self?.paired = false
            self?.unlocked = false
        }
        relay.onLog = { [weak self] in self?.note("ble: \($0)") }
        relay.onMessage = { [weak self] in self?.client.receive($0) }
        relay.onState = { [weak self] state in
            guard let self else { return }
            let wasConnected = link.keyConnected
            link = state
            if state.keyConnected && !wasConnected { Task { await self.unlockKey() } }
            if !state.keyConnected { unlocked = false; cache.removeAll() }
        }
        relay.start()
        chooser.onPick = { [weak self] item in self?.fill(item) }
        startWatching()
    }

    // MARK: - Key

    private func unlockKey() async {
        guard paired, link.keyConnected else { return }
        if let reply = await client.unlock() {
            unlocked = reply.status == "ok"
            vaultCount = reply.vaultCount
            note("unlock → \(reply.status ?? "?") (\(reply.vaultCount ?? 0) logins)")
        }
    }

    func startPairing() {
        pairingUI = .waiting
        client.startPairing()
    }

    func confirmPairing() { client.confirmPairing() }
    func cancelPairing() {
        client.cancelPairing()
        pairingUI = .idle
    }

    func unpair() {
        client.forgetPairing(tellKey: true)
        paired = false
        unlocked = false
        pairingUI = .idle
    }

    // MARK: - Watching the screen

    func requestAccessibility() {
        AX.askForPermission()
    }

    private func startWatching() {
        watcher = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let granted = AX.trusted
        if granted != accessibilityGranted { accessibilityGranted = granted }
        guard granted else { return }

        let form = AX.focusedForm()
        if form == currentForm {
            if form == nil, chooser.isVisible, !chooser.mouseInside { chooser.hide() }
            return
        }
        currentForm = form
        chooser.hide()
        guard let form, paired, unlocked, link.keyConnected, form.origin.hasPrefix("http") else { return }
        Task { await handle(form) }
    }

    private func handle(_ form: FocusedForm) async {
        let items = await logins(for: form.origin)
        guard currentForm == form else { return }  // focus moved on while we asked
        switch items.count {
        case 0:
            break
        case 1 where autofill && !form.isSignup:
            fill(items[0])
        default:
            chooser.show(items: items, host: URL(string: form.origin)?.host ?? form.origin, anchor: form.frame)
        }
    }

    private func logins(for origin: String) async -> [WireItem] {
        if let (at, items) = cache[origin], Date().timeIntervalSince(at) < 90 { return items }
        guard !asking.contains(origin) else { return [] }
        asking.insert(origin)
        defer { asking.remove(origin) }
        var get = Message(t: Message.Kind.get)
        get.origin = origin
        get.reason = "auto"
        guard let reply = await client.request(get, timeout: 8) else {
            note("no answer from the key for \(origin)")
            return []
        }
        if reply.status == "locked" {
            await unlockKey()
            return await logins(for: origin)
        }
        let items = reply.items ?? []
        cache[origin] = (Date(), items)
        return items
    }

    /// Shows the chooser for the current form even when autofill is off (menu bar action).
    func fillNow() {
        guard let form = AX.focusedForm() else { return }
        currentForm = form
        Task {
            let items = await logins(for: form.origin)
            guard !items.isEmpty else { return }
            chooser.show(items: items, host: URL(string: form.origin)?.host ?? form.origin, anchor: form.frame)
        }
    }

    // MARK: - Filling

    private func fill(_ item: WireItem) {
        chooser.hide()
        guard let form = currentForm ?? AX.focusedForm() else { return }
        form.app.activate()
        if let username = form.username, !item.username.isEmpty {
            put(item.username, into: username)
        }
        if let password = form.password {
            put(item.password, into: password)
        } else if let username = form.username {
            // two-step login: only the username is on this screen
            put(item.username, into: username)
        }
        lastFill = "\(item.username) · \(URL(string: form.origin)?.host ?? form.origin)"
        note("filled \(lastFill ?? "")")
    }

    private func put(_ value: String, into field: AXUIElement) {
        AX.focus(field)
        let ok = AX.setValue(value, on: field)
        // Some pages ignore AX value changes; check and fall back to typing.
        let now = AX.string(field, kAXValueAttribute) ?? ""
        if !ok || (now != value && !(AX.subrole(field) == kAXSecureTextFieldSubrole && now.count == value.count)) {
            AX.setValue("", on: field)
            AX.type(value)
        }
    }

    private func note(_ s: String) {
        log.append(s)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// The pairing lives in the login keychain: readable only by this app, and by you after a prompt.
enum PairingStore {
    private static let service = "com.codecrackjd.shhlock.mac"
    private static let account = "key-pairing"

    static func load() -> KeyPairing? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeyPairing.self, from: data)
    }

    static func save(_ pairing: KeyPairing?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let pairing, let data = try? JSONEncoder().encode(pairing) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
