import Foundation
import SafelyCore
import SwiftUI

/// Browsers that completed pairing. Stored encrypted, like the vault.
final class BrowserStore: ObservableObject, PairingStore {
    @Published private(set) var browsers: [PairedBrowser] = []
    private let file = SecureFile<[PairedBrowser]>(name: "browsers.bin")

    init() { browsers = file.load() ?? [] }

    func browser(keyId: Data) -> PairedBrowser? { browsers.first { $0.keyId == keyId } }

    func save(_ browser: PairedBrowser) {
        if let index = browsers.firstIndex(where: { $0.keyId == browser.keyId }) {
            browsers[index] = browser
        } else {
            browsers.append(browser)
        }
        file.save(browsers)
    }

    func remove(keyId: Data) {
        browsers.removeAll { $0.keyId == keyId }
        file.save(browsers)
    }
}

/// What happened, without any secret in it. Shown on the Activity tab.
struct ActivityEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case filled, offered, denied, saved, imported, paired, unpaired, nothingFound
    }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var site: String
    var detail: String
}

final class ActivityLog: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []
    private let file = SecureFile<[ActivityEvent]>(name: "activity.bin")
    private let limit = 300

    init() { events = file.load() ?? [] }

    func add(_ kind: ActivityEvent.Kind, site: String, detail: String) {
        events.insert(ActivityEvent(kind: kind, site: site, detail: detail), at: 0)
        if events.count > limit { events.removeLast(events.count - limit) }
        file.save(events)
    }

    func clear() {
        events = []
        file.save(events)
    }
}

enum FillPolicy: String, CaseIterable, Identifiable {
    /// Having the phone and key nearby is the approval.
    case automatic
    /// Every request needs a tap (and Face ID) on the phone.
    case ask

    var id: String { rawValue }
    var title: String { self == .automatic ? "Fill automatically" : "Ask me every time" }
    var blurb: String {
        self == .automatic
            ? "When your key and phone are near a paired browser, logins are filled without a tap."
            : "Your phone asks before any password leaves it. Approve with Face ID."
    }
}

final class AppSettings: ObservableObject {
    @AppStorage("fillPolicy") var fillPolicyRaw = FillPolicy.automatic.rawValue { willSet { objectWillChange.send() } }
    @AppStorage("notifyOnFill") var notifyOnFill = true { willSet { objectWillChange.send() } }
    @AppStorage("appLock") var appLock = true { willSet { objectWillChange.send() } }
    @AppStorage("onboarded") var onboarded = false { willSet { objectWillChange.send() } }

    var fillPolicy: FillPolicy {
        get { FillPolicy(rawValue: fillPolicyRaw) ?? .automatic }
        set { fillPolicyRaw = newValue.rawValue }
    }
}
