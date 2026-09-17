import Foundation

public struct VaultItem: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var url: String
    public var username: String
    public var password: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int

    public init(id: UUID = UUID(), title: String, url: String, username: String, password: String, notes: String = "",
                createdAt: Date = Date(), updatedAt: Date = Date(), lastUsedAt: Date? = nil, useCount: Int = 0) {
        self.id = id
        self.title = title
        self.url = url
        self.username = username
        self.password = password
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    public var host: String { DomainMatcher.host(of: url) }

    public var wire: WireItem {
        WireItem(id: id.uuidString, title: title, url: url, username: username, password: password, notes: notes.isEmpty ? nil : notes,
                 updatedAt: Int(updatedAt.timeIntervalSince1970))
    }
}

public struct ImportSummary: Equatable {
    public var imported = 0
    public var updated = 0
    public var skipped = 0
    public init() {}
}

/// Decides which vault items may be offered to a given web origin.
public enum DomainMatcher {
    /// Suffixes under which unrelated parties register names. Sites below them never share credentials.
    static let publicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "co.in", "net.in", "org.in", "gov.in", "ac.in", "firm.in", "gen.in", "ind.in",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "co.kr", "co.za",
        "com.br", "com.mx", "com.ar", "com.sg", "com.my", "com.hk", "com.tw", "com.cn", "com.tr", "co.id", "co.il", "co.th",
        "github.io", "gitlab.io", "herokuapp.com", "vercel.app", "netlify.app", "web.app", "firebaseapp.com", "pages.dev",
        "workers.dev", "blogspot.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "appspot.com", "onrender.com",
        "fly.dev", "glitch.me", "repl.co", "ngrok.io", "ngrok-free.app", "wordpress.com", "myshopify.com",
    ]

    public static func host(of urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let url = URL(string: trimmed), let host = url.host, url.scheme != nil {
            return normalize(host)
        }
        if let url = URL(string: "https://" + trimmed), let host = url.host {
            return normalize(host)
        }
        return normalize(trimmed)
    }

    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// The part of the host one party controls, e.g. accounts.google.com → google.com.
    public static func registrableDomain(of host: String) -> String {
        let h = normalize(host)
        if h.isEmpty || h == "localhost" || isIPAddress(h) { return h }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        for take in stride(from: min(labels.count - 1, 3), through: 2, by: -1) {
            let suffix = labels.suffix(take).joined(separator: ".")
            if publicSuffixes.contains(suffix) {
                return labels.suffix(take + 1).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Items usable on `origin`, exact host matches first, then most recently used.
    public static func matches(for origin: String, in items: [VaultItem]) -> [VaultItem] {
        let requestHost = host(of: origin)
        guard !requestHost.isEmpty else { return [] }
        let requestDomain = registrableDomain(of: requestHost)

        let scored: [(VaultItem, Int)] = items.compactMap { item in
            let itemHost = item.host
            guard !itemHost.isEmpty else { return nil }
            if itemHost == requestHost { return (item, 2) }
            if registrableDomain(of: itemHost) == requestDomain { return (item, 1) }
            return nil
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return (a.0.lastUsedAt ?? a.0.updatedAt) > (b.0.lastUsedAt ?? b.0.updatedAt)
        }.map(\.0)
    }
}

public extension Array where Element == VaultItem {
    /// Adds or updates credentials. Same host + username is the same login.
    mutating func merge(_ incoming: [WireItem]) -> ImportSummary {
        var summary = ImportSummary()
        var index: [String: Int] = [:]
        for (i, item) in enumerated() { index[Self.mergeKey(url: item.url, username: item.username)] = i }

        for wire in incoming {
            guard !wire.password.isEmpty, !wire.url.isEmpty || !wire.title.isEmpty else {
                summary.skipped += 1
                continue
            }
            let key = Self.mergeKey(url: wire.url, username: wire.username)
            if let i = index[key] {
                if self[i].password == wire.password {
                    summary.skipped += 1
                } else {
                    self[i].password = wire.password
                    self[i].updatedAt = Date()
                    summary.updated += 1
                }
            } else {
                let host = DomainMatcher.host(of: wire.url)
                let title = wire.title.isEmpty ? host : wire.title
                append(VaultItem(title: title, url: wire.url, username: wire.username, password: wire.password, notes: wire.notes ?? ""))
                index[key] = count - 1
                summary.imported += 1
            }
        }
        return summary
    }

    /// Like `merge`, but an existing login only changes when the incoming one is newer (sync from the key).
    mutating func mergeNewer(_ incoming: [WireItem]) -> ImportSummary {
        var summary = ImportSummary()
        var index: [String: Int] = [:]
        for (i, item) in enumerated() { index[Self.mergeKey(url: item.url, username: item.username)] = i }
        for wire in incoming {
            guard !wire.password.isEmpty, !wire.url.isEmpty || !wire.title.isEmpty else { summary.skipped += 1; continue }
            let key = Self.mergeKey(url: wire.url, username: wire.username)
            let incomingDate = Date(timeIntervalSince1970: TimeInterval(wire.updatedAt ?? 0))
            if let i = index[key] {
                if self[i].password != wire.password, incomingDate > self[i].updatedAt {
                    self[i].password = wire.password
                    self[i].updatedAt = incomingDate
                    summary.updated += 1
                } else {
                    summary.skipped += 1
                }
            } else {
                let host = DomainMatcher.host(of: wire.url)
                var item = VaultItem(title: wire.title.isEmpty ? host : wire.title, url: wire.url, username: wire.username, password: wire.password, notes: wire.notes ?? "")
                if wire.updatedAt != nil { item.updatedAt = incomingDate; item.createdAt = incomingDate }
                append(item)
                index[key] = count - 1
                summary.imported += 1
            }
        }
        return summary
    }

    private static func mergeKey(url: String, username: String) -> String {
        DomainMatcher.host(of: url) + "\u{1F}" + username.lowercased()
    }
}
