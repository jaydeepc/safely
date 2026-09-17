# Shlok

<img src="design/mascot.png" width="120" align="right" alt="Shlok mascot">

Your passwords live on your phone. A small Bluetooth key in your pocket lets your browser borrow one
for a moment — and only while you are there.

```
 Chrome extension ⇄ Bluetooth helper ⇄  Shlok Key  ⇄  Shlok iOS app
  (fills the form)   (native host)     (XIAO ESP32C3)   (encrypted vault)
        └──────────── end-to-end encrypted: ECDH P-256 + AES-256-GCM ───────────┘
```

Nothing is stored in Chrome, in the helper, or on the key. Walk away with the key or the phone and the
browser can fill nothing.

| Folder | What it is |
| --- | --- |
| `firmware/` | Arduino firmware for the Seeed Studio XIAO ESP32C3 — a BLE relay that forwards sealed frames |
| `core/` | Swift package: protocol, crypto, BLE link, the phone-side engine, the native helper (`safely-host`) and a phone simulator (`safely-simphone`) |
| `ios/` | SwiftUI app + Password AutoFill extension (`Safely.xcodeproj`) |
| `extension/` | Chrome extension (Manifest V3) |
| `scripts/` | Installer, tests, TestFlight build |
| `docs/` | `PROTOCOL.md` and the illustrated guide `Shlok-Guide.pdf` |
| `design/` | Mascot and illustration source art (generated with GPT Image on Higgsfield) |

## Quick start

**1 · Key** — plug in the XIAO ESP32C3 and flash it (already done once for the board on this Mac):

```bash
firmware/flash.sh
```

Afterwards it only needs power — a USB battery or any USB port.

**2 · Browser helper + extension**

```bash
scripts/install-host.sh
```

Then Chrome → `chrome://extensions` → Developer mode → **Load unpacked** → pick `extension/`.
The setup page opens by itself. If macOS asks whether Chrome may use Bluetooth, allow it.

**3 · Phone** — open `ios/Safely.xcodeproj`, select your iPhone, Run. For TestFlight see below.
In the app: **Devices → Pair a browser**, then **Start pairing** on the Chrome setup page and compare the six digits.

**4 · Passwords** — Chrome → `chrome://password-manager/settings` → **Export passwords**, then Shlok toolbar
icon → **Import passwords** and drop the CSV. It is encrypted in the browser and sent through the key to the phone.
Nothing is removed from Chrome; delete the CSV afterwards. (The app can also import the CSV directly: Settings → Import.)

**5 · Try it** — `scripts/serve-test-page.sh` serves a harmless login form at <http://localhost:8765>, or just open a site you imported.

### No iPhone at hand?

`safely-simphone` runs the exact same phone-side code on your Mac with four demo logins
(`github.com`, `example.com`, `localhost:8765`):

```bash
cd core && swift build && .build/debug/safely-simphone
```

## Tests

```bash
cd core && swift test              # framing, crypto, domain matching, CSV, pairing + replay
node scripts/protocol-test.mjs     # extension JavaScript ⇄ phone Swift, no Bluetooth needed
node scripts/ble-e2e-test.mjs      # the whole chain over real Bluetooth (needs the key + safely-simphone running)
```

## TestFlight

```bash
scripts/testflight.sh            # → build/export/Safely.ipa, upload it with the Transporter app
```

```bash
scripts/testflight.sh --upload   # → straight to App Store Connect
```

One-time: sign in to Xcode (Settings → Accounts) and create the app record in App Store Connect with bundle ID
`com.codecrackjd.safely`. The script header explains how to change the bundle ID.

> **Naming:** the product is called **Shlok**. Code identifiers, the bundle ID (`com.codecrackjd.safely`), the native-host ID and folder
> names still say *safely* on purpose — only what people see was renamed.

## Security model

- **The key is untrusted.** It relays opaque frames and keeps no state. Stealing or cloning it yields nothing.
- **Pairing** uses a commitment + six digit comparison, so a nearby attacker cannot slip in between browser and phone.
- **Every message** is sealed with AES-256-GCM under a key derived from both sides' P-256 keys; a strictly
  increasing counter rejects replays. The browser's key is a non-extractable WebCrypto key.
- **The vault** is one AES-256-GCM file; its key sits in the iOS Keychain (this device only, never iCloud, never backups).
- **The phone decides.** "Fill automatically" treats proximity as consent; "Ask me every time" requires Face ID per request.
  Requests are limited to 40 per minute per browser and every fill is written to the Activity log.
- **The page never picks the site.** The extension takes the origin from Chrome, and the phone only returns logins
  whose registrable domain matches (with shared-hosting suffixes such as `github.io` treated as separate owners).

Known limits of this first version: no forward secrecy (a stolen browser profile *plus* recorded radio traffic could be
decrypted), no BLE-level bonding (anyone in range can connect to the key and be ignored), and the vault has no cloud
backup by design — use **Settings → Export a backup** now and then.
