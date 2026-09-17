import Combine
import Foundation
import LocalAuthentication
import SafelyCore
import SwiftUI
import UserNotifications

enum PairingPhase: Equatable {
    case idle
    case connecting          // waiting for the key to answer
    case pressButton         // the key wants its button pressed
    case paired(String)
    case failed(String)
}

struct KeyStatus: Equatable {
    var connected = false
    var unlocked = false
    var vaultCount: Int?
    var lastSync: Date?
    var syncing = false
}

/// Owns the vault, the Bluetooth link to the key, and everything the phone does for it:
/// loading the vault onto the key, approving computers, keeping both sides in step.
@MainActor
final class AppModel: NSObject, ObservableObject {
    let vault = VaultStore()
    let activity = ActivityLog()
    let settings = AppSettings()

    @Published var linkState = RelayLink.State()
    @Published var key = KeyStatus()
    @Published var paired = false
    @Published var pairing: PairingPhase = .idle
    @Published var approval: ApprovalRequest?
    @Published var peers: [PeerInfo] = []
    @Published var isLocked = true

    static let isDemo = ProcessInfo.processInfo.arguments.contains("-SafelyDemo")

    private let link = RelayLink(role: .phone, restoreIdentifier: "com.codecrackjd.safely.central")
    private var client: KeyClient!
    private var backgroundedAt: Date?
    private var isForeground = true
    private var pushTask: Task<Void, Never>?
    private var vaultWatcher: AnyCancellable?

    override init() {
        super.init()
        client = KeyClient(role: .phone, name: UIDevice.current.name,
                           stored: Keychain.data(for: "key-pairing").flatMap { try? JSONDecoder().decode(KeyPairing.self, from: $0) },
                           persist: { pairing in
                               if let pairing, let data = try? JSONEncoder().encode(pairing) { Keychain.set(data, for: "key-pairing") }
                               else { Keychain.delete("key-pairing") }
                           })
        paired = client.isPaired
        client.send = { [link] in link.send($0) }
        client.onPairingEvent = { [weak self] event in self?.pairingEvent(event) }
        client.onApprovalRequest = { [weak self] request in self?.approvalArrived(request) }
        client.onUnpaired = { [weak self] in
            self?.paired = false
            self?.key = KeyStatus()
        }
        link.onMessage = { [weak self] envelope in self?.client.receive(envelope) }
        link.onState = { [weak self] state in self?.linkChanged(state) }

        vaultWatcher = vault.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedulePush() }
        }

        if Self.isDemo {
            isLocked = false
            seedDemo()
        } else {
            isLocked = settings.appLock
            link.start()
        }
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Link

    private func linkChanged(_ state: RelayLink.State) {
        let cameUp = state.keyConnected && !linkState.keyConnected
        withAnimation(.easeInOut(duration: 0.3)) { linkState = state }
        if !state.keyConnected {
            key.connected = false
            key.unlocked = false
            return
        }
        key.connected = true
        if cameUp, paired { Task { await connectToKey() } }
    }

    /// Unlock the key, pull what computers saved, push our vault.
    private func connectToKey() async {
        guard let reply = await client.unlock() else { return }
        key.unlocked = reply.status == "ok"
        key.vaultCount = reply.vaultCount
        if key.unlocked {
            await sync()
        } else if reply.status == "denied" {
            activity.add(.denied, site: "Shhlock Key", detail: "This phone's secret no longer opens the key. Reset the key and pair again.")
        }
    }

    // MARK: - Sync

    func sync() async {
        guard paired, key.connected, key.unlocked, !key.syncing else { return }
        key.syncing = true
        defer { key.syncing = false }

        // 1. pull: logins saved from computers since we last looked
        var pulled: [WireItem] = []
        var offset = 0
        while true {
            var pull = Message(t: Message.Kind.vaultPull)
            pull.offset = offset
            pull.limit = 25
            guard let reply = await client.request(pull, timeout: 20), let items = reply.items else { return }
            pulled += items
            offset += items.count
            if items.isEmpty || offset >= (reply.total ?? 0) { break }
        }
        let summary = vault.mergeNewer(pulled)
        if summary.imported + summary.updated > 0 {
            activity.add(.imported, site: "Shhlock Key", detail: "\(summary.imported) new · \(summary.updated) updated from your computers")
        }

        // 2. push: the phone's list is the truth (this is also how deletions reach the key)
        await pushVault()
    }

    private func pushVault() async {
        let items = vault.items.map(\.wire)
        let batches = items.isEmpty ? [[]] : stride(from: 0, to: items.count, by: 25).map { Array(items[$0..<min($0 + 25, items.count)]) }
        for (i, batch) in batches.enumerated() {
            var put = Message(t: Message.Kind.vaultPut)
            put.batch = i + 1
            put.totalBatches = batches.count
            put.items = batch
            guard let reply = await client.request(put, timeout: 30), reply.status == "ok" else {
                activity.add(.denied, site: "Shhlock Key", detail: "Sync stopped — the key did not answer")
                return
            }
            if i == batches.count - 1 { key.vaultCount = reply.vaultCount }
        }
        key.lastSync = Date()
    }

    private func schedulePush() {
        guard paired, key.unlocked, !key.syncing else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.pushVault()
        }
    }

    // MARK: - Pairing with the key

    func beginPairing() {
        pairing = .connecting
        client.startPairing()
    }

    func endPairing() {
        if case .paired = pairing {} else { client.cancelPairing() }
        pairing = .idle
    }

    private func pairingEvent(_ event: KeyPairingEvent) {
        switch event {
        case .waitingForButton:
            withAnimation(Theme.spring) { pairing = .pressButton }
        case .paired(let name, _):
            paired = true
            activity.add(.paired, site: name, detail: "This phone now manages the key")
            withAnimation(Theme.spring) { pairing = .paired(name) }
            Task {
                try? await Task.sleep(for: .seconds(1.2))  // let the enrol round trip finish
                await connectToKey()
            }
        case .failed(let reason):
            withAnimation(Theme.spring) { pairing = .failed(reason) }
        case .compare:
            break
        }
    }

    func forgetKey() {
        client.forgetPairing(tellKey: true)
        paired = false
        key = KeyStatus()
        activity.add(.unpaired, site: "Shhlock Key", detail: "Removed from this phone")
    }

    /// Wipes the key completely: vault, pairings, identity. The phone keeps its own copy of the vault.
    func resetKey() async {
        _ = await client.request(Message(t: Message.Kind.wipe), timeout: 10)
        client.forgetPairing(tellKey: false)
        paired = false
        key = KeyStatus()
        activity.add(.unpaired, site: "Shhlock Key", detail: "Key reset to factory state")
    }

    // MARK: - Computers

    func refreshPeers() async {
        guard let reply = await client.request(Message(t: Message.Kind.clientsList), timeout: 10) else { return }
        withAnimation(Theme.spring) { peers = (reply.clients ?? []).filter { $0.role != "phone" } }
    }

    func remove(_ peer: PeerInfo) async {
        var m = Message(t: Message.Kind.clientsRemove)
        m.target = peer.id
        _ = await client.request(m, timeout: 10)
        activity.add(.unpaired, site: peer.name, detail: "Removed from the key")
        await refreshPeers()
    }

    private func approvalArrived(_ request: ApprovalRequest) {
        withAnimation(Theme.spring) { approval = request }
        activity.add(.offered, site: request.name, detail: "Wants to pair — code \(request.code)")
        if !isForeground {
            notify(title: "\(request.name) wants to pair", body: "Open Shhlock and compare the code \(request.code).")
        }
    }

    func resolveApproval(_ ok: Bool) async {
        guard let request = approval else { return }
        if ok, !(await authenticate("Let \(request.name) use your logins")) { return }
        client.answerApproval(request, ok: ok)
        activity.add(ok ? .paired : .denied, site: request.name, detail: ok ? "Approved · code \(request.code)" : "Rejected")
        withAnimation(Theme.spring) { approval = nil }
        if ok {
            try? await Task.sleep(for: .seconds(2))
            await refreshPeers()
        }
    }

    // MARK: - Lock

    func unlock() async {
        guard isLocked else { return }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            isLocked = false
            return
        }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your vault")) ?? false
        if ok { withAnimation(.easeInOut(duration: 0.35)) { isLocked = false } }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            if let since = backgroundedAt, settings.appLock, Date().timeIntervalSince(since) > 45 { isLocked = true }
            backgroundedAt = nil
            if paired, key.connected { Task { await sync() } }
        case .background:
            isForeground = false
            backgroundedAt = backgroundedAt ?? Date()
        default:
            break
        }
    }

    func authenticate(_ reason: String) async -> Bool {
        if Self.isDemo { return true }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - Import / export

    func importCSV(_ text: String) -> ImportSummary {
        let summary = vault.merge(PasswordCSV.parse(text))
        activity.add(.imported, site: "CSV file", detail: "\(summary.imported) new · \(summary.updated) updated · \(summary.skipped) skipped")
        return summary
    }

    func exportCSV() -> String {
        func cell(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = vault.items.map { [$0.title, $0.url, $0.username, $0.password, $0.notes].map(cell).joined(separator: ",") }
        return (["name,url,username,password,note"] + rows).joined(separator: "\n") + "\n"
    }

    // MARK: - Demo

    private func seedDemo() {
        linkState.bluetooth = .on
        linkState.keyConnected = true
        linkState.rssi = -48
        paired = true
        key = KeyStatus(connected: true, unlocked: true, vaultCount: 7, lastSync: Date().addingTimeInterval(-120))
        peers = [PeerInfo(id: "a", name: "Jaydeep's MacBook Pro", role: "computer", lastCtr: nil)]
        guard vault.items.isEmpty else { return }
        vault.merge([
            WireItem(title: "GitHub", url: "https://github.com/login", username: "jaydeep@example.com", password: "vK9#mPq2-xLw7!Rt"),
            WireItem(title: "Figma", url: "https://www.figma.com/login", username: "jaydeep@example.com", password: "Tq4$hhZ8-pLm2@Wc"),
            WireItem(title: "Notion", url: "https://www.notion.so/login", username: "jaydeep@example.com", password: "bN7!rrK3-sDf9#Xp"),
            WireItem(title: "Netflix", url: "https://www.netflix.com/login", username: "family@example.com", password: "Lm2@wwQ9-zXc5$Vb"),
            WireItem(title: "AWS Console", url: "https://signin.aws.amazon.com", username: "admin-jd", password: "Hp6#ttY1-qWe8!Zn"),
            WireItem(title: "Spotify", url: "https://accounts.spotify.com", username: "jd.music", password: "Rf3$ggU7-mNb4@Kj"),
            WireItem(title: "Linear", url: "https://linear.app/login", username: "jaydeep@example.com", password: "Xc8!vvB5-lKj2#Hg"),
        ])
        activity.add(.paired, site: "Shhlock Key", detail: "This phone now manages the key")
        activity.add(.imported, site: "Chrome", detail: "7 new · 0 updated · 0 skipped")
        activity.add(.paired, site: "Jaydeep's MacBook Pro", detail: "Approved · code 482913")
        activity.add(.imported, site: "Shhlock Key", detail: "1 new · 0 updated from your computers")
    }
}

extension AppModel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
