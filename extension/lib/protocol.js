// Shhlock wire protocol — browser side. Mirrors core/Sources/SafelyCore/{Crypto,Messages}.swift.
// Uses only WebCrypto, so it runs unchanged in the service worker and in Node (scripts/e2e-test.mjs).

const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder();
const dec = new TextDecoder();

export const ENVELOPE_PLAIN = 0x01;
export const ENVELOPE_SEALED = 0x02;

const SESSION_SALT = enc.encode('shhlock/v2/session');
const COMMIT_LABEL = enc.encode('shhlock/v2/commit');
const SAS_LABEL = enc.encode('shhlock/v2/sas');

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

export function toBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function fromBase64(text) {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function toHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(...parts) {
  return new Uint8Array(await subtle.digest('SHA-256', concat(...parts)));
}

/** New P-256 identity for one pairing. The private key never leaves WebCrypto. */
export async function createPairingKeys() {
  const keyPair = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
  const publicKey = new Uint8Array(await subtle.exportKey('raw', keyPair.publicKey));
  const nonce = globalThis.crypto.getRandomValues(new Uint8Array(16));
  const commit = await sha256(COMMIT_LABEL, publicKey, nonce);
  // the secret that wraps the vault key on the Shhlock Key; only this browser ever holds it
  const secret = globalThis.crypto.getRandomValues(new Uint8Array(32));
  return { privateKey: keyPair.privateKey, publicKey, nonce, commit, secret };
}

export async function keyIdOf(browserPublicKey) {
  return (await sha256(browserPublicKey)).slice(0, 8);
}

/** Six digits both screens must show. */
export async function sas(browserPublicKey, phonePublicKey, nonce) {
  const digest = await sha256(SAS_LABEL, browserPublicKey, phonePublicKey, nonce);
  const value = new DataView(digest.buffer).getUint32(0, false);
  return String(value % 1_000_000).padStart(6, '0');
}

/** ECDH → HKDF-SHA256 → non-extractable AES-256-GCM key, bound to both public keys. */
export async function deriveSessionKey(privateKey, browserPublicKey, phonePublicKey) {
  const peer = await subtle.importKey('raw', phonePublicKey, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = await subtle.deriveBits({ name: 'ECDH', public: peer }, privateKey, 256);
  const hkdf = await subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
  return subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: SESSION_SALT, info: concat(browserPublicKey, phonePublicKey) },
    hkdf,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

export function plainEnvelope(message) {
  return concat(new Uint8Array([ENVELOPE_PLAIN]), enc.encode(JSON.stringify(message)));
}

export function parsePlain(envelope) {
  if (envelope[0] !== ENVELOPE_PLAIN) return null;
  try {
    return JSON.parse(dec.decode(envelope.subarray(1)));
  } catch {
    return null;
  }
}

/** [0x02][keyId 8][nonce 12][ciphertext][tag 16]; the 9 byte header is authenticated. */
export async function seal(key, keyId, message) {
  const header = concat(new Uint8Array([ENVELOPE_SEALED]), keyId);
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const body = await subtle.encrypt({ name: 'AES-GCM', iv, additionalData: header }, key, enc.encode(JSON.stringify(message)));
  return concat(header, iv, new Uint8Array(body));
}

export function sealedKeyId(envelope) {
  if (envelope[0] !== ENVELOPE_SEALED || envelope.length < 9 + 28) return null;
  return envelope.subarray(1, 9);
}

export async function open(key, envelope) {
  if (envelope[0] !== ENVELOPE_SEALED || envelope.length < 9 + 28) throw new Error('bad envelope');
  const header = envelope.subarray(0, 9);
  const iv = envelope.subarray(9, 21);
  const plain = await subtle.decrypt({ name: 'AES-GCM', iv, additionalData: header }, key, envelope.subarray(21));
  return JSON.parse(dec.decode(plain));
}

export function sameBytes(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

let lastCtr = 0;
/** Strictly increasing millisecond counter; the phone rejects anything not newer than the last one. */
export function nextCtr() {
  lastCtr = Math.max(lastCtr + 1, Date.now());
  return lastCtr;
}

export function randomId() {
  return toHex(globalThis.crypto.getRandomValues(new Uint8Array(8)));
}
