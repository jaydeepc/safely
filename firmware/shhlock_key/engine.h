// Shhlock protocol v2 on the key: pairing, sealed messaging, vault requests. Transport agnostic —
// the sketch supplies transmit() (BLE frames, or serial lines in the test build) and the button state.
#pragma once

#include <Preferences.h>

#include "crypto.h"
#include "vault.h"

#define KEY_NAME "Shhlock Key"
#define MAX_CLIENTS 10
#define PAIR_TIMEOUT_MS 90000
#define BUTTON_WINDOW_MS 60000

enum PeerRole : uint8_t { ROLE_PHONE = 1, ROLE_COMPUTER = 2 };

struct Peer {
  Bytes keyId;      // 8
  Bytes pub;        // 65
  Bytes wrap;       // 60: vault key sealed under HKDF(client secret); empty until enrolled
  Bytes session;    // 32, derived on load
  int64_t lastCtr = 0;
  PeerRole role = ROLE_COMPUTER;
  String name;
};

// supplied by the sketch
void transmit(uint16_t conn, const Bytes& envelope);
bool buttonWasPressed();      // true once per press
void statusChanged();

namespace engine {

static Preferences prefs;
static Bytes identityPriv, identityPub;
static std::vector<Peer> clients;
static uint32_t epochSeconds = 0;  // learned from client counters (ms since 1970)

// one reassembler per connection
struct Link {
  uint16_t conn = 0;
  bool used = false;
  uint8_t curMsg = 0, total = 0, got = 0;
  Bytes buffer;
  Bytes clientKeyId;  // who talked last on this link
  uint8_t nextMsgId = 0;
};
static Link links[6];

struct Pending {
  bool active = false;
  uint16_t conn = 0;
  uint32_t startedAt = 0;
  PeerRole role = ROLE_COMPUTER;
  String name;
  Bytes commit, clientPub, nonce, session, keyId;
  String sas;
  enum { WAIT_BUTTON, WAIT_REVEAL, WAIT_APPROVAL } stage = WAIT_REVEAL;
};
static Pending pending;

static const Bytes SESSION_SALT = crypto::bytes("shhlock/v2/session");
static const Bytes COMMIT_LABEL = crypto::bytes("shhlock/v2/commit");
static const Bytes SAS_LABEL = crypto::bytes("shhlock/v2/sas");
static const Bytes WRAP_SALT = crypto::bytes("shhlock/v2/wrap");

// ── helpers ──

inline Link* link(uint16_t conn, bool create) {
  Link* free_ = nullptr;
  for (Link& l : links) {
    if (l.used && l.conn == conn) return &l;
    if (!l.used && !free_) free_ = &l;
  }
  if (create && free_) {
    *free_ = Link();
    free_->used = true;
    free_->conn = conn;
    return free_;
  }
  return nullptr;
}

inline void linkClosed(uint16_t conn) {
  if (Link* l = link(conn, false)) l->used = false;
  if (pending.active && pending.conn == conn) pending.active = false;
}

inline Peer* peerById(const Bytes& keyId) {
  for (Peer& c : clients) if (c.keyId == keyId) return &c;
  return nullptr;
}

inline Bytes keyIdOf(const Bytes& clientPub) {
  Bytes h = crypto::sha256(clientPub);
  return Bytes(h.begin(), h.begin() + 8);
}

inline Bytes sessionKeyFor(const Bytes& clientPub) {
  Bytes shared;
  if (!crypto::ecdh(identityPriv, clientPub, shared)) return Bytes();
  return crypto::hkdf(shared, SESSION_SALT, crypto::cat(clientPub, identityPub));
}

inline String sasFor(const Bytes& clientPub, const Bytes& nonce) {
  Bytes h = crypto::sha256(crypto::cat(crypto::cat(SAS_LABEL, clientPub), crypto::cat(identityPub, nonce)));
  uint32_t v = (uint32_t)h[0] << 24 | (uint32_t)h[1] << 16 | (uint32_t)h[2] << 8 | h[3];
  char buf[8];
  snprintf(buf, sizeof buf, "%06lu", (unsigned long)(v % 1000000UL));
  return String(buf);
}

inline Bytes wrapKeyFor(const Bytes& secret, const Bytes& keyId) { return crypto::hkdf(secret, WRAP_SALT, keyId); }

inline uint16_t phoneConn() {
  for (Link& l : links) {
    if (!l.used || l.clientKeyId.empty()) continue;
    Peer* c = peerById(l.clientKeyId);
    if (c && c->role == ROLE_PHONE) return l.conn;
  }
  return 0xFFFF;
}

// ── persistence ──

inline void saveClients() {
  JsonDocument doc;
  JsonArray arr = doc.to<JsonArray>();
  for (Peer& c : clients) {
    JsonObject o = arr.add<JsonObject>();
    o["id"] = crypto::b64encode(c.keyId);
    o["pub"] = crypto::b64encode(c.pub);
    o["wrap"] = crypto::b64encode(c.wrap);
    o["ctr"] = c.lastCtr;
    o["role"] = (int)c.role;
    o["name"] = c.name;
  }
  String json;
  serializeJson(doc, json);
  prefs.putBytes("clients", json.c_str(), json.length());
}

inline void loadClients() {
  clients.clear();
  size_t len = prefs.getBytesLength("clients");
  if (!len) return;
  Bytes raw(len);
  prefs.getBytes("clients", raw.data(), len);
  JsonDocument doc;
  if (deserializeJson(doc, raw.data(), raw.size()) != DeserializationError::Ok) return;
  for (JsonObjectConst o : doc.as<JsonArrayConst>()) {
    Peer c;
    c.keyId = crypto::b64decode(o["id"] | "");
    c.pub = crypto::b64decode(o["pub"] | "");
    c.wrap = crypto::b64decode(o["wrap"] | "");
    c.lastCtr = o["ctr"] | 0LL;
    c.role = (PeerRole)(o["role"] | 2);
    c.name = o["name"] | "";
    c.session = sessionKeyFor(c.pub);
    if (c.keyId.size() == 8 && c.pub.size() == 65 && !c.session.empty()) clients.push_back(c);
  }
}

inline void begin() {
  prefs.begin("shhlock", false);
  size_t n = prefs.getBytesLength("idpriv");
  if (n == 32) {
    identityPriv.assign(32, 0);
    prefs.getBytes("idpriv", identityPriv.data(), 32);
    // rebuild the public key from the private one
    Bytes shared;
    mbedtls_ecp_group grp;
    mbedtls_mpi d;
    mbedtls_ecp_point Q;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_ecp_point_init(&Q);
    mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1);
    mbedtls_mpi_read_binary(&d, identityPriv.data(), 32);
    mbedtls_ecp_mul(&grp, &Q, &d, &grp.G, crypto::rng, nullptr);
    identityPub.assign(65, 0);
    size_t olen = 0;
    mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED, &olen, identityPub.data(), 65);
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
  } else {
    crypto::generateKeyPair(identityPriv, identityPub);
    prefs.putBytes("idpriv", identityPriv.data(), 32);
  }
  loadClients();
}

inline void factoryReset() {
  vault::wipe();
  clients.clear();
  prefs.clear();
  crypto::generateKeyPair(identityPriv, identityPub);
  prefs.putBytes("idpriv", identityPriv.data(), 32);
}

// ── sending ──

inline void sendPlain(uint16_t conn, JsonDocument& doc) {
  String json;
  serializeJson(doc, json);
  Bytes env;
  env.push_back(0x01);
  env.insert(env.end(), json.begin(), json.end());
  transmit(conn, env);
}

inline void cancel(uint16_t conn, const char* reason) {
  JsonDocument doc;
  doc["t"] = "pair_cancel";
  doc["reason"] = reason;
  sendPlain(conn, doc);
}

inline int64_t nextCtr() {
  static int64_t last = 0;
  int64_t now = (int64_t)epochSeconds * 1000 + (millis() % 1000);
  last = std::max(last + 1, now);
  return last;
}

inline void sendSealed(uint16_t conn, const Peer& client, JsonDocument& doc) {
  doc["ctr"] = nextCtr();
  Bytes header;
  header.push_back(0x02);
  header.insert(header.end(), client.keyId.begin(), client.keyId.end());
  Bytes body(measureJson(doc));
  serializeJson(doc, (char*)body.data(), body.size());
  if (!crypto::gcmSealInPlace(client.session, body, header)) return;
  body.insert(body.begin(), header.begin(), header.end());
  transmit(conn, body);
}

inline void sendSealedTo(uint16_t conn, const Bytes& keyId, JsonDocument& doc) {
  if (Peer* c = peerById(keyId)) sendSealed(conn, *c, doc);
}

// ── pairing ──

inline void finishPairing() {
  Peer c;
  c.keyId = pending.keyId;
  c.pub = pending.clientPub;
  c.session = pending.session;
  c.role = pending.role;
  c.name = pending.name;
  c.lastCtr = 0;
  for (size_t i = 0; i < clients.size(); i++) if (clients[i].keyId == c.keyId) clients.erase(clients.begin() + i--);
  if (clients.size() >= MAX_CLIENTS) clients.erase(clients.begin());
  clients.push_back(c);
  saveClients();
  if (Link* l = link(pending.conn, false)) l->clientKeyId = c.keyId;

  JsonDocument doc;
  doc["t"] = "pair_confirm";
  doc["name"] = KEY_NAME;
  doc["vaultCount"] = (int)vault::items.size();
  doc["unlocked"] = vault::unlocked();
  sendSealed(pending.conn, c, doc);
  pending.active = false;
  Serial.printf("[pair] %s paired (%s)\n", c.name.c_str(), c.role == ROLE_PHONE ? "phone" : "computer");
  statusChanged();
}

inline void handlePlain(uint16_t conn, JsonDocument& msg) {
  const char* t = msg["t"] | "";
  if (!strcmp(t, "pair_commit")) {
    Bytes commit = crypto::b64decode(msg["commit"] | "");
    if (commit.size() != 32) return;
    if (pending.active && millis() - pending.startedAt < PAIR_TIMEOUT_MS && pending.conn != conn) {
      cancel(conn, "Another device is pairing right now. Try again in a minute.");
      return;
    }
    pending = Pending();
    pending.active = true;
    pending.conn = conn;
    pending.startedAt = millis();
    pending.commit = commit;
    pending.name = String(msg["name"] | "Device").substring(0, 60);
    pending.role = strcmp(msg["role"] | "computer", "phone") == 0 ? ROLE_PHONE : ROLE_COMPUTER;
    if (pending.role == ROLE_COMPUTER && phoneConn() == 0xFFFF) {
      pending.active = false;
      cancel(conn, "Open Shhlock on your phone first — it approves new computers.");
      return;
    }
    if (pending.role == ROLE_PHONE) {
      // A phone proves it is near the key by pressing the key's button.
      pending.stage = Pending::WAIT_BUTTON;
      buttonWasPressed();  // clear any stale press
      JsonDocument doc;
      doc["t"] = "pair_button";
      doc["reason"] = "Press the button on your Shhlock Key.";
      sendPlain(conn, doc);
      statusChanged();
      return;
    }
    pending.stage = Pending::WAIT_REVEAL;
    JsonDocument doc;
    doc["t"] = "pair_pub";
    doc["pub"] = crypto::b64encode(identityPub);
    doc["name"] = KEY_NAME;
    sendPlain(conn, doc);

  } else if (!strcmp(t, "pair_reveal")) {
    if (!pending.active || pending.conn != conn || pending.stage != Pending::WAIT_REVEAL) return;
    Bytes pub = crypto::b64decode(msg["pub"] | "");
    Bytes nonce = crypto::b64decode(msg["nonce"] | "");
    if (pub.size() != 65 || nonce.empty() || crypto::sha256(crypto::cat(crypto::cat(COMMIT_LABEL, pub), nonce)) != pending.commit) {
      pending.active = false;
      cancel(conn, "The device's key did not match its commitment.");
      return;
    }
    pending.clientPub = pub;
    pending.nonce = nonce;
    pending.session = sessionKeyFor(pub);
    pending.keyId = keyIdOf(pub);
    pending.sas = sasFor(pub, nonce);
    if (pending.session.empty()) {
      pending.active = false;
      cancel(conn, "Key agreement failed.");
      return;
    }
    if (pending.role == ROLE_PHONE) {
      finishPairing();  // the button press was the proof
      return;
    }
    uint16_t phone = phoneConn();
    if (phone == 0xFFFF) {
      pending.active = false;
      cancel(conn, "Your phone went away before it could approve this computer.");
      return;
    }
    pending.stage = Pending::WAIT_APPROVAL;
    JsonDocument doc;
    doc["t"] = "approve";
    doc["target"] = crypto::b64encode(pending.keyId);
    doc["code"] = pending.sas;
    doc["name"] = pending.name;
    Link* pl = link(phone, false);
    if (pl) sendSealedTo(phone, pl->clientKeyId, doc);

  } else if (!strcmp(t, "pair_cancel")) {
    if (pending.active && pending.conn == conn) pending.active = false;
  }
}

// ── sealed messages ──

inline void reply(uint16_t conn, const Peer& c, JsonDocument& doc, const char* id) {
  if (id && *id) doc["id"] = id;
  sendSealed(conn, c, doc);
}

inline void handleSealed(uint16_t conn, Peer& c, JsonDocument& msg) {
  const char* t = msg["t"] | "";
  const char* id = msg["id"] | "";
  JsonDocument out;

  if (!strcmp(t, "ping")) {
    out["t"] = "pong";
    out["name"] = KEY_NAME;
    out["vaultCount"] = (int)vault::items.size();
    out["unlocked"] = vault::unlocked();
    reply(conn, c, out, id);
    return;
  }

  if (!strcmp(t, "enroll")) {
    // First sealed message after pairing: the client hands over the secret that wraps the vault key.
    Bytes secret = crypto::b64decode(msg["secret"] | "");
    out["t"] = "ack";
    if (secret.size() != 32) {
      out["status"] = "error";
    } else {
      if (!vault::unlocked() && clients.size() == 1 && c.role == ROLE_PHONE) {
        vault::unlock(crypto::randomBytes(32));  // brand new key: mint the vault key now
        vault::save();
      }
      if (!vault::unlocked()) {
        out["status"] = "locked";
      } else {
        c.wrap = crypto::gcmSeal(wrapKeyFor(secret, c.keyId), vault::key, c.keyId);
        saveClients();
        out["status"] = "ok";
        out["vaultCount"] = (int)vault::items.size();
      }
    }
    reply(conn, c, out, id);
    statusChanged();
    return;
  }

  if (!strcmp(t, "unlock")) {
    Bytes secret = crypto::b64decode(msg["secret"] | "");
    out["t"] = "ack";
    if (vault::unlocked()) {
      out["status"] = "ok";
    } else {
      Bytes vaultKey;
      if (secret.size() == 32 && !c.wrap.empty() && crypto::gcmOpen(wrapKeyFor(secret, c.keyId), c.wrap, c.keyId, vaultKey) && vault::unlock(vaultKey)) {
        out["status"] = "ok";
        Serial.printf("[vault] unlocked by %s: %u logins\n", c.name.c_str(), (unsigned)vault::items.size());
      } else {
        out["status"] = "denied";
      }
    }
    out["vaultCount"] = (int)vault::items.size();
    reply(conn, c, out, id);
    statusChanged();
    return;
  }

  if (!strcmp(t, "unpair")) {
    for (size_t i = 0; i < clients.size(); i++) if (clients[i].keyId == c.keyId) clients.erase(clients.begin() + i--);
    saveClients();
    statusChanged();
    return;
  }

  if (!vault::unlocked()) {
    out["t"] = !strcmp(t, "get") ? "creds" : "ack";
    out["status"] = "locked";
    reply(conn, c, out, id);
    return;
  }

  if (!strcmp(t, "get")) {
    String origin = msg["origin"] | "";
    auto found = vault::matches(origin);
    out["t"] = "creds";
    out["status"] = found.empty() ? "none" : "ok";
    JsonArray arr = out["items"].to<JsonArray>();
    for (const Item* item : found) vault::itemToJson(*item, arr.add<JsonObject>(), false);
    reply(conn, c, out, id);
    Serial.printf("[get] %s → %u for %s\n", vault::hostOf(origin).c_str(), (unsigned)found.size(), c.name.c_str());

  } else if (!strcmp(t, "save") || !strcmp(t, "import")) {
    std::vector<Item> incoming;
    if (msg["item"].is<JsonObjectConst>()) incoming.push_back(vault::itemFromJson(msg["item"].as<JsonObjectConst>()));
    for (JsonObjectConst o : msg["items"].as<JsonArrayConst>()) incoming.push_back(vault::itemFromJson(o));
    vault::MergeSummary s = vault::merge(incoming, epochSeconds);
    bool last = !strcmp(t, "save") || (int)(msg["batch"] | 1) >= (int)(msg["totalBatches"] | 1);
    if (last && vault::dirty) vault::save();
    out["t"] = "ack";
    out["status"] = "ok";
    out["batch"] = msg["batch"] | 1;
    out["imported"] = s.imported;
    out["updated"] = s.updated;
    out["skipped"] = s.skipped;
    out["vaultCount"] = (int)vault::items.size();
    reply(conn, c, out, id);

  } else if (!strcmp(t, "vault_pull")) {  // phone: read the vault back in pages
    int offset = msg["offset"] | 0, limit = msg["limit"] | 25;
    out["t"] = "vault_items";
    out["offset"] = offset;
    out["total"] = (int)vault::items.size();
    JsonArray arr = out["items"].to<JsonArray>();
    for (int i = offset; i < (int)vault::items.size() && i < offset + limit; i++) vault::itemToJson(vault::items[i], arr.add<JsonObject>(), true);
    reply(conn, c, out, id);

  } else if (!strcmp(t, "vault_put")) {  // phone: replace the whole vault, in batches
    static std::vector<Item> staging;
    int batch = msg["batch"] | 1, total = msg["totalBatches"] | 1;
    if (batch == 1) staging.clear();
    for (JsonObjectConst o : msg["items"].as<JsonArrayConst>()) staging.push_back(vault::itemFromJson(o));
    out["t"] = "ack";
    out["status"] = "ok";
    out["batch"] = batch;
    if (batch >= total) {
      vault::items.swap(staging);
      staging.clear();
      staging.shrink_to_fit();
      vault::dirty = true;
      out["status"] = vault::save() ? "ok" : "error";
      Serial.printf("[vault] replaced: %u logins\n", (unsigned)vault::items.size());
    }
    out["vaultCount"] = (int)vault::items.size();
    reply(conn, c, out, id);

  } else if (!strcmp(t, "approve_reply") && c.role == ROLE_PHONE) {
    Bytes target = crypto::b64decode(msg["target"] | "");
    if (pending.active && pending.stage == Pending::WAIT_APPROVAL && pending.keyId == target) {
      if (msg["ok"] | false) finishPairing();
      else {
        cancel(pending.conn, "Rejected on the phone.");
        pending.active = false;
      }
    }

  } else if (!strcmp(t, "clients_list") && c.role == ROLE_PHONE) {
    out["t"] = "clients";
    JsonArray arr = out["clients"].to<JsonArray>();
    for (Peer& cl : clients) {
      JsonObject o = arr.add<JsonObject>();
      o["id"] = crypto::b64encode(cl.keyId);
      o["name"] = cl.name;
      o["role"] = cl.role == ROLE_PHONE ? "phone" : "computer";
      o["lastCtr"] = cl.lastCtr;
    }
    reply(conn, c, out, id);

  } else if (!strcmp(t, "clients_remove") && c.role == ROLE_PHONE) {
    Bytes target = crypto::b64decode(msg["target"] | "");
    for (size_t i = 0; i < clients.size(); i++) if (clients[i].keyId == target && clients[i].keyId != c.keyId) clients.erase(clients.begin() + i--);
    saveClients();
    out["t"] = "ack";
    out["status"] = "ok";
    reply(conn, c, out, id);

  } else if (!strcmp(t, "wipe") && c.role == ROLE_PHONE) {
    out["t"] = "ack";
    out["status"] = "ok";
    reply(conn, c, out, id);
    factoryReset();
    statusChanged();
  }
}

// ── entry: a complete envelope arrived on a connection ──

inline void receive(uint16_t conn, const Bytes& env) {
  if (env.empty()) return;
  if (env[0] == 0x01) {
    JsonDocument doc;
    if (deserializeJson(doc, env.data() + 1, env.size() - 1) == DeserializationError::Ok) handlePlain(conn, doc);
    return;
  }
  if (env[0] != 0x02 || env.size() < 9 + 28) return;
  Bytes keyId(env.begin() + 1, env.begin() + 9);
  Peer* c = peerById(keyId);
  if (!c) return;
  Bytes header(env.begin(), env.begin() + 9);
  Bytes plain(env.begin() + 9, env.end());
  if (!crypto::gcmOpenInPlace(c->session, plain, header)) return;
  plain.push_back(0);
  JsonDocument doc;
  if (deserializeJson(doc, (char*)plain.data()) != DeserializationError::Ok) return;  // zero-copy parse
  int64_t ctr = doc["ctr"] | 0LL;
  if (ctr <= c->lastCtr) return;  // replay
  c->lastCtr = ctr;
  if (ctr / 1000 > epochSeconds) epochSeconds = ctr / 1000;
  if (Link* l = link(conn, true)) l->clientKeyId = keyId;
  handleSealed(conn, *c, doc);
  static uint32_t lastPersist = 0;
  if (millis() - lastPersist > 30000) {  // remember counters now and then; a reboot costs at most 30 s of replay window
    saveClients();
    lastPersist = millis();
  }
}

/// Frame in: [msgId][index][total] + payload. Returns true when a whole envelope was handled.
inline void frameIn(uint16_t conn, const uint8_t* data, size_t len) {
  if (len < 3) return;
  Link* l = link(conn, true);
  if (!l) return;
  uint8_t msgId = data[0], index = data[1], total = data[2];
  if (!total || index >= total) return;
  if (index == 0 || l->curMsg != msgId || l->total != total) {
    l->curMsg = msgId;
    l->total = total;
    l->got = 0;
    l->buffer.clear();
  }
  if (index != l->got) { l->got = 0; l->buffer.clear(); return; }  // out of order: drop
  l->buffer.insert(l->buffer.end(), data + 3, data + len);
  l->got++;
  if (l->got == total) {
    Bytes env;
    env.swap(l->buffer);
    l->got = 0;
    receive(conn, env);
  }
}

inline void tick() {
  if (pending.active && millis() - pending.startedAt > PAIR_TIMEOUT_MS) {
    cancel(pending.conn, "Pairing timed out.");
    pending.active = false;
    statusChanged();
  }
  if (pending.active && pending.stage == Pending::WAIT_BUTTON && buttonWasPressed()) {
    pending.stage = Pending::WAIT_REVEAL;
    JsonDocument doc;
    doc["t"] = "pair_pub";
    doc["pub"] = crypto::b64encode(identityPub);
    doc["name"] = KEY_NAME;
    sendPlain(pending.conn, doc);
    statusChanged();
  }
}

inline bool pairingWaitsForButton() { return pending.active && pending.stage == Pending::WAIT_BUTTON; }

}  // namespace engine
