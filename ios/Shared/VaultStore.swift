import Foundation
import SafelyCore

/// The vault: every login, held in memory and mirrored to one encrypted file.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultItem] = []

    private let file: SecureFile<[VaultItem]>

    init(readOnly: Bool = false) {
        file = SecureFile(name: "vault.bin", canCreateKey: !readOnly)
        reload()
    }

    func reload() {
        items = (file.load() ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func matches(for origin: String) -> [VaultItem] {
        DomainMatcher.matches(for: origin, in: items)
    }

    func upsert(_ item: VaultItem) {
        var item = item
        item.updatedAt = Date()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        persist()
    }

    func delete(_ item: VaultItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func deleteAll() {
        items = []
        persist()
    }

    func markUsed(_ ids: [UUID]) {
        let now = Date()
        for index in items.indices where ids.contains(items[index].id) {
            items[index].lastUsedAt = now
            items[index].useCount += 1
        }
        persist()
    }

    @discardableResult
    func merge(_ incoming: [WireItem]) -> ImportSummary {
        let summary = items.merge(incoming)
        persist()
        return summary
    }

    private func persist() {
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        file.save(items)
    }
}
