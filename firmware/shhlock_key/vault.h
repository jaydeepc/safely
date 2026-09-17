// The vault: logins held in RAM while unlocked, stored as one AES-256-GCM sealed file on LittleFS.
// Domain matching follows the same rules as the phone app (DomainMatcher in SafelyCore).
#pragma once

#include <ArduinoJson.h>
#include <LittleFS.h>

#include <algorithm>

#include "crypto.h"

struct Item {
  String id, title, url, username, password, notes;
  uint32_t updatedAt = 0;  // seconds since 1970 as known by the phone; 0 = unknown
};

namespace vault {

static const char* FILE_PATH = "/vault.bin";

/// One encrypted record per login on LittleFS; only this index lives in RAM (~40 bytes per login),
/// so a vault of a thousand logins fits the ESP32's memory.
struct Entry {
  uint32_t offset;     // where the record starts in the file
  uint32_t updatedAt;
  String host;         // normalised, for matching
  String user;         // lower-cased, for de-duplication
  bool deleted;        // superseded by a later record; cleaned up at the next full sync
};

static const char* AAD_RECORD = "shhlock/v2/rec";
static const uint8_t RECORD_MAGIC = 0xA5;

static std::vector<Entry> index_;
static Bytes key;         // 32 bytes while unlocked, empty while locked
static bool dirty = false;

inline bool unlocked() { return key.size() == 32; }
inline size_t count() {
  size_t n = 0;
  for (const Entry& e : index_) if (!e.deleted) n++;
  return n;
}

// ── domain matching ──

static const char* PUBLIC_SUFFIXES[] = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "co.in", "net.in", "org.in", "gov.in", "ac.in", "firm.in", "gen.in", "ind.in",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "co.kr", "co.za",
    "com.br", "com.mx", "com.ar", "com.sg", "com.my", "com.hk", "com.tw", "com.cn", "com.tr", "co.id", "co.il", "co.th",
    "github.io", "gitlab.io", "herokuapp.com", "vercel.app", "netlify.app", "web.app", "firebaseapp.com", "pages.dev",
    "workers.dev", "blogspot.com", "azurewebsites.net", "cloudfront.net", "amazonaws.com", "appspot.com", "onrender.com",
    "fly.dev", "glitch.me", "repl.co", "ngrok.io", "ngrok-free.app", "wordpress.com", "myshopify.com"};

inline String hostOf(String url) {
  url.trim();
  int scheme = url.indexOf("://");
  if (scheme >= 0) url = url.substring(scheme + 3);
  int at = url.indexOf('@');
  int slash = url.indexOf('/');
  if (at >= 0 && (slash < 0 || at < slash)) url = url.substring(at + 1);
  for (char stop : {'/', '?', '#', ':'}) {
    int i = url.indexOf(stop);
    if (i >= 0) url = url.substring(0, i);
  }
  url.toLowerCase();
  if (url.startsWith("www.")) url = url.substring(4);
  return url;
}

inline bool isIPAddress(const String& h) {
  if (h.indexOf(':') >= 0) return true;
  int dots = 0;
  for (char c : h) {
    if (c == '.') dots++;
    else if (!isDigit(c)) return false;
  }
  return dots == 3;
}

inline String registrableDomain(const String& host) {
  if (host.isEmpty() || host == "localhost" || isIPAddress(host)) return host;
  std::vector<String> labels;
  int start = 0;
  for (int i = 0; i <= (int)host.length(); i++) {
    if (i == (int)host.length() || host[i] == '.') {
      labels.push_back(host.substring(start, i));
      start = i + 1;
    }
  }
  if (labels.size() <= 2) return host;
  auto suffix = [&](size_t take) {
    String s;
    for (size_t i = labels.size() - take; i < labels.size(); i++) {
      if (!s.isEmpty()) s += '.';
      s += labels[i];
    }
    return s;
  };
  for (size_t take = std::min(labels.size() - 1, (size_t)3); take >= 2; take--) {
    String s = suffix(take);
    for (const char* ps : PUBLIC_SUFFIXES) {
      if (s == ps) return suffix(take + 1);
    }
  }
  return suffix(2);
}

// ── merge helpers ──

struct MergeSummary {
  int imported = 0, updated = 0, skipped = 0;
};

inline String mergeKey(const Item& item) {
  String u = item.username;
  u.toLowerCase();
  return hostOf(item.url) + "\x1f" + u;
}

inline String newId() {
  Bytes r = crypto::randomBytes(16);
  static const char* H = "0123456789abcdef";
  String s;
  for (int i = 0; i < 16; i++) {
    s += H[r[i] >> 4];
    s += H[r[i] & 15];
    if (i == 3 || i == 5 || i == 7 || i == 9) s += '-';
  }
  s.toUpperCase();
  return s;
}

// ── JSON (de)serialisation shared with the wire format ──

inline void itemToJson(const Item& item, JsonObject o, bool withNotes) {
  o["id"] = item.id;
  o["title"] = item.title;
  o["url"] = item.url;
  o["username"] = item.username;
  o["password"] = item.password;
  if (withNotes && !item.notes.isEmpty()) o["notes"] = item.notes;
  if (item.updatedAt) o["updatedAt"] = item.updatedAt;
}

inline Item itemFromJson(JsonObjectConst o) {
  Item item;
  item.id = o["id"] | "";
  item.title = o["title"] | "";
  item.url = o["url"] | "";
  item.username = o["username"] | "";
  item.password = o["password"] | "";
  item.notes = o["notes"] | "";
  item.updatedAt = o["updatedAt"] | 0;
  return item;
}

// Streams the vault to JSON without an intermediate document, escaping as it goes.
inline void appendEscaped(Bytes& out, const String& s) {
  out.push_back('"');
  for (size_t i = 0; i < s.length(); i++) {
    unsigned char c = s[i];
    switch (c) {
      case '"': out.push_back('\\'); out.push_back('"'); break;
      case '\\': out.push_back('\\'); out.push_back('\\'); break;
      case '\n': out.push_back('\\'); out.push_back('n'); break;
      case '\r': out.push_back('\\'); out.push_back('r'); break;
      case '\t': out.push_back('\\'); out.push_back('t'); break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof buf, "\\u%04x", c);
          for (char* p = buf; *p; p++) out.push_back(*p);
        } else {
          out.push_back(c);
        }
    }
  }
  out.push_back('"');
}

inline void appendField(Bytes& out, const char* name, const String& value, bool& first) {
  if (!first) out.push_back(',');
  first = false;
  appendEscaped(out, String(name));
  out.push_back(':');
  appendEscaped(out, value);
}

// ── records on flash ──

inline bool begin() { return LittleFS.begin(true); }

inline String userKey(const String& username) {
  String u = username;
  u.toLowerCase();
  return u;
}

/// Serialises one item to JSON bytes (no intermediate document).
inline Bytes encodeItem(const Item& it) {
  Bytes buf;
  buf.reserve(80 + it.id.length() + it.title.length() + it.url.length() + it.username.length() + it.password.length() + it.notes.length());
  buf.push_back('{');
  bool first = true;
  appendField(buf, "id", it.id, first);
  appendField(buf, "title", it.title, first);
  appendField(buf, "url", it.url, first);
  appendField(buf, "username", it.username, first);
  appendField(buf, "password", it.password, first);
  if (!it.notes.isEmpty()) appendField(buf, "notes", it.notes, first);
  if (it.updatedAt) {
    char num[24];
    snprintf(num, sizeof num, ",\"updatedAt\":%lu", (unsigned long)it.updatedAt);
    for (char* p = num; *p; p++) buf.push_back(*p);
  }
  buf.push_back('}');
  return buf;
}

/// Appends one sealed record; returns its offset or -1.
inline int32_t appendRecord(const Item& it) {
  if (!unlocked()) return -1;
  Bytes buf = encodeItem(it);
  if (!crypto::gcmSealInPlace(key, buf, crypto::bytes(AAD_RECORD))) return -1;
  File f = LittleFS.open(FILE_PATH, "a");
  if (!f) return -1;
  int32_t offset = f.size();
  uint8_t header[3] = {RECORD_MAGIC, (uint8_t)(buf.size() & 0xFF), (uint8_t)(buf.size() >> 8)};
  bool ok = f.write(header, 3) == 3 && f.write(buf.data(), buf.size()) == buf.size();
  f.close();
  return ok ? offset : -1;
}

/// Reads and decrypts the record at `offset`.
inline bool readRecord(File& f, uint32_t offset, Item& out) {
  if (!f.seek(offset)) return false;
  uint8_t header[3];
  if (f.read(header, 3) != 3 || header[0] != RECORD_MAGIC) return false;
  size_t len = header[1] | (header[2] << 8);
  Bytes buf(len);
  if (f.read(buf.data(), len) != len) return false;
  if (!crypto::gcmOpenInPlace(key, buf, crypto::bytes(AAD_RECORD))) return false;
  buf.push_back(0);
  JsonDocument doc;
  if (deserializeJson(doc, (char*)buf.data()) != DeserializationError::Ok) return false;
  out = itemFromJson(doc.as<JsonObjectConst>());
  return true;
}

inline bool readRecord(uint32_t offset, Item& out) {
  File f = LittleFS.open(FILE_PATH, "r");
  if (!f) return false;
  bool ok = readRecord(f, offset, out);
  f.close();
  return ok;
}

inline void indexAdd(const Item& it, uint32_t offset) {
  String host = hostOf(it.url), user = userKey(it.username);
  for (Entry& e : index_) if (!e.deleted && e.host == host && e.user == user) e.deleted = true;  // superseded
  index_.push_back(Entry{offset, it.updatedAt, host, user, false});
}

/// Builds the index by walking the file. Records that fail to open are skipped.
inline bool unlock(const Bytes& vaultKey) {
  if (vaultKey.size() != 32) return false;
  index_.clear();
  key = vaultKey;
  if (!LittleFS.exists(FILE_PATH)) return true;
  File f = LittleFS.open(FILE_PATH, "r");
  if (!f) { key.clear(); return false; }
  uint32_t offset = 0, size = f.size();
  bool any = false, bad = false;
  while (offset + 3 <= size) {
    Item it;
    if (!readRecord(f, offset, it)) { bad = true; break; }
    indexAdd(it, offset);
    any = true;
    uint8_t header[3];
    f.seek(offset);
    f.read(header, 3);
    offset += 3 + (header[1] | (header[2] << 8));
  }
  f.close();
  if (bad && !any) { key.clear(); index_.clear(); return false; }  // wrong key for this vault
  return true;
}

inline void lock() {
  index_.clear();
  key.clear();
}

inline void wipe() {
  lock();
  LittleFS.remove(FILE_PATH);
}

/// Starts a full replacement (phone sync): the file is rewritten from scratch.
inline void beginReplace() {
  index_.clear();
  LittleFS.remove(FILE_PATH);
}

/// Items usable on `origin`: exact host first, then same registrable domain; newest first.
inline std::vector<Item> matches(const String& origin) {
  std::vector<Item> out;
  String host = hostOf(origin);
  if (host.isEmpty() || !unlocked()) return out;
  String domain = registrableDomain(host);
  std::vector<std::pair<const Entry*, int>> scored;
  for (const Entry& e : index_) {
    if (e.deleted || e.host.isEmpty()) continue;
    if (e.host == host) scored.push_back({&e, 2});
    else if (registrableDomain(e.host) == domain) scored.push_back({&e, 1});
  }
  std::stable_sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
    if (a.second != b.second) return a.second > b.second;
    return a.first->updatedAt > b.first->updatedAt;
  });
  File f = LittleFS.open(FILE_PATH, "r");
  if (!f) return out;
  for (auto& s : scored) {
    Item it;
    if (readRecord(f, s.first->offset, it)) out.push_back(it);
    if (out.size() >= 12) break;
  }
  f.close();
  return out;
}

/// The n-th live item (for paging the vault back to the phone).
inline bool itemAt(size_t n, Item& out) {
  size_t seen = 0;
  for (const Entry& e : index_) {
    if (e.deleted) continue;
    if (seen++ == n) return readRecord(e.offset, out);
  }
  return false;
}

inline MergeSummary merge(const std::vector<Item>& incoming, uint32_t now) {
  MergeSummary summary;
  for (const Item& in : incoming) {
    if (in.password.isEmpty() || (in.url.isEmpty() && in.title.isEmpty())) { summary.skipped++; continue; }
    String host = hostOf(in.url), user = userKey(in.username);
    Entry* existing = nullptr;
    for (Entry& e : index_) if (!e.deleted && e.host == host && e.user == user) { existing = &e; break; }
    Item item = in;
    if (existing) {
      Item old;
      if (readRecord(existing->offset, old) && old.password == in.password) { summary.skipped++; continue; }
      if (item.id.isEmpty()) item.id = old.id;
      if (item.title.isEmpty()) item.title = old.title;
      item.updatedAt = now;
      summary.updated++;
    } else {
      if (item.id.isEmpty()) item.id = newId();
      if (item.title.isEmpty()) item.title = host;
      if (!item.updatedAt) item.updatedAt = now;
      summary.imported++;
    }
    int32_t offset = appendRecord(item);
    if (offset >= 0) indexAdd(item, offset);
  }
  return summary;
}

}  // namespace vault
