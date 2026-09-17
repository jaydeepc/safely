import Foundation
import LocalAuthentication
import SafelyCore
import SwiftUI
import UserNotifications

/// A credential request waiting for the person's decision ("Ask me every time").
struct PendingApproval: Identifiable {
    let id: String
    let request: CredentialRequest
    let matches: [VaultItem]
    let reply: (CredentialReply) -> Void
    let receivedAt = Date()
}

enum PairingPhase: Equatable {
    case idle
    case waiting
    case compare(code: String, browser: String)
    case paired(String)
    case failed(String)
}

/// Owns the vault, the Bluetooth link and the protocol engine, and turns protocol events into UI state.
@MainActor
final class AppModel: NSObject, ObservableObject {
    let vault = VaultStore()
    let browsers = BrowserStore()
    let activity = ActivityLog()
    let settings = AppSettings()

    @Published var linkState = RelayLink.State()
    @Published var pairing: PairingPhase = .idle
    @Published var approval: PendingApproval?
    @Published var isLocked = true
    @Published var lastFill: ActivityEvent?

    static let isDemo = ProcessInfo.processInfo.arguments.contains("-SafelyDemo")

    private let link = RelayLink(role: .phone, restoreIdentifier: "com.codecrackjd.safely.central")
    private var engine: PhoneEngine!
    private var backgroundedAt: Date?
    private var isForeground = true
    private static let approveCategory = "SAFELY_APPROVE"

    override init() {
        super.init()
        engine = PhoneEngine(identity: Self.loadIdentity(), store: browsers, deviceName: UIDevice.current.name)
        engine.delegate = self
        engine.send = { [link] envelope in _ = link.send(envelope) }
        link.onMessage = { [weak self] envelope in self?.engine.receive(envelope) }
        link.onState = { [weak self] state in
            withAnimation(.spring(duration: 0.5)) { self?.linkState = state }
        }

        if Self.isDemo {
            isLocked = false
            seedDemo()
        } else {
            isLocked = settings.appLock
            link.start()
        }
        configureNotifications()
    }

    private static func loadIdentity() -> Identity {
        if let raw = Keychain.data(for: "identity"), let identity = try? Identity(rawRepresentation: raw) { return identity }
        let identity = Identity()
        Keychain.set(identity.rawRepresentation, for: "identity")
        return identity
    }

    // MARK: - Lock

    func unlock() async {
        guard isLocked else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false  // no passcode on this device: nothing to check against
            return
        }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your vault")) ?? false
        if ok { withAnimation(.spring(duration: 0.6)) { isLocked = false } }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            if let since = backgroundedAt, settings.appLock, Date().timeIntervalSince(since) > 45 { isLocked = true }
            backgroundedAt = nil
        case .background:
            isForeground = false
            backgroundedAt = backgroundedAt ?? Date()
        default:
            break
        }
    }

    /// Confirms the person's identity before something sensitive (approve, reveal, export).
    func authenticate(_ reason: String) async -> Bool {
        if Self.isDemo { return true }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    // MARK: - Pairing

    func beginPairing() {
        pairing = .waiting
        engine.pairingWindowOpen = true
    }

    func answerPairing(matches: Bool) {
        engine.confirmPairing(matches)
    }

    func endPairing() {
        engine.pairingWindowOpen = false
        pairing = .idle
    }

    func forget(_ browser: PairedBrowser) {
        engine.forget(browser)
        activity.add(.unpaired, site: browser.name, detail: "Removed from this phone")
    }

    // MARK: - Approvals

    func resolveApproval(_ allow: Bool) async {
        guard let pending = approval else { return }
        if allow, !(await authenticate("Send your login for \(DomainMatcher.host(of: pending.request.origin))")) { return }
        finish(pending, allow: allow)
    }

    private func finish(_ pending: PendingApproval, allow: Bool) {
        if approval?.id == pending.id { withAnimation(.spring(duration: 0.45)) { approval = nil } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [pending.id])
        let site = DomainMatcher.host(of: pending.request.origin)
        if allow {
            deliver(pending.matches, for: pending.request, reply: pending.reply)
        } else {
            pending.reply(.denied)
            activity.add(.denied, site: site, detail: pending.request.browser.name)
        }
    }

    private func deliver(_ matches: [VaultItem], for request: CredentialRequest, reply: (CredentialReply) -> Void) {
        reply(.items(matches))
        vault.markUsed(matches.map(\.id))
        let site = DomainMatcher.host(of: request.origin)
        let who = matches.count == 1 ? matches[0].username : "\(matches.count) logins"
        activity.add(.filled, site: site, detail: "\(who) → \(request.browser.name)")
        withAnimation(.spring(duration: 0.5)) { lastFill = activity.events.first }
        if settings.notifyOnFill, !isForeground {
            notify(id: UUID().uuidString, title: "Filled \(site)", body: "\(who) was sent to \(request.browser.name).", category: nil)
        }
    }

    // MARK: - Notifications

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approveCategory, actions: [approve, deny], intentIdentifiers: []),
        ])
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(id: String, title: String, body: String, category: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = category == nil ? nil : .default
        if let category {
            content.categoryIdentifier = category
            content.interruptionLevel = .active
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Import / export

    func importCSV(_ text: String) -> ImportSummary {
        let parsed = PasswordCSV.parse(text)
        let summary = vault.merge(parsed)
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
        linkState.peerPresent = true
        linkState.rssi = -48
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
        activity.add(.paired, site: "Chrome on macOS", detail: "Pairing code confirmed")
        activity.add(.imported, site: "Chrome", detail: "7 new · 0 updated · 0 skipped")
        activity.add(.filled, site: "figma.com", detail: "jaydeep@example.com → Chrome on macOS")
        activity.add(.filled, site: "github.com", detail: "jaydeep@example.com → Chrome on macOS")
    }
}

// MARK: - Protocol events

extension AppModel: PhoneEngineDelegate {
    nonisolated func phoneEngine(_ engine: PhoneEngine, showPairingCode code: String, browserName: String) {
        MainActor.assumeIsolated {
            withAnimation(.spring(duration: 0.5)) { pairing = .compare(code: code, browser: browserName) }
        }
    }

    nonisolated func phoneEngine(_ engine: PhoneEngine, pairingEnded result: PairingResult) {
        MainActor.assumeIsolated {
            switch result {
            case .paired(let browser):
                activity.add(.paired, site: browser.name, detail: "Pairing code confirmed")
                browsers.objectWillChange.send()
                withAnimation(.spring(duration: 0.5)) { pairing = .paired(browser.name) }
            case .failed(let reason):
                withAnimation(.spring(duration: 0.5)) { pairing = .failed(reason) }
            }
        }
    }

    nonisolated func phoneEngine(_ engine: PhoneEngine, credentialsFor request: CredentialRequest, reply: @escaping (CredentialReply) -> Void) {
        MainActor.assumeIsolated {
            let site = DomainMatcher.host(of: request.origin)
            let matches = vault.matches(for: request.origin)
            guard !matches.isEmpty else {
                reply(.items([]))
                if request.reason == "user" { activity.add(.nothingFound, site: site, detail: request.browser.name) }
                return
            }
            if settings.fillPolicy == .automatic {
                deliver(matches, for: request, reply: reply)
                return
            }

            let pending = PendingApproval(id: request.id, request: request, matches: matches, reply: reply)
            if let previous = approval { finish(previous, allow: false) }
            withAnimation(.spring(duration: 0.5)) { approval = pending }
            activity.add(.offered, site: site, detail: "Waiting for approval · \(request.browser.name)")
            if !isForeground {
                notify(id: pending.id, title: "Sign in to \(site)?", body: "\(request.browser.name) is asking for your login.", category: Self.approveCategory)
            }
            // The browser stops waiting after a minute; do not leave a stale sheet behind.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                guard let self, self.approval?.id == pending.id else { return }
                self.finish(pending, allow: false)
            }
        }
    }

    nonisolated func phoneEngine(_ engine: PhoneEngine, save item: WireItem, origin: String, from browser: PairedBrowser, reply: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            let summary = vault.merge([item])
            let site = DomainMatcher.host(of: origin)
            activity.add(.saved, site: site, detail: summary.updated > 0 ? "Password updated · \(item.username)" : "New login · \(item.username)")
            reply(true)
        }
    }

    nonisolated func phoneEngine(_ engine: PhoneEngine, importItems items: [WireItem], from browser: PairedBrowser) -> ImportSummary {
        MainActor.assumeIsolated {
            let summary = vault.merge(items)
            activity.add(.imported, site: browser.name, detail: "\(summary.imported) new · \(summary.updated) updated · \(summary.skipped) skipped")
            return summary
        }
    }

    nonisolated func phoneEngineVaultCount(_ engine: PhoneEngine) -> Int {
        MainActor.assumeIsolated { vault.items.count }
    }
}

extension AppModel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            guard let pending = approval, pending.id == id else { return }
            switch action {
            case "APPROVE": finish(pending, allow: true)  // iOS already authenticated: the action requires it
            case "DENY": finish(pending, allow: false)
            default: break  // tapped the banner: the app opens and shows the approval sheet
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
