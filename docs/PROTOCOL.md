# Safely protocol v1

Implementations: `core/Sources/SafelyCore` (Swift — phone, helper) and `extension/lib` (JavaScript — browser).
`scripts/protocol-test.mjs` runs one against the other.

## 1. Transport: the Safely Key (GATT)

Service `5AFE0001-7A3C-4B1E-9D2F-C0DE5AFE1A00`. Characteristic UUIDs differ in the fourth hex group.

| UUID | Name | Properties | Used by |
| --- | --- | --- | --- |
| `…0002` | PHONE_RX | write | phone → key |
| `…0003` | PHONE_TX | notify | key → phone |
| `…0004` | BROWSER_RX | write | browser → key |
| `…0005` | BROWSER_TX | notify | key → browser |
| `…0006` | STATUS | read, notify | bit 0 = a phone is subscribed, bit 1 = a browser is subscribed |

The key copies every write on `BROWSER_RX` to a notification on `PHONE_TX` and every write on `PHONE_RX` to
`BROWSER_TX`. It does not parse, store or reorder frames. Roles follow from the characteristic used, so up to
three centrals (one phone, two browsers) can be attached at once.

### Frames

A message (an *envelope*, below) is split into frames of at most 160 bytes:

```
[msgId u8][index u8][total u8][payload ≤ 157 bytes]
```

`msgId` increments per sender, `index` counts from 0. Largest message: 255 × 157 = 40 035 bytes. Frames are
written with response, so they arrive in order; receivers reassemble per `msgId` and drop partial messages after 30 s.

## 2. Envelopes

```
plain   0x01 ‖ JSON                                   pairing only
sealed  0x02 ‖ keyId[8] ‖ nonce[12] ‖ ciphertext ‖ tag[16]
```

- `keyId` = first 8 bytes of SHA-256(browser public key). It names the pairing in both directions.
- Sealed body: AES-256-GCM, random nonce, the 9 header bytes as additional authenticated data.
- Keys are P-256, encoded as 65 byte uncompressed points, base64 inside JSON.
- Session key = HKDF-SHA256(ECDH shared secret, salt `"safely/v1/session"`, info = browserPub ‖ phonePub, 32 bytes).

Every sealed JSON carries `ctr` — milliseconds since 1970, strictly increasing per sender. A receiver stores the
highest `ctr` it accepted per pairing and silently drops anything not greater. Replies echo the request `id`.

## 3. Pairing

The person opens **Pair a browser** on the phone (otherwise the phone answers `pair_cancel`).

```
browser                                            phone
  │ pair_commit { commit, name }                     │  commit = SHA256("safely/v1/commit" ‖ pubB ‖ nonce)
  │ ───────────────────────────────────────────────▶ │
  │                         pair_pub { pub, name }   │
  │ ◀─────────────────────────────────────────────── │
  │ pair_reveal { pub, nonce }                       │  phone verifies the commitment
  │ ───────────────────────────────────────────────▶ │
  │      both display  SAS = uint32(SHA256("safely/v1/sas" ‖ pubB ‖ pubP ‖ nonce)[0..4]) mod 10⁶
  │                  sealed pair_confirm { name }    │  after "They match" on the phone
  │ ◀─────────────────────────────────────────────── │
```

The browser stores the pairing only after *its* user confirmed the code **and** a valid `pair_confirm` arrived.
Because the browser is committed to its key before it learns the phone's key, an attacker in the middle gets one
blind guess at a 1 in 1 000 000 collision.

## 4. Sealed messages

| `t` | Direction | Fields | Reply |
| --- | --- | --- | --- |
| `get` | browser → phone | `origin`, `url` (origin + path, no query), `reason`: `auto` \| `user` | `creds` |
| `creds` | phone → browser | `status`: `ok` \| `none` \| `denied` \| `locked` \| `busy`, `items[]` | |
| `save` | browser → phone | `origin`, `item` | `ack` |
| `import` | browser → phone | `batch`, `totalBatches`, `items[]` (≈ 6 KB per batch) | `ack` with `imported`, `updated`, `skipped`, `vaultCount` |
| `ping` | browser → phone | | `pong` with `name`, `vaultCount` |
| `unpair` | either | | none — the receiver deletes the pairing |

`items[]` entries: `{ id?, title, url, username, password, notes? }`.

The phone matches `origin` against the vault by registrable domain (exact host first, then most recently used),
treating shared-hosting suffixes (`github.io`, `vercel.app`, …) as public suffixes. It answers at most 40 `get`
requests per minute per browser.

## 5. Helper ⇄ extension (Chrome native messaging, host `app.safely.host`)

```
extension → helper   {"type":"tx","data":"<base64 envelope>"}      {"type":"status?"}
helper → extension   {"type":"rx","data":"<base64 envelope>"}      {"type":"status","bluetooth":"on","key":true,"phone":true,"rssi":-52}
```

The helper frames, reassembles and reconnects. It holds no keys.
