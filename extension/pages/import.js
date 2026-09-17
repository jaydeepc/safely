import { parsePasswordCsv } from '../lib/csv.js';

const $ = (id) => document.getElementById(id);
let items = [];

function show(section) {
  for (const id of ['pick', 'review', 'progress']) $(id).hidden = id !== section;
}

function hostOf(url) {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

async function load(file) {
  $('pick-error').hidden = true;
  items = parsePasswordCsv(await file.text());
  if (!items.length) {
    $('pick-error').hidden = false;
    $('pick-error').textContent = 'No logins found in that file. It should be the .csv that the browser’s “Export passwords” creates.';
    return;
  }
  $('found').textContent = items.length;
  $('filename').textContent = file.name;
  $('preview').replaceChildren(
    ...items.slice(0, 60).map((item, i) => {
      const row = document.createElement('div');
      row.style.animationDelay = `${Math.min(i, 12) * 30}ms`;
      const site = document.createElement('b');
      site.textContent = item.title || hostOf(item.url);
      const user = document.createElement('span');
      user.textContent = item.username || '—';
      row.append(site, user);
      return row;
    }),
  );
  show('review');

  const status = await chrome.runtime.sendMessage({ cmd: 'status' });
  $('link-warning').hidden = status.ready;
  $('send').disabled = !status.ready;
  if (!status.ready) {
    $('link-warning').textContent = status.paired
      ? 'Your phone is not reachable right now. Bring the key and phone close and open Shhlock on the phone.'
      : 'This browser is not paired yet — pair it first from the Shhlock toolbar icon.';
  }
}

function start() {
  show('progress');
  const port = chrome.runtime.connect({ name: 'import' });
  port.onMessage.addListener((message) => {
    $('n-imported').textContent = message.imported;
    $('n-updated').textContent = message.updated;
    $('n-skipped').textContent = message.skipped;
    if (message.event === 'progress') {
      $('bar').style.width = `${(message.done / message.total) * 100}%`;
      $('progress-text').textContent = `Encrypted batch ${message.done} of ${message.total} delivered`;
    } else if (message.event === 'done') {
      $('bar').style.width = '100%';
      $('progress-title').textContent = 'All set — your phone has them';
      $('progress-text').textContent = message.vaultCount != null ? `${message.vaultCount} logins are now in your vault.` : '';
      $('after').hidden = false;
      items = [];
      port.disconnect();
    } else if (message.event === 'failed') {
      $('progress-title').textContent = 'Import stopped';
      $('progress-text').textContent = `The phone stopped answering (${message.reason}). Already delivered logins are safe — run the import again to continue; duplicates are skipped.`;
      port.disconnect();
    }
  });
  port.postMessage({ items });
}

const drop = $('drop');
drop.addEventListener('click', () => $('file').click());
drop.addEventListener('keydown', (event) => event.key === 'Enter' && $('file').click());
drop.addEventListener('dragover', (event) => {
  event.preventDefault();
  drop.classList.add('over');
});
drop.addEventListener('dragleave', () => drop.classList.remove('over'));
drop.addEventListener('drop', (event) => {
  event.preventDefault();
  drop.classList.remove('over');
  if (event.dataTransfer.files[0]) load(event.dataTransfer.files[0]);
});
$('file').addEventListener('change', (event) => event.target.files[0] && load(event.target.files[0]));
$('back').addEventListener('click', () => show('pick'));
$('send').addEventListener('click', start);
chrome.runtime.onMessage.addListener((message) => {
  if (message.event === 'status' && !$('review').hidden) {
    $('send').disabled = !message.status.ready;
    $('link-warning').hidden = message.status.ready;
  }
});
