const $ = (id) => document.getElementById(id);
const send = (message) => chrome.runtime.sendMessage(message);
const openPage = (page) => chrome.tabs.create({ url: chrome.runtime.getURL(`pages/${page}`) });

let lookedUp = false;

function render(status) {
  const hostOk = status.host === 'ok';
  $('n-key').classList.toggle('on', status.key);
  $('n-phone').classList.toggle('on', status.key && status.phone);
  $('w-key').className = `wire ${status.key ? 'on' : hostOk ? 'seek' : ''}`;
  $('w-phone').className = `wire ${status.key && status.phone ? 'on' : status.key ? 'seek' : ''}`;

  const pill = $('pill');
  let hint = '';
  if (status.host === 'missing') {
    pill.className = 'pill bad';
    pill.textContent = 'Helper missing';
    hint = 'The Bluetooth helper is not installed yet.';
  } else if (status.bluetooth === 'off') {
    pill.className = 'pill bad';
    pill.textContent = 'Bluetooth off';
    hint = 'Turn on Bluetooth on this computer.';
  } else if (status.bluetooth === 'unauthorized') {
    pill.className = 'pill bad';
    pill.textContent = 'No permission';
    hint = 'Allow Chrome to use Bluetooth in System Settings → Privacy & Security.';
  } else if (!status.key) {
    pill.className = 'pill warn';
    pill.textContent = 'Looking for key';
    hint = 'Bring your Safely Key close. It connects on its own.';
  } else if (!status.phone) {
    pill.className = 'pill warn';
    pill.textContent = 'Phone away';
    hint = 'Key found. Waiting for your phone to join — open Safely once if it does not.';
  } else if (!status.paired) {
    pill.className = 'pill warn';
    pill.textContent = 'Not paired';
    hint = 'Everything is in reach. Pair this browser with your phone to start.';
  } else {
    pill.className = 'pill good';
    pill.textContent = 'Ready';
    hint = `Connected to ${status.phoneName || 'your phone'}${status.rssi ? ` · key signal ${status.rssi} dBm` : ''}`;
  }
  $('hint').textContent = hint;

  $('setup').hidden = status.host !== 'missing';
  $('pair').hidden = status.paired || status.host === 'missing';
  $('import').hidden = !status.paired;
  $('settings-card').hidden = !status.paired;

  if (status.ready && !lookedUp) {
    lookedUp = true;
    lookUpSite();
  }
}

async function lookUpSite() {
  const card = $('site-card');
  const list = $('logins');
  card.hidden = false;
  $('site-host').textContent = 'This site';
  list.replaceChildren(Object.assign(document.createElement('div'), { className: 'loader' }));

  const result = await send({ cmd: 'tab:credentials' });
  if (result.status === 'unsupported') {
    card.hidden = true;
    return;
  }
  $('site-host').textContent = result.host || 'This site';
  list.replaceChildren();

  if (result.status !== 'ok') {
    const messages = {
      none: 'No login saved for this site yet.',
      denied: 'Declined on your phone.',
      locked: 'Unlock Safely on your phone first.',
      timeout: 'Your phone did not answer.',
      busy: 'Too many requests — try again in a minute.',
    };
    const empty = document.createElement('p');
    empty.className = 'empty muted small';
    empty.textContent = messages[result.status] || 'Your phone is not reachable right now.';
    list.append(empty);
    $('site-count').textContent = '';
    return;
  }

  $('site-count').textContent = `${result.items.length} login${result.items.length === 1 ? '' : 's'}`;
  result.items.forEach((item, index) => {
    const row = document.createElement('div');
    row.className = 'login';
    row.style.animationDelay = `${index * 60}ms`;

    const avatar = document.createElement('div');
    avatar.className = 'avatar';
    avatar.textContent = (item.title || item.username || '?').trim().charAt(0).toUpperCase();

    const who = document.createElement('div');
    who.className = 'who';
    const name = document.createElement('b');
    name.textContent = item.username || '(no username)';
    const title = document.createElement('span');
    title.textContent = item.title;
    who.append(name, title);

    const copy = document.createElement('button');
    copy.className = 'mini copy';
    copy.textContent = 'Copy';
    copy.addEventListener('click', async () => {
      await navigator.clipboard.writeText(item.password);
      copy.textContent = 'Copied';
      setTimeout(() => (copy.textContent = 'Copy'), 1400);
    });

    const fill = document.createElement('button');
    fill.className = 'mini fill';
    fill.textContent = 'Fill';
    fill.addEventListener('click', async () => {
      await send({ cmd: 'tab:fill', item });
      window.close();
    });

    row.append(avatar, who, copy, fill);
    list.append(row);
  });
}

$('pair').addEventListener('click', () => openPage('pair.html'));
$('setup').addEventListener('click', () => openPage('pair.html'));
$('import').addEventListener('click', () => openPage('import.html'));

for (const [id, key] of [['s-autofill', 'autofill'], ['s-save', 'offerSave']]) {
  $(id).addEventListener('change', (event) => send({ cmd: 'settings:set', settings: { [key]: event.target.checked } }));
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.event === 'status') render(message.status);
});

send({ cmd: 'settings' }).then((settings) => {
  $('s-autofill').checked = settings.autofill;
  $('s-save').checked = settings.offerSave;
});
send({ cmd: 'status' }).then(render);
