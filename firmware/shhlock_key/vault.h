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
static const char* AAD = "shhlock/v2/vault";

static std::vector<Item> items;
static Bytes key;         // 32 bytes while unlocked, empty while locked
static bool dirty = false;

inline bool unlocked() { return key.size() == 32; }

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

/// Items usable on `origin`: exact host first, then same registrable domain; newest first within each group.
inline std::vector<const Item*> matches(const String& origin) {
  std::vector<std::pair<const Item*, int>> scored;
  String host = hostOf(origin);
  if (host.isEmpty()) return {};
  String domain = registrableDomain(host);
  for (const Item& item : items) {
    String ih = hostOf(item.url);
    if (ih.isEmpty()) continue;
    if (ih == host) scored.push_back({&item, 2});
    else if (registrableDomain(ih) == domain) scored.push_back({&item, 1});
  }
  std::stable_sort(scored.begin(), scored.end(), [](const auto& a, const auto& b) {
    if (a.second != b.second) return a.second > b.second;
    return a.first->updatedAt > b.first->updatedAt;
  });
  std::vector<const Item*> out;
  for (auto& s : scored) out.push_back(s.first);
  return out;
}

// ── merge ──

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

inline MergeSummary merge(const std::vector<Item>& incoming, uint32_t now) {
  MergeSummary summary;
  for (const Item& in : incoming) {
    if (in.password.isEmpty() || (in.url.isEmpty() && in.title.isEmpty())) {
      summary.skipped++;
      continue;
    }
    String k = mergeKey(in);
    Item* existing = nullptr;
    for (Item& it : items) {
      if (mergeKey(it) == k) {
        existing = &it;
        break;
      }
    }
    if (existing) {
      if (existing->password == in.password) {
        summary.skipped++;
      } else {
        existing->password = in.password;
        existing->updatedAt = now;
        summary.updated++;
      }
    } else {
      Item item = in;
      if (item.id.isEmpty()) item.id = newId();
      if (item.title.isEmpty()) item.title = hostOf(item.url);
      if (!item.updatedAt) item.updatedAt = now;
      items.push_back(item);
      summary.imported++;
    }
  }
  if (summary.imported || summary.updated) dirty = true;
  return summary;
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

// ── storage ──

inline bool begin() { return LittleFS.begin(true); }

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

inline bool save() {
  if (!unlocked()) return false;
  Bytes buf;
  size_t estimate = 2;
  for (const Item& it : items) estimate += 80 + it.id.length() + it.title.length() + it.url.length() + it.username.length() + it.password.length() + it.notes.length();
  buf.reserve(estimate + 28);
  buf.push_back('[');
  bool firstItem = true;
  for (const Item& it : items) {
    if (!firstItem) buf.push_back(',');
    firstItem = false;
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
  }
  buf.push_back(']');
  if (!crypto::gcmSealInPlace(key, buf, crypto::bytes(AAD))) return false;
  File f = LittleFS.open(FILE_PATH, "w");
  if (!f) return false;
  bool ok = f.write(buf.data(), buf.size()) == buf.size();
  f.close();
  if (ok) dirty = false;
  return ok;
}

/// Decrypts the stored vault with `vaultKey`. Succeeds with an empty vault when no file exists yet.
inline bool unlock(const Bytes& vaultKey) {
  if (vaultKey.size() != 32) return false;
  items.clear();
  if (LittleFS.exists(FILE_PATH)) {
    File f = LittleFS.open(FILE_PATH, "r");
    if (!f) return false;
    Bytes buf(f.size());
    f.read(buf.data(), buf.size());
    f.close();
    if (!crypto::gcmOpenInPlace(vaultKey, buf, crypto::bytes(AAD))) return false;
    buf.push_back(0);
    JsonDocument doc;
    // writable char* → ArduinoJson parses in place instead of copying every string
    if (deserializeJson(doc, (char*)buf.data()) != DeserializationError::Ok) return false;
    for (JsonObjectConst o : doc.as<JsonArrayConst>()) items.push_back(itemFromJson(o));
  }
  key = vaultKey;
  dirty = false;
  return true;
}

inline void lock() {
  items.clear();
  key.clear();
}

inline void wipe() {
  lock();
  LittleFS.remove(FILE_PATH);
}

}  // namespace vault
