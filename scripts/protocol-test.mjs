// Proves the extension's JavaScript (WebCrypto) and the phone's Swift (CryptoKit) speak the same protocol.
// Runs the real BrowserEngine from extension/lib against the real PhoneEngine (safely-simphone --stdio).
// No Bluetooth involved:   node scripts/protocol-test.mjs
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import assert from 'node:assert/strict';
import { BrowserEngine } from '../extension/lib/engine.js';
import { fromBase64, toBase64 } from '../extension/lib/protocol.js';
import { batches } from '../extension/lib/csv.js';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const phone = spawn(path.join(root, 'core/.build/debug/safely-simphone'), ['--stdio', '--auto-confirm']);
phone.stderr.pipe(process.stderr);

let phoneCode = null;
let stored = null;
const events = [];
const engine = new BrowserEngine({
  send: (envelope) => phone.stdin.write(toBase64(envelope) + '\n'),
  loadPairing: async () => stored,
  savePairing: async (pairing) => { stored = pairing; },
  onPairingEvent: (event) => events.push(event),
});

createInterface({ input: phone.stdout }).on('line', (line) => {
  if (line.startsWith('#')) {
    console.log('  phone:', line.slice(2));
    const code = line.match(/PAIRING CODE (\d{6})/);
    if (code) phoneCode = code[1];
  } else {
    engine.receive(fromBase64(line));
  }
});

const until = async (what, test) => {
  for (let i = 0; i < 100; i++) {
    if (test()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timed out waiting for ${what}`);
};

try {
  console.log('1. pairing');
  await engine.startPairing('Protocol test');
  await until('pairing code', () => engine.pairingSnapshot().stage === 'compare' && phoneCode);
  assert.equal(engine.pairingSnapshot().code, phoneCode, 'both sides must show the same six digits');
  console.log(`  browser code ${engine.pairingSnapshot().code} == phone code ${phoneCode}`);
  await engine.confirmPairing();
  await until('pairing to finish', () => stored);
  assert.equal(stored.phoneName, 'Simulated iPhone');

  console.log('2. credentials for a known site');
  const creds = await engine.request({ t: 'get', origin: 'https://github.com', reason: 'auto' });
  assert.equal(creds.status, 'ok');
  assert.equal(creds.items[0].username, 'demo@safely.test');
  assert.equal(creds.items[0].password, 'demo-Gh-7431!');

  console.log('3. subdomain matching and ordering');
  const sub = await engine.request({ t: 'get', origin: 'https://login.example.com', reason: 'user' });
  assert.deepEqual(sub.items.map((i) => i.username), ['alice@work', 'alice']);

  console.log('4. unknown site');
  assert.equal((await engine.request({ t: 'get', origin: 'https://nothing.invalid', reason: 'auto' })).status, 'none');

  console.log('5. save a new login, then read it back');
  const saved = await engine.request({ t: 'save', origin: 'https://new.site', item: { title: 'new.site', url: 'https://new.site/login', username: 'me', password: 'pässwörd ✓ "quoted"' } });
  assert.equal(saved.status, 'ok');
  const back = await engine.request({ t: 'get', origin: 'https://new.site', reason: 'auto' });
  assert.equal(back.items[0].password, 'pässwörd ✓ "quoted"');

  console.log('6. bulk import in batches (multi-chunk messages)');
  const many = Array.from({ length: 250 }, (_, i) => ({ title: `Site ${i}`, url: `https://site${i}.test/login`, username: `user${i}@example.com`, password: `pw-${i}-${'x'.repeat(24)}` }));
  const groups = batches(many);
  let imported = 0;
  for (let i = 0; i < groups.length; i++) {
    const ack = await engine.request({ t: 'import', batch: i + 1, totalBatches: groups.length, items: groups[i] });
    assert.equal(ack.status, 'ok');
    imported += ack.imported;
  }
  assert.equal(imported, 250);
  console.log(`  ${groups.length} batches, ${imported} logins`);

  console.log('7. a replayed request is ignored by the phone');
  let captured = null;
  const realSend = engine.io.send;
  engine.io.send = (envelope) => { captured = envelope; return realSend(envelope); };
  await engine.request({ t: 'ping' });
  engine.io.send = realSend;
  let replayAnswered = false;
  const realReceive = engine.receive.bind(engine);
  engine.receive = async (envelope) => { replayAnswered = true; return realReceive(envelope); };
  realSend(captured);
  await new Promise((r) => setTimeout(r, 600));
  assert.equal(replayAnswered, false, 'phone must not answer a replay');

  console.log('\nPASS — JavaScript and Swift agree on pairing, encryption, import and replay protection.');
  phone.kill();
  process.exit(0);
} catch (error) {
  console.error('\nFAIL:', error.message);
  phone.kill();
  process.exit(1);
}
