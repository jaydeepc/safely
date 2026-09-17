# Shhlock protocol v2

The key is the server. Devices (a phone, computers) are clients. Implementations: `firmware/shhlock_key/engine.h`
(C++, the key), `core/Sources/SafelyCore/KeyClient.swift` (phone, Mac), `extension/lib/engine.js` (Chrome).
`shhlock-keytest` runs the Swift client against a real key over USB serial.

## 1. Transport: GATT

Service `5AFE0001-7A3C-4B1E-9D2F-C0DE5AFE1A00`; characteristics differ in the second group.

| UUID | Name | Properties | Used by |
| --- | --- | --- | --- |
| `…0002` | PHONE_RX | write | phone → key |
| `…0003` | PHONE_TX | notify | key → phone |
| `…0004` | COMPUTER_RX | write | computer → key |
| `…0005` | COMPUTER_TX | notify | key → computer |
| `…0006` | STATUS | read, notify | bit0 phone subscribed · bit1 computer subscribed · bit2 vault unlocked · bit3 waiting for the button |

Replies go back on the connection the request came from. Frames: `[msgId u8][index u8][total u8] + ≤157 bytes`;
max message 40 035 bytes.

## 2. Envelopes

```
plain   0x01 ‖ JSON                                   pairing only
sealed  0x02 ‖ keyId[8] ‖ nonce[12] ‖ ciphertext ‖ tag[16]
```

`keyId` = SHA-256(device public key)[0..8]. AES-256-GCM with the 9 header bytes as AAD.
Session key = HKDF-SHA256(ECDH(x), salt `shhlock/v2/session`, info = devicePub ‖ keyPub). Every sealed JSON carries
`ctr` (ms since 1970, strictly increasing per sender; the key persists the last accepted value per device).

## 3. Pairing

```
device                                                      key
  │ pair_commit { commit, name, role: "phone"|"computer" }    │  commit = SHA256("shhlock/v2/commit" ‖ pub ‖ nonce)
  │ ─────────────────────────────────────────────────────────▶│
  │           (phone) pair_button   — press the key's button   │  physical proof for the phone
  │ ◀───────────────────────────────────────────────────────  │
  │                              pair_pub { pub, name }        │
  │ ◀─────────────────────────────────────────────────────────│
  │ pair_reveal { pub, nonce }                                 │  key checks the commitment, derives the session
  │ ─────────────────────────────────────────────────────────▶│
  │      (computer) key → phone, sealed: approve { target, code, name }
  │      code = SAS = uint32(SHA256("shhlock/v2/sas" ‖ devicePub ‖ keyPub ‖ nonce)[0..4]) mod 10⁶ — computer shows it too
  │      phone → key, sealed: approve_reply { target, ok }
  │                       sealed pair_confirm { name, vaultCount, unlocked }
  │ ◀─────────────────────────────────────────────────────────│
  │ sealed enroll { secret }                                   │  32 random bytes; the key stores
  │ ─────────────────────────────────────────────────────────▶│  wrap = GCM(HKDF(secret, "shhlock/v2/wrap", keyId), vaultKey)
```

The first phone's `enroll` also mints the vault key. Up to 10 devices. `pair_cancel { reason }` aborts from either side.

## 4. Unlocking

After every connection a device sends sealed `unlock { secret }`. The key unwraps the vault key into RAM, loads the vault,
answers `ack { status: ok|denied, vaultCount }`. Any other request on a locked vault gets `status: "locked"`. Power loss locks it.

## 5. Requests (sealed)

| `t` | Who | Fields | Reply |
| --- | --- | --- | --- |
| `get` | any | `origin`, `reason` | `creds { status: ok|none|locked, items[] }` — exact host first, then registrable domain |
| `save` | any | `origin`, `item` | `ack { imported, updated, skipped, vaultCount }` |
| `import` | any | `batch`, `totalBatches`, `items[]` | `ack` |
| `vault_pull` | phone | `offset`, `limit` | `vault_items { items[], offset, total }` |
| `vault_put` | phone | `batch`, `totalBatches`, `items[]` | `ack` — replaces the whole vault at the last batch |
| `clients_list` | phone | | `clients { clients: [{ id, name, role }] }` |
| `clients_remove` | phone | `target` | `ack` |
| `wipe` | phone | | `ack`, then factory reset |
| `ping` | any | | `pong { name, vaultCount, unlocked }` |
| `unpair` | any | | none — the key forgets the sender |

Items: `{ id, title, url, username, password, notes?, updatedAt? }` (`updatedAt` in seconds; the phone keeps the newer side on sync).

## 6. Storage on the key

- NVS `shhlock/idpriv`: P-256 private key. NVS `shhlock/clients`: JSON of paired devices (id, pub, wrap, ctr, role, name).
- LittleFS `/vault.bin`: nonce ‖ AES-256-GCM(vault JSON) ‖ tag, AAD `shhlock/v2/vault`.
- Button: short press confirms a phone pairing; 8 s hold = factory reset.
