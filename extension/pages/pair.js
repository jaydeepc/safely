const $ = (id) => document.getElementById(id);
const send = (message) => chrome.runtime.sendMessage(message);

let status = null;
let pairing = { stage: 'idle' };

function setStep(id, state) {
  $(id).classList.toggle('active', state === 'active');
  $(id).classList.toggle('done', state === 'done');
}

function render() {
  if (!status) return;
  $('wizard').hidden = status.paired;
  $('done').hidden = !status.paired;
  if (status.paired) {
    $('phone-name').textContent = status.phoneName || 'your phone';
    return;
  }

  const helperOk = status.host === 'ok';
  const linkOk = helperOk && status.key && status.phone;
  setStep('step-helper', helperOk ? 'done' : 'active');
  setStep('step-link', !helperOk ? 'todo' : linkOk ? 'done' : 'active');
  setStep('step-pair', linkOk ? 'active' : 'todo');

  const linkText = $('link-text');
  if (status.bluetooth === 'off') linkText.textContent = 'Bluetooth is off on this computer — turn it on.';
  else if (status.bluetooth === 'unauthorized') linkText.textContent = 'Chrome is not allowed to use Bluetooth. Enable it in System Settings → Privacy & Security → Bluetooth.';
  else if (!status.key) linkText.textContent = 'Looking for your Safely Key… plug it into any USB power source or battery.';
  else if (!status.phone) linkText.textContent = 'Key connected. Now open Safely on your phone so it joins the key.';

  $('pair-intro').hidden = pairing.stage !== 'idle' && pairing.stage !== 'failed';
  $('pair-wait').hidden = pairing.stage !== 'waiting-phone';
  $('pair-compare').hidden = pairing.stage !== 'compare';
  $('error').hidden = pairing.stage !== 'failed';
  if (pairing.stage === 'failed') $('error').textContent = pairing.reason;

  if (pairing.stage === 'compare') {
    const code = $('code');
    if (code.dataset.value !== pairing.code) {
      code.dataset.value = pairing.code;
      code.replaceChildren(
        ...[...pairing.code].map((digit, i) => {
          const cell = document.createElement('b');
          cell.textContent = digit;
          cell.style.animationDelay = `${i * 70}ms`;
          return cell;
        }),
      );
    }
    $('confirm').disabled = pairing.userConfirmed;
    $('confirm').textContent = pairing.userConfirmed ? 'Waiting for phone…' : 'Yes, they match';
    $('phone-state').textContent = pairing.phoneConfirmed ? 'Confirmed on the phone ✓' : 'Confirm on the phone too.';
  }
}

async function refresh() {
  status = await send({ cmd: 'status' });
  render();
}

$('start').addEventListener('click', async () => {
  pairing = await send({ cmd: 'pair:start' });
  render();
});
$('confirm').addEventListener('click', async () => {
  pairing = { ...pairing, ...(await send({ cmd: 'pair:confirm' })) };
  await refresh();
});
$('reject').addEventListener('click', async () => {
  pairing = await send({ cmd: 'pair:cancel' });
  render();
});
$('go-import').addEventListener('click', () => (location.href = 'import.html'));
$('unpair').addEventListener('click', async () => {
  if (!confirm('Unpair this browser from your phone?')) return;
  await send({ cmd: 'unpair' });
  pairing = { stage: 'idle' };
  await refresh();
});

chrome.runtime.onMessage.addListener((message) => {
  if (message.event === 'status') {
    status = message.status;
    render();
  } else if (message.event === 'pairing') {
    pairing = message;
    if (message.stage === 'done') refresh();
    else render();
  }
});

send({ cmd: 'pair:state' }).then((state) => {
  pairing = state;
  refresh();
});
setInterval(refresh, 4000); // also wakes the worker so it retries the helper after installation
