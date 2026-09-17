import Foundation
import SafelyCore
import SwiftUI

/// What happened, without any secret in it. Shown on the Activity tab.
struct ActivityEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case filled, offered, denied, saved, imported, paired, unpaired, nothingFound, synced
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

final class AppSettings: ObservableObject {
    @AppStorage("appLock") var appLock = true { willSet { objectWillChange.send() } }
    @AppStorage("onboarded") var onboarded = false { willSet { objectWillChange.send() } }
}
