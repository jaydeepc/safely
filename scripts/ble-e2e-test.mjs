// End-to-end test over real Bluetooth, without Chrome and without an iPhone:
//
//   this script (extension engine) ⇄ safely-host ⇄ BLE ⇄ Safely Key ⇄ BLE ⇄ safely-simphone
//
// 1. Flash and power the key.
// 2. In another terminal:   core/.build/debug/safely-simphone --auto-confirm
// 3. Here:                   node scripts/ble-e2e-test.mjs
//
// macOS asks once whether your terminal may use Bluetooth. `--app` starts the helper through
// build/Safely Host.app instead (scripts/make-dev-app.sh), which has its own Bluetooth permission.
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { BrowserEngine } from '../extension/lib/engine.js';
import { fromBase64, toBase64 } from '../extension/lib/protocol.js';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
let toHost, fromHost, stop;

if (process.argv.includes('--app')) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'safely-e2e-'));
  const inPipe = path.join(dir, 'in'), outPipe = path.join(dir, 'out');
  execFileSync('mkfifo', [inPipe, outPipe]);
  // open both ends read-write first so neither side blocks
  const inFd = fs.openSync(inPipe, 'r+'), outFd = fs.openSync(outPipe, 'r+');
  execFileSync('open', ['-n', '--stdin', inPipe, '--stdout', outPipe, path.join(root, 'build/Safely Host.app')]);
  toHost = fs.createWriteStream(null, { fd: inFd });
  fromHost = fs.createReadStream(null, { fd: outFd });
  stop = () => { try { execFileSync('pkill', ['-f', 'Safely Host.app']); } catch {} };
} else {
  const host = spawn(path.join(root, 'core/.build/debug/safely-host'), [], { stdio: ['pipe', 'pipe', 'inherit'] });
  host.on('exit', (code, signal) => signal === 'SIGABRT' && console.error('The helper was refused Bluetooth access — allow your terminal in System Settings → Privacy & Security → Bluetooth, or use --app.'));
  toHost = host.stdin;
  fromHost = host.stdout;
  stop = () => host.kill();
}

// Chrome native messaging framing: uint32 little-endian length + JSON
const post = (message) => {
  const body = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length);
  toHost.write(Buffer.concat([header, body]));
};

let status = {};
let stored = null;
const engine = new BrowserEngine({
  send: (envelope) => (post({ type: 'tx', data: toBase64(envelope) }), true),
  loadPairing: async () => stored,
  savePairing: async (pairing) => { stored = pairing; },
});

let buffer = Buffer.alloc(0);
fromHost.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32LE(0)) {
    const length = buffer.readUInt32LE(0);
    const message = JSON.parse(buffer.subarray(4, 4 + length).toString());
    buffer = buffer.subarray(4 + length);
    if (message.type === 'status') {
      status = message;
      console.log(`  link: bluetooth=${message.bluetooth} key=${message.key} phone=${message.phone} rssi=${message.rssi ?? '-'}`);
    } else if (message.type === 'rx') {
      engine.receive(fromBase64(message.data));
    }
  }
});

const until = async (what, test, seconds = 30) => {
  for (let i = 0; i < seconds * 10; i++) {
    if (test()) return;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`timed out waiting for ${what}`);
};

try {
  console.log('1. waiting for key and (simulated) phone');
  post({ type: 'status?' });
  await until('the Safely Key', () => status.key);
  await until('the phone on the key', () => status.phone);

  console.log('2. pairing over Bluetooth');
  await engine.startPairing('BLE end-to-end test');
  await until('pairing code', () => engine.pairingSnapshot().stage === 'compare');
  console.log(`  code ${engine.pairingSnapshot().code} (the simulated phone prints the same one)`);
  await engine.confirmPairing();
  await until('phone confirmation', () => stored);

  console.log('3. fetching a login through the key');
  const started = Date.now();
  const creds = await engine.request({ t: 'get', origin: 'https://github.com', reason: 'auto' });
  assert.equal(creds.items[0].password, 'demo-Gh-7431!');
  console.log(`  got ${creds.items[0].username} in ${Date.now() - started} ms`);

  console.log('4. a 12 KB message (about 80 BLE frames each way)');
  const items = Array.from({ length: 60 }, (_, i) => ({ title: `Bulk ${i}`, url: `https://bulk${i}.test`, username: `u${i}`, password: 'p'.repeat(120) }));
  const bulkStart = Date.now();
  const ack = await engine.request({ t: 'import', batch: 1, totalBatches: 1, items }, 60000);
  assert.equal(ack.imported + ack.skipped + ack.updated, 60);
  console.log(`  delivered and acknowledged in ${Date.now() - bulkStart} ms`);

  await engine.unpair();
  console.log('\nPASS — browser ⇄ helper ⇄ Safely Key ⇄ phone works over Bluetooth.');
  stop();
  process.exit(0);
} catch (error) {
  console.error('\nFAIL:', error.message);
  stop();
  process.exit(1);
}
