import Foundation

/// A credential as it travels between browser and phone.
public struct WireItem: Codable, Equatable {
    public var id: String?
    public var title: String
    public var url: String
    public var username: String
    public var password: String
    public var notes: String?
    /// Seconds since 1970, as kept on the key.
    public var updatedAt: Int?

    public init(id: String? = nil, title: String, url: String, username: String, password: String, notes: String? = nil, updatedAt: Int? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.username = username
        self.password = password
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

/// A device paired with the key, as the key reports it to the phone.
public struct PeerInfo: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var role: String
    public var lastCtr: Int64?

    public init(id: String, name: String, role: String, lastCtr: Int64? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.lastCtr = lastCtr
    }
}

/// One JSON shape for every message; `t` selects the meaning. See docs/PROTOCOL.md.
public struct Message: Codable {
    public enum Kind {
        // pairing, plain
        public static let pairCommit = "pair_commit"
        public static let pairPub = "pair_pub"
        public static let pairReveal = "pair_reveal"
        public static let pairCancel = "pair_cancel"
        // sealed
        public static let pairConfirm = "pair_confirm"
        public static let get = "get"
        public static let creds = "creds"
        public static let save = "save"
        public static let importBatch = "import"
        public static let ack = "ack"
        public static let ping = "ping"
        public static let pong = "pong"
        public static let unpair = "unpair"
        // v2: the key holds the vault
        public static let pairButton = "pair_button"
        public static let enroll = "enroll"
        public static let unlock = "unlock"
        public static let approve = "approve"
        public static let approveReply = "approve_reply"
        public static let vaultPull = "vault_pull"
        public static let vaultItems = "vault_items"
        public static let vaultPut = "vault_put"
        public static let clientsList = "clients_list"
        public static let clients = "clients"
        public static let clientsRemove = "clients_remove"
        public static let wipe = "wipe"
    }

    public enum Status {
        public static let ok = "ok"
        public static let none = "none"
        public static let denied = "denied"
        public static let locked = "locked"
        public static let busy = "busy"
        public static let error = "error"
    }

    public var t: String
    public var id: String?
    /// Milliseconds since 1970, strictly increasing per sender. Replay protection.
    public var ctr: Int64?
    public var name: String?
    public var commit: String?
    public var pub: String?
    public var nonce: String?
    public var origin: String?
    public var url: String?
    public var reason: String?
    public var status: String?
    public var items: [WireItem]?
    public var item: WireItem?
    public var batch: Int?
    public var totalBatches: Int?
    public var imported: Int?
    public var updated: Int?
    public var skipped: Int?
    public var vaultCount: Int?
    public var role: String?
    public var secret: String?
    public var code: String?
    public var ok: Bool?
    public var offset: Int?
    public var limit: Int?
    public var total: Int?
    public var unlocked: Bool?
    public var clients: [PeerInfo]?
    /// A paired device this message is about (approve, approve_reply, clients_remove).
    public var target: String?

    public init(t: String, id: String? = nil) {
        self.t = t
        self.id = id
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: data)
    }

    public func plainEnvelope() -> Data {
        Data([EnvelopeType.plain.rawValue]) + encoded()
    }
}

/// Strictly increasing millisecond counter, safe across restarts as long as the clock moves forward.
public final class MonotonicCounter {
    private var last: Int64 = 0
    public init() {}
    public func next() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        last = max(last + 1, now)
        return last
    }
}
