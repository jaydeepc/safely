// Shhlock content script: finds login forms, asks the service worker for credentials (which asks the
// phone through the Shhlock Key), fills them, and offers to save logins that were typed by hand.
// All UI lives in a closed shadow root so pages cannot read or restyle it.

(() => {
  if (window.__safelyLoaded) return;
  window.__safelyLoaded = true;

  const isTop = window === window.top;
  const secure = location.protocol === 'https:' || ['localhost', '127.0.0.1'].includes(location.hostname);

  let settings = { autofill: true, offerSave: true };
  let items = null; // credentials for this origin, memory only
  let phase = 'idle'; // idle | asking | ok | none | offline | not-paired | denied | locked | timeout | busy
  let autoFilled = false;
  let activeField = null;

  const send = (message) =>
    new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage(message, (reply) => resolve(chrome.runtime.lastError ? null : reply));
      } catch {
        resolve(null); // extension was reloaded
      }
    });

  // ───────────────────────────── form detection ─────────────────────────────

  function isVisible(el) {
    if (!el.isConnected || el.disabled || el.readOnly) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 30 || rect.height < 10) return false;
    const style = getComputedStyle(el);
    return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
  }

  const isTextLike = (el) => el instanceof HTMLInputElement && ['text', 'email', 'tel', ''].includes(el.type);

  function passwordFields() {
    return [...document.querySelectorAll('input[type="password"]')].filter(isVisible);
  }

  function usernameFor(password) {
    const scope = password.form || document;
    let best = null;
    for (const candidate of scope.querySelectorAll('input')) {
      if (!isTextLike(candidate) || !isVisible(candidate)) continue;
      if (candidate.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING) best = candidate;
    }
    return best;
  }

  /** The field that identifies the account: an e-mail / username field if the form has one, else the text field above the password. */
  function accountField(password) {
    const scope = password.form || document;
    const hinted = [...scope.querySelectorAll('input[type="email"], input[autocomplete~="username"], input[autocomplete~="email"], input[name*="email" i], input[id*="email" i], input[name*="user" i], input[id*="user" i], input[name*="login" i], input[id*="login" i]')]
      .filter((el) => isTextLike(el) && isVisible(el) && el.value);
    return hinted[0] || usernameFor(password);
  }

  /** First step of a two step login (username now, password on the next screen). */
  function loneUsernameField() {
    const hinted = [...document.querySelectorAll('input[autocomplete~="username"], input[type="email"], input[name*="user" i], input[name*="email" i], input[name*="login" i], input[id*="user" i], input[id*="email" i], input[name="identifier"]')];
    return hinted.find((el) => isTextLike(el) && isVisible(el) && !/search|newsletter|subscribe/i.test(`${el.name} ${el.id} ${el.placeholder}`)) || null;
  }

  function loginTarget() {
    const passwords = passwordFields();
    const signup = passwords.length > 1 || passwords.some((p) => p.autocomplete === 'new-password');
    if (passwords.length) return { password: passwords[0], username: usernameFor(passwords[0]), signup };
    const username = loneUsernameField();
    return username ? { password: null, username, signup: false } : null;
  }

  const isLoginField = (el) => {
    const target = loginTarget();
    return !!target && (el === target.password || el === target.username);
  };

  // ───────────────────────────── filling ─────────────────────────────

  const nativeValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

  function setValue(el, value) {
    nativeValueSetter.call(el, value); // bypasses React/Vue value tracking, then tell them about it
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    const previous = { boxShadow: el.style.boxShadow, transition: el.style.transition };
    el.style.transition = 'box-shadow .35s ease';
    el.style.boxShadow = '0 0 0 3px rgba(255,79,121,.35), 0 0 18px rgba(255,154,61,.35)';
    setTimeout(() => {
      el.style.boxShadow = previous.boxShadow;
      setTimeout(() => (el.style.transition = previous.transition), 400);
    }, 1100);
  }

  function fill(item, announce = true) {
    const target = loginTarget();
    if (!target) return false;
    if (target.username && item.username) setValue(target.username, item.username);
    if (target.password) setValue(target.password, item.password);
    hideChooser();
    if (announce) toast('Filled by Shhlock', item.username || item.title);
    return true;
  }

  // ───────────────────────────── asking the phone ─────────────────────────────

  async function ask(reason) {
    if (phase === 'asking') return;
    phase = 'asking';
    renderBadge();
    const reply = await send({ cmd: 'credentials', reason });
    phase = reply?.status || 'offline';
    items = phase === 'ok' ? reply.items : null;
    renderBadge();

    const target = loginTarget();
    if (phase === 'ok' && target) {
      const empty = !(target.password?.value || (!target.password && target.username?.value));
      if (reason === 'auto' && settings.autofill && items.length === 1 && !target.signup && empty && !autoFilled) {
        autoFilled = true;
        fill(items[0]);
      } else if (reason === 'user' || document.activeElement === target.password || document.activeElement === target.username) {
        showChooser();
      }
    } else if (reason === 'user') {
      showChooser();
    }
  }

  let scanTimer = null;
  function scanSoon() {
    clearTimeout(scanTimer);
    scanTimer = setTimeout(() => {
      if (phase === 'idle' && secure && loginTarget()) ask('auto');
    }, 350);
  }

  // ───────────────────────────── UI ─────────────────────────────

  // Built node by node: pages that enforce Trusted Types reject innerHTML, even from extensions.
  const SVG_NS = 'http://www.w3.org/2000/svg';
  function svg(tag, attrs, ...children) {
    const node = document.createElementNS(SVG_NS, tag);
    for (const [name, value] of Object.entries(attrs)) node.setAttribute(name, value);
    node.append(...children);
    return node;
  }

  function shield() {
    return svg('svg', { viewBox: '0 0 24 24', fill: 'none' },
      svg('path', { d: 'M8 10.5V7.6a4 4 0 0 1 8 0v2.9', stroke: '#FFCC33', 'stroke-width': 2.6, 'stroke-linecap': 'round' }),
      svg('rect', { x: 4.5, y: 9.6, width: 15, height: 12, rx: 4.2, fill: 'url(#shlok-g)' }),
      svg('circle', { cx: 12, cy: 14.4, r: 1.7, fill: '#5B2FD6' }),
      svg('path', { d: 'M11.2 15.3h1.6l.5 3.1h-2.6l.5-3.1Z', fill: '#5B2FD6' }),
      svg('defs', {},
        svg('linearGradient', { id: 'shlok-g', x1: 4, y1: 9, x2: 20, y2: 22 },
          svg('stop', { 'stop-color': '#FF4F79' }),
          svg('stop', { offset: 1, 'stop-color': '#FF9A3D' }))));
  }

  function tick() {
    return svg('svg', { viewBox: '0 0 16 16', fill: 'none', stroke: '#fff', 'stroke-width': 2.4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' },
      svg('path', { d: 'm3.5 8.5 3 3 6-7' }));
  }

  const CSS = `
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, Roboto, sans-serif; }
    .badge { position: fixed; z-index: 2147483646; width: 26px; height: 26px; padding: 3px; border: 0; border-radius: 9px; cursor: pointer;
      background: #fff; box-shadow: 0 2px 10px rgba(43,26,63,.18), 0 0 0 1px rgba(255,79,121,.18);
      transition: transform .18s cubic-bezier(.34,1.56,.64,1), opacity .18s; animation: pop .28s cubic-bezier(.34,1.56,.64,1); }
    .badge:hover { transform: scale(1.12); }
    .badge svg { width: 100%; height: 100%; display: block; }
    .badge.asking { animation: pulse 1.1s ease-in-out infinite; }
    .badge.off { filter: grayscale(1); opacity: .75; }
    .badge .count { position: absolute; top: -5px; right: -5px; min-width: 15px; height: 15px; padding: 0 4px; border-radius: 8px;
      background: #FF4F79; color: #fff; font-size: 10px; font-weight: 700; line-height: 15px; text-align: center; }
    .card { position: fixed; z-index: 2147483647; width: 300px; max-width: calc(100vw - 24px); padding: 8px; border-radius: 16px; background: rgba(255,255,255,.97);
      backdrop-filter: blur(14px); box-shadow: 0 18px 50px rgba(43,26,63,.22), 0 0 0 1px rgba(255,79,121,.14); color: #2B1A3F;
      animation: rise .22s cubic-bezier(.2,.9,.3,1.2); }
    .head { display: flex; align-items: center; gap: 8px; padding: 6px 8px 8px; font-size: 12px; font-weight: 600; color: #80708F; letter-spacing: .02em; }
    .head svg { width: 16px; height: 16px; }
    .row { display: flex; align-items: center; gap: 10px; width: 100%; padding: 9px 8px; border: 0; border-radius: 11px; background: transparent; cursor: pointer; text-align: left;
      transition: background .15s, transform .15s; animation: rise .3s both; }
    .row:hover, .row:focus-visible { background: #FFF0E8; transform: translateX(2px); outline: none; }
    .avatar { flex: none; width: 32px; height: 32px; border-radius: 10px; display: grid; place-items: center; color: #fff; font-weight: 700; font-size: 14px;
      background: linear-gradient(135deg, #FF4F79, #FF9A3D); }
    .row:nth-of-type(3n+2) .avatar { background: linear-gradient(135deg, #7C4DFF, #FF5CA8); }
    .row:nth-of-type(3n) .avatar { background: linear-gradient(135deg, #33ADFF, #19D3A2); }
    .avatar.spark { background: linear-gradient(135deg, #FFCC33, #FF9A3D); font-size: 16px; }
    .who { min-width: 0; }
    .who b { display: block; font-size: 13.5px; font-weight: 600; color: #2B1A3F; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .who span { display: block; font-size: 12px; color: #80708F; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .note { padding: 8px 10px 10px; font-size: 13px; line-height: 1.45; color: #6B5A7D; }
    .note b { color: #2B1A3F; }
    .toast { position: fixed; z-index: 2147483647; right: 20px; bottom: 20px; display: flex; align-items: center; gap: 10px; padding: 10px 16px 10px 10px; border-radius: 999px;
      background: #fff; color: #2B1A3F; font-size: 13px; box-shadow: 0 12px 36px rgba(43,26,63,.2), 0 0 0 1px rgba(255,154,61,.35);
      animation: slide .4s cubic-bezier(.2,.9,.3,1.2), fade .35s 2.4s forwards; }
    .toast .tick { width: 26px; height: 26px; border-radius: 50%; background: linear-gradient(135deg, #19D3A2, #33ADFF); display: grid; place-items: center; }
    .toast .tick svg { width: 14px; height: 14px; stroke-dasharray: 20; stroke-dashoffset: 20; animation: draw .4s .2s forwards; }
    .toast small { display: block; color: #80708F; font-size: 11.5px; }
    .save { top: 16px; right: 16px; width: 320px; padding: 14px; }
    .save h4 { margin: 0 0 2px; font-size: 14px; display: flex; align-items: center; gap: 8px; }
    .save h4 svg { width: 20px; height: 20px; }
    .save p { margin: 0 0 12px 28px; font-size: 12.5px; color: #80708F; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .actions { display: flex; gap: 8px; justify-content: flex-end; }
    .btn { border: 0; border-radius: 10px; padding: 8px 14px; font-size: 13px; font-weight: 600; cursor: pointer; transition: transform .15s, box-shadow .15s; }
    .btn:active { transform: scale(.96); }
    .btn.primary { color: #fff; background: linear-gradient(135deg, #FF4F79, #EE3366); box-shadow: 0 6px 16px rgba(255,79,121,.35); }
    .btn.ghost { color: #6B5A7D; background: #F8ECEE; }
    @keyframes pop { from { transform: scale(0); opacity: 0; } }
    @keyframes rise { from { transform: translateY(8px); opacity: 0; } }
    @keyframes slide { from { transform: translateY(24px) scale(.9); opacity: 0; } }
    @keyframes fade { to { opacity: 0; transform: translateY(10px); } }
    @keyframes draw { to { stroke-dashoffset: 0; } }
    @keyframes pulse { 50% { transform: scale(1.14); box-shadow: 0 2px 14px rgba(255,79,121,.5), 0 0 0 5px rgba(255,79,121,.12); } }
    @media (prefers-reduced-motion: reduce) { * { animation-duration: .01s !important; transition: none !important; } }
  `;

  let root = null;
  let hostEl = null;
  let badge = null;
  let chooser = null;

  function ui() {
    if (root) return root;
    const host = (hostEl = document.createElement('safely-ui'));
    host.style.cssText = 'all: initial; position: fixed; top: 0; left: 0; width: 0; height: 0; z-index: 2147483647;';
    root = host.attachShadow({ mode: 'closed' });
    const style = document.createElement('style');
    style.textContent = CSS;
    root.append(style);
    document.documentElement.append(host);
    return root;
  }

  function el(tag, className, ...children) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    node.append(...children);
    return node;
  }

  function text(tag, value) {
    const node = document.createElement(tag);
    node.textContent = value;
    return node;
  }

  function placeBadge() {
    if (!badge || !activeField?.isConnected) return;
    const rect = activeField.getBoundingClientRect();
    badge.style.top = `${rect.top + (rect.height - 26) / 2}px`;
    badge.style.left = `${rect.right - 26 - Math.min(10, rect.height / 4) - (activeField.type === 'password' ? 28 : 0)}px`;
  }

  function renderBadge() {
    if (!activeField || !isVisible(activeField)) {
      badge?.remove();
      badge = null;
      return;
    }
    if (!badge) {
      badge = el('button', 'badge');
      badge.type = 'button';
      badge.title = 'Shhlock';
      badge.addEventListener('mousedown', (event) => event.preventDefault()); // keep focus in the field
      badge.addEventListener('click', () => {
        if (chooser) hideChooser();
        else if (phase === 'ok' || loginTarget()?.signup) showChooser();
        else ask('user');
      });
      ui().append(badge);
    }
    badge.className = `badge ${phase === 'asking' ? 'asking' : ''} ${['ok', 'asking', 'idle', 'none'].includes(phase) ? '' : 'off'}`;
    badge.replaceChildren(shield());
    if (phase === 'ok' && items.length) badge.append(el('span', 'count', String(items.length)));
    placeBadge();
  }

  const NOTES = {
    none: ['No saved login for this site.', 'Sign in once and Shhlock will offer to keep it on your phone.'],
    offline: ['Your phone is not in reach.', 'Keep your Shhlock Key nearby and Bluetooth on — it reconnects on its own.'],
    'not-paired': ['Not paired yet.', 'Click the Shhlock icon in the toolbar and pair this browser with your phone.'],
    denied: ['Declined on your phone.', ''],
    locked: ['Shhlock is locked.', 'Unlock the app on your phone, then try again.'],
    timeout: ['No answer from your phone.', 'Open Shhlock on your phone and try again.'],
    busy: ['Too many requests.', 'Try again in a minute.'],
    unsupported: ['Shhlock only fills on web pages.', ''],
    asking: ['Asking your phone…', ''],
  };

  function strongPassword(length = 20) {
    const sets = ['abcdefghijkmnopqrstuvwxyz', 'ABCDEFGHJKLMNPQRSTUVWXYZ', '23456789', '!@#$%&*-_+?'];
    const all = sets.join('');
    const pick = (chars) => chars[crypto.getRandomValues(new Uint32Array(1))[0] % chars.length];
    const out = sets.map(pick);
    while (out.length < length) out.push(pick(all));
    for (let i = out.length - 1; i > 0; i--) {
      const j = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1);
      [out[i], out[j]] = [out[j], out[i]];
    }
    return out.join('');
  }

  function suggestRow() {
    const row = el('button', 'row');
    row.type = 'button';
    const avatar = text('div', '✦');
    avatar.className = 'avatar spark';
    const who = el('div', 'who');
    who.append(text('b', 'Use a strong password'), text('span', 'Shhlock offers to save it when you sign up'));
    row.append(avatar, who);
    row.addEventListener('mousedown', (event) => event.preventDefault());
    row.addEventListener('click', () => {
      const password = strongPassword();
      for (const field of passwordFields()) setValue(field, password);
      hideChooser();
      toast('Strong password filled', 'Finish signing up and save it to your phone');
    });
    return row;
  }

  function showChooser() {
    hideChooser();
    const target = loginTarget();
    const anchor = activeField?.isConnected ? activeField : target?.password || target?.username;
    if (!anchor) return;
    chooser = el('div', 'card');
    chooser.append(el('div', 'head', shield(), text('span', `SHHLOCK · ${location.hostname}`)));
    if (target?.signup) chooser.append(suggestRow());
    if (target?.signup && !(phase === 'ok' && items?.length)) {
      // a sign-up form needs no answer from the phone
    } else if (phase === 'ok' && items?.length) {
      items.forEach((item, index) => {
        const row = el('button', 'row');
        row.type = 'button';
        row.style.animationDelay = `${index * 45}ms`;
        const avatar = text('div', (item.title || item.username || '?').trim().charAt(0).toUpperCase());
        avatar.className = 'avatar';
        const who = el('div', 'who');
        who.append(text('b', item.username || '(no username)'), text('span', item.title || ''));
        row.append(avatar, who);
        row.addEventListener('mousedown', (event) => event.preventDefault());
        row.addEventListener('click', () => fill(item));
        chooser.append(row);
      });
    } else {
      const [headline, detail] = NOTES[phase] || NOTES.offline;
      chooser.append(el('div', 'note', text('b', headline), document.createElement('br'), detail));
    }
    const rect = anchor.getBoundingClientRect();
    chooser.style.left = `${Math.max(12, Math.min(rect.left, innerWidth - 312))}px`;
    const below = rect.bottom + 8;
    if (below + 220 < innerHeight) chooser.style.top = `${below}px`;
    else chooser.style.bottom = `${Math.max(12, innerHeight - rect.top + 8)}px`;
    ui().append(chooser);
  }

  function hideChooser() {
    chooser?.remove();
    chooser = null;
  }

  function toast(title, detail) {
    const node = el('div', 'toast', el('div', 'tick', tick()));
    const body = document.createElement('div');
    body.append(text('b', title));
    if (detail) body.append(text('small', detail));
    node.append(body);
    ui().append(node);
    setTimeout(() => node.remove(), 2900);
  }

  // ───────────────────────────── save prompt ─────────────────────────────

  let saveCard = null;

  function showSavePrompt(offer) {
    if (saveCard || (!isTop && (innerWidth < 340 || innerHeight < 160))) return;
    saveCard = el('div', 'card save');
    const title = el('h4', '', shield(), text('span', offer.update ? 'Update this password in Shhlock?' : 'Save this login to Shhlock?'));
    const who = text('p', `${offer.username || '(no username)'} · ${offer.host}`);
    const actions = el('div', 'actions');
    const later = text('button', 'Not now');
    later.className = 'btn ghost';
    const save = text('button', offer.update ? 'Update on phone' : 'Save to phone');
    save.className = 'btn primary';
    const close = () => {
      saveCard?.remove();
      saveCard = null;
    };
    later.addEventListener('click', () => {
      send({ cmd: 'save:dismiss' });
      close();
    });
    save.addEventListener('click', async () => {
      save.textContent = 'Sending…';
      save.disabled = true;
      const reply = await send({ cmd: 'save:confirm' });
      close();
      if (reply?.status === 'ok') toast(offer.update ? 'Password updated on your phone' : 'Saved to your phone', offer.username);
      else if (reply?.status === 'denied') toast('Could not save', 'Declined on the phone');
      else toast('Phone not reachable', 'Shhlock will ask again on the next page');
    });
    actions.append(later, save);
    saveCard.append(title, who, actions);
    ui().append(saveCard);
  }

  let lastCaptured = '';
  function captureLogin() {
    if (!settings.offerSave) return;
    const filled = passwordFields().filter((p) => p.value);
    if (!filled.length || filled.length > 3) return;
    // old / new / confirm → the new one; password / confirm → either
    const password = filled.length === 3 ? filled[1] : filled[0];
    const username = accountField(password)?.value || '';
    const fingerprint = `${username}\n${password.value}`;
    if (fingerprint === lastCaptured) return;
    if (items?.some((item) => item.username === username && item.password === password.value)) return; // already in the vault
    lastCaptured = fingerprint;
    const offer = { username, password: password.value, update: !!items?.some((item) => item.username === username) };
    send({ cmd: 'save:stash', offer }).then((reply) => {
      // Single page apps do not navigate after login; classic sites show the prompt on the next page instead.
      if (reply?.ok) setTimeout(() => showSavePrompt({ ...offer, host: location.host }), 1200);
    });
  }

  // ───────────────────────────── wiring ─────────────────────────────

  document.addEventListener('focusin', (event) => {
    const field = event.target;
    if (!(field instanceof HTMLInputElement) || !isLoginField(field)) return;
    activeField = field;
    renderBadge();
    if (phase === 'idle' && secure) ask('auto');
    else if (phase === 'ok' && items.length > 1 && !field.value) showChooser();
  }, true);

  document.addEventListener('focusout', () => {
    setTimeout(() => {
      if (document.activeElement !== activeField && !chooser) {
        activeField = null;
        renderBadge();
      }
    }, 150);
  }, true);

  document.addEventListener('mousedown', (event) => {
    // Our UI lives in a closed shadow root, so a click on a chooser row arrives here with the host
    // element as its target. Treating that as "clicked elsewhere" removed the row before its click fired.
    if (event.target === hostEl) return;
    if (chooser && event.target !== activeField) hideChooser();
  }, true);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hideChooser();
    if (event.key === 'Enter' && event.target instanceof HTMLInputElement && event.target.type === 'password') captureLogin();
  }, true);
  document.addEventListener('submit', captureLogin, true);
  document.addEventListener('click', (event) => {
    const button = event.target instanceof Element && event.target.closest('button, input[type="submit"], [role="button"]');
    if (button && passwordFields().some((p) => p.value) && (button.form || button.closest('form') || /log|sign|continue|next|create|register|join|submit|start/i.test(button.textContent || button.value || ''))) captureLogin();
  }, true);

  addEventListener('scroll', () => { placeBadge(); hideChooser(); }, true);
  addEventListener('resize', () => { placeBadge(); hideChooser(); });

  new MutationObserver(scanSoon).observe(document.documentElement, { childList: true, subtree: true });

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.cmd === 'fill' && isTop) {
      sendResponse({ ok: fill(message.item) });
    } else if (message.event === 'ready' && ['offline', 'timeout'].includes(phase)) {
      phase = 'idle'; // the phone came back into range
      scanSoon();
    }
  });

  (async () => {
    settings = (await send({ cmd: 'settings' })) || settings;
    scanSoon();
    if (isTop) {
      const offer = await send({ cmd: 'save:pending' });
      if (offer) showSavePrompt(offer);
    }
  })();
})();
