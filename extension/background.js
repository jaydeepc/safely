// Safely service worker.
//
//   content script / popup  ⇄  this worker  ⇄  native host (BLE pipe)  ⇄  Safely Key  ⇄  phone
//
// The worker owns the pairing (a non-extractable AES key in IndexedDB) and is the only place
// where credentials are decrypted. It never writes a password to disk.

import { BrowserEngine } from './lib/engine.js';
import { fromBase64, toBase64 } from './lib/protocol.js';
import { batches } from './lib/csv.js';
import { kv } from './lib/store.js';

const HOST_NAME = 'app.safely.host';
const DEFAULT_SETTINGS = { autofill: true, offerSave: true };

let port = null;
let reconnectTimer = null;
const link = { host: 'connecting', bluetooth: 'unknown', key: false, phone: false, rssi: null };

const engine = new BrowserEngine({
  send(envelope) {
    if (!port || !link.key) return false;
    port.postMessage({ type: 'tx', data: toBase64(envelope) });
    return true;
  },
  loadPairing: () => kv.get('pairing'),
  savePairing: (pairing) => (pairing ? kv.set('pairing', pairing) : kv.delete('pairing')),
  onPairingEvent: (event) => broadcast({ event: 'pairing', ...event }),
  onUnpaired: () => publishStatus(),
});

// ───────────────────────────── native host ─────────────────────────────

function connectHost() {
  if (port) return;
  clearTimeout(reconnectTimer);
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
  } catch (error) {
    link.host = 'missing';
    return;
  }
  link.host = 'connecting';

  port.onMessage.addListener((message) => {
    link.host = 'ok';
    if (message.type === 'status') {
      const wasReady = link.key && link.phone;
      Object.assign(link, { bluetooth: message.bluetooth, key: !!message.key, phone: !!message.phone, rssi: message.rssi ?? null });
      publishStatus();
      if (!wasReady && link.key && link.phone) nudgeActiveTabs();
    } else if (message.type === 'rx') {
      engine.receive(fromBase64(message.data)).catch((e) => console.warn('receive failed', e));
    }
  });

  port.onDisconnect.addListener(() => {
    const reason = chrome.runtime.lastError?.message || '';
    port = null;
    Object.assign(link, { key: false, phone: false, rssi: null });
    link.host = /not found|forbidden|access/i.test(reason) ? 'missing' : 'stopped';
    console.warn('native host disconnected:', reason);
    publishStatus();
    reconnectTimer = setTimeout(connectHost, link.host === 'missing' ? 15000 : 3000);
  });

  port.postMessage({ type: 'status?' });
}

async function snapshot() {
  const pairing = await engine.getPairing();
  return {
    ...link,
    paired: !!pairing,
    phoneName: pairing?.phoneName || null,
    ready: link.host === 'ok' && link.key && link.phone && !!pairing,
  };
}

async function publishStatus() {
  const status = await snapshot();
  broadcast({ event: 'status', status });
  const badge = status.ready ? ['', '#22C55E'] : status.host === 'missing' ? ['×', '#EF4444'] : !status.paired ? ['!', '#F59E0B'] : ['·', '#94A3B8'];
  chrome.action.setBadgeText({ text: badge[0] });
  chrome.action.setBadgeBackgroundColor({ color: badge[1] });
}

function broadcast(message) {
  chrome.runtime.sendMessage(message).catch(() => {});
}

/** The phone just came into range: let open login pages try again. */
async function nudgeActiveTabs() {
  const tabs = await chrome.tabs.query({ active: true });
  for (const tab of tabs) chrome.tabs.sendMessage(tab.id, { event: 'ready' }).catch(() => {});
}

// ───────────────────────────── credentials ─────────────────────────────

function originOf(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' || u.protocol === 'http:' ? u : null;
  } catch {
    return null;
  }
}

async function fetchCredentials(url, reason) {
  const target = originOf(url);
  if (!target) return { status: 'unsupported' };
  const status = await snapshot();
  if (!status.paired) return { status: 'not-paired' };
  if (!status.ready) return { status: 'offline', link: status };
  try {
    // Only origin + path leave the browser; query strings can carry tokens.
    const reply = await engine.request(
      { t: 'get', origin: target.origin, url: target.origin + target.pathname, reason },
      reason === 'user' ? 60000 : 25000,
    );
    return { status: reply.status, items: reply.items || [] };
  } catch (error) {
    return { status: error.message === 'timeout' ? 'timeout' : 'offline' };
  }
}

// Logins typed by hand are kept in memory (never on disk) until the person answers the save prompt.
const SAVE_TTL = 120000;

async function stashSave(tabId, offer) {
  await chrome.storage.session.set({ [`save:${tabId}`]: { ...offer, at: Date.now() } });
}

async function pendingSave(tabId) {
  const key = `save:${tabId}`;
  const offer = (await chrome.storage.session.get(key))[key];
  if (!offer) return null;
  if (Date.now() - offer.at > SAVE_TTL) {
    await chrome.storage.session.remove(key);
    return null;
  }
  return offer;
}

// ───────────────────────────── message API ─────────────────────────────

const handlers = {
  status: () => snapshot(),

  settings: async () => ({ ...DEFAULT_SETTINGS, ...(await chrome.storage.local.get('settings')).settings }),

  'settings:set': async ({ settings }) => {
    const merged = { ...(await handlers.settings()), ...settings };
    await chrome.storage.local.set({ settings: merged });
    return merged;
  },

  // from a content script: the origin comes from Chrome, never from the page
  credentials: ({ reason }, sender) => fetchCredentials(sender.origin || sender.url, reason === 'user' ? 'user' : 'auto'),

  // from the popup
  'tab:credentials': async () => {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab?.url) return { status: 'unsupported' };
    const result = await fetchCredentials(tab.url, 'user');
    return { ...result, host: originOf(tab.url)?.host };
  },

  'tab:fill': async ({ item }) => {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) return { ok: false };
    await chrome.tabs.sendMessage(tab.id, { cmd: 'fill', item }, { frameId: 0 }).catch(() => {});
    return { ok: true };
  },

  'save:stash': async ({ offer }, sender) => {
    const settings = await handlers.settings();
    const target = originOf(sender.origin || sender.url);
    if (!settings.offerSave || !target || !sender.tab || !(await engine.getPairing())) return { ok: false };
    await stashSave(sender.tab.id, { ...offer, origin: target.origin, url: target.origin + target.pathname, host: target.host });
    return { ok: true };
  },

  'save:pending': async (_, sender) => (sender.tab && sender.frameId === 0 ? pendingSave(sender.tab.id) : null),

  'save:dismiss': async (_, sender) => {
    if (sender.tab) await chrome.storage.session.remove(`save:${sender.tab.id}`);
    return { ok: true };
  },

  'save:confirm': async (_, sender) => {
    const offer = sender.tab && (await pendingSave(sender.tab.id));
    if (!offer) return { status: 'expired' };
    await chrome.storage.session.remove(`save:${sender.tab.id}`);
    try {
      const reply = await engine.request(
        { t: 'save', origin: offer.origin, item: { title: offer.host, url: offer.url, username: offer.username, password: offer.password } },
        60000,
      );
      return { status: reply.status };
    } catch (error) {
      return { status: error.message };
    }
  },

  'pair:start': async () => {
    const platform = navigator.userAgentData?.platform || 'computer';
    await engine.startPairing(`Chrome on ${platform}`);
    return engine.pairingSnapshot();
  },
  'pair:state': () => engine.pairingSnapshot(),
  'pair:confirm': async () => {
    await engine.confirmPairing();
    publishStatus();
    return engine.pairingSnapshot();
  },
  'pair:cancel': () => {
    engine.cancelPairing(true);
    return { stage: 'idle' };
  },

  unpair: async () => {
    await engine.unpair();
    publishStatus();
    return { ok: true };
  },
};

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const handler = message?.cmd && handlers[message.cmd];
  if (!handler || sender.id !== chrome.runtime.id) return false;
  connectHost();
  Promise.resolve(handler(message, sender))
    .then(sendResponse)
    .catch((error) => sendResponse({ status: 'error', error: String(error?.message || error) }));
  return true;
});

// Import streams progress, so it uses a long-lived port from pages/import.html.
chrome.runtime.onConnect.addListener((client) => {
  if (client.name !== 'import' || client.sender?.id !== chrome.runtime.id) return;
  client.onMessage.addListener(async ({ items }) => {
    const groups = batches(items);
    const totals = { imported: 0, updated: 0, skipped: 0, vaultCount: null };
    try {
      for (let i = 0; i < groups.length; i++) {
        const reply = await engine.request({ t: 'import', batch: i + 1, totalBatches: groups.length, items: groups[i] }, 90000);
        if (reply.status !== 'ok') throw new Error(reply.status || 'refused');
        totals.imported += reply.imported || 0;
        totals.updated += reply.updated || 0;
        totals.skipped += reply.skipped || 0;
        totals.vaultCount = reply.vaultCount ?? totals.vaultCount;
        client.postMessage({ event: 'progress', done: i + 1, total: groups.length, ...totals });
      }
      client.postMessage({ event: 'done', ...totals });
    } catch (error) {
      client.postMessage({ event: 'failed', reason: String(error.message || error), ...totals });
    }
  });
});

chrome.runtime.onInstalled.addListener(({ reason }) => {
  if (reason === 'install') chrome.tabs.create({ url: chrome.runtime.getURL('pages/pair.html') });
});
chrome.runtime.onStartup.addListener(connectHost);

connectHost();
publishStatus();
