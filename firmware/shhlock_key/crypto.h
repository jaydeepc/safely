// Crypto for the Shhlock Key, on top of the mbedTLS that ships with the ESP32 core.
// Same primitives and encodings as the Swift (CryptoKit) and JavaScript (WebCrypto) sides:
//   P-256 ECDH (uncompressed 65 byte points), HKDF-SHA256, AES-256-GCM (12 byte nonce, 16 byte tag), SHA-256.
#pragma once

#include <Arduino.h>
#include <esp_random.h>
#include <mbedtls/ecdh.h>
#include <mbedtls/ecp.h>
#include <mbedtls/gcm.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>
#include <mbedtls/sha256.h>

#include <vector>

typedef std::vector<uint8_t> Bytes;

namespace crypto {

inline int rng(void*, unsigned char* out, size_t len) {
  esp_fill_random(out, len);
  return 0;
}

inline Bytes randomBytes(size_t n) {
  Bytes b(n);
  esp_fill_random(b.data(), n);
  return b;
}

inline Bytes sha256(const Bytes& data) {
  Bytes out(32);
  mbedtls_sha256(data.data(), data.size(), out.data(), 0);
  return out;
}

inline Bytes cat(const Bytes& a, const Bytes& b) {
  Bytes out(a);
  out.insert(out.end(), b.begin(), b.end());
  return out;
}

inline Bytes bytes(const char* s) { return Bytes(s, s + strlen(s)); }

/// Generates a P-256 key pair. priv = 32 bytes, pub = 65 bytes (0x04 ‖ X ‖ Y).
inline bool generateKeyPair(Bytes& priv, Bytes& pub) {
  mbedtls_ecp_group grp;
  mbedtls_mpi d;
  mbedtls_ecp_point Q;
  mbedtls_ecp_group_init(&grp);
  mbedtls_mpi_init(&d);
  mbedtls_ecp_point_init(&Q);
  bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) == 0 &&
            mbedtls_ecp_gen_keypair(&grp, &d, &Q, rng, nullptr) == 0;
  if (ok) {
    priv.assign(32, 0);
    pub.assign(65, 0);
    size_t olen = 0;
    ok = mbedtls_mpi_write_binary(&d, priv.data(), 32) == 0 &&
         mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED, &olen, pub.data(), 65) == 0 && olen == 65;
  }
  mbedtls_ecp_point_free(&Q);
  mbedtls_mpi_free(&d);
  mbedtls_ecp_group_free(&grp);
  return ok;
}

/// ECDH shared secret: the X coordinate of priv · peerPub (what CryptoKit and WebCrypto return).
inline bool ecdh(const Bytes& priv, const Bytes& peerPub, Bytes& shared) {
  if (priv.size() != 32 || peerPub.size() != 65 || peerPub[0] != 0x04) return false;
  mbedtls_ecp_group grp;
  mbedtls_mpi d, z;
  mbedtls_ecp_point Q;
  mbedtls_ecp_group_init(&grp);
  mbedtls_mpi_init(&d);
  mbedtls_mpi_init(&z);
  mbedtls_ecp_point_init(&Q);
  bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) == 0 &&
            mbedtls_mpi_read_binary(&d, priv.data(), 32) == 0 &&
            mbedtls_ecp_point_read_binary(&grp, &Q, peerPub.data(), 65) == 0 &&
            mbedtls_ecp_check_pubkey(&grp, &Q) == 0 &&
            mbedtls_ecdh_compute_shared(&grp, &z, &Q, &d, rng, nullptr) == 0;
  if (ok) {
    shared.assign(32, 0);
    ok = mbedtls_mpi_write_binary(&z, shared.data(), 32) == 0;
  }
  mbedtls_ecp_point_free(&Q);
  mbedtls_mpi_free(&z);
  mbedtls_mpi_free(&d);
  mbedtls_ecp_group_free(&grp);
  return ok;
}

inline Bytes hkdf(const Bytes& ikm, const Bytes& salt, const Bytes& info, size_t len = 32) {
  Bytes out(len);
  const mbedtls_md_info_t* md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (mbedtls_hkdf(md, salt.data(), salt.size(), ikm.data(), ikm.size(), info.data(), info.size(), out.data(), len) != 0) out.clear();
  return out;
}

/// nonce(12) ‖ ciphertext ‖ tag(16) — CryptoKit's "combined" representation.
inline Bytes gcmSeal(const Bytes& key, const Bytes& plain, const Bytes& aad) {
  Bytes nonce = randomBytes(12);
  Bytes out(12 + plain.size() + 16);
  memcpy(out.data(), nonce.data(), 12);
  mbedtls_gcm_context ctx;
  mbedtls_gcm_init(&ctx);
  bool ok = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key.data(), 256) == 0 &&
            mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, plain.size(), nonce.data(), 12, aad.data(), aad.size(),
                                      plain.data(), out.data() + 12, 16, out.data() + 12 + plain.size()) == 0;
  mbedtls_gcm_free(&ctx);
  if (!ok) out.clear();
  return out;
}

/// In-place variants for large buffers (one copy of the vault in RAM instead of three).
/// sealInPlace: buf = plaintext on entry, nonce ‖ ciphertext ‖ tag on return.
inline bool gcmSealInPlace(const Bytes& key, Bytes& buf, const Bytes& aad) {
  size_t len = buf.size();
  Bytes nonce = randomBytes(12);
  buf.insert(buf.begin(), nonce.begin(), nonce.end());
  buf.resize(12 + len + 16);
  mbedtls_gcm_context ctx;
  mbedtls_gcm_init(&ctx);
  bool ok = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key.data(), 256) == 0 &&
            mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, len, nonce.data(), 12, aad.data(), aad.size(),
                                      buf.data() + 12, buf.data() + 12, 16, buf.data() + 12 + len) == 0;
  mbedtls_gcm_free(&ctx);
  return ok;
}

/// openInPlace: buf = nonce ‖ ciphertext ‖ tag on entry, plaintext on return.
inline bool gcmOpenInPlace(const Bytes& key, Bytes& buf, const Bytes& aad) {
  if (buf.size() < 28) return false;
  size_t len = buf.size() - 28;
  Bytes nonce(buf.begin(), buf.begin() + 12);
  Bytes tag(buf.end() - 16, buf.end());
  mbedtls_gcm_context ctx;
  mbedtls_gcm_init(&ctx);
  bool ok = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key.data(), 256) == 0 &&
            mbedtls_gcm_auth_decrypt(&ctx, len, nonce.data(), 12, aad.data(), aad.size(), tag.data(), 16,
                                     buf.data() + 12, buf.data() + 12) == 0;
  mbedtls_gcm_free(&ctx);
  if (ok) {
    buf.erase(buf.begin(), buf.begin() + 12);
    buf.resize(len);
  }
  return ok;
}

inline bool gcmOpen(const Bytes& key, const Bytes& combined, const Bytes& aad, Bytes& plain) {
  if (combined.size() < 28) return false;
  size_t len = combined.size() - 28;
  plain.assign(len, 0);
  mbedtls_gcm_context ctx;
  mbedtls_gcm_init(&ctx);
  bool ok = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key.data(), 256) == 0 &&
            mbedtls_gcm_auth_decrypt(&ctx, len, combined.data(), 12, aad.data(), aad.size(),
                                     combined.data() + 12 + len, 16, combined.data() + 12, plain.data()) == 0;
  mbedtls_gcm_free(&ctx);
  if (!ok) plain.clear();
  return ok;
}

// ── base64 (RFC 4648, with padding) ──

inline String b64encode(const Bytes& in) {
  static const char* T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  String out;
  out.reserve((in.size() + 2) / 3 * 4);
  for (size_t i = 0; i < in.size(); i += 3) {
    uint32_t v = in[i] << 16 | (i + 1 < in.size() ? in[i + 1] << 8 : 0) | (i + 2 < in.size() ? in[i + 2] : 0);
    out += T[(v >> 18) & 63];
    out += T[(v >> 12) & 63];
    out += i + 1 < in.size() ? T[(v >> 6) & 63] : '=';
    out += i + 2 < in.size() ? T[v & 63] : '=';
  }
  return out;
}

inline Bytes b64decode(const char* s) {
  Bytes out;
  if (!s) return out;
  uint32_t acc = 0;
  int bits = 0;
  for (; *s && *s != '='; s++) {
    char c = *s;
    int v;
    if (c >= 'A' && c <= 'Z') v = c - 'A';
    else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
    else if (c >= '0' && c <= '9') v = c - '0' + 52;
    else if (c == '+' || c == '-') v = 62;
    else if (c == '/' || c == '_') v = 63;
    else if (c == '\n' || c == '\r' || c == ' ') continue;
    else return Bytes();
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back((acc >> bits) & 0xFF);
    }
  }
  return out;
}

}  // namespace crypto
