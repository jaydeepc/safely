// Browser side of the Safely protocol: pairing state machine and sealed request/response.
// Transport and storage are injected, so the service worker and the Node end-to-end test share it.

import * as P from './protocol.js';

export class BrowserEngine {
  /**
   * @param {object} io
   * @param {(envelope: Uint8Array) => boolean} io.send            hand an envelope to the transport
   * @param {() => Promise<object|null>} io.loadPairing
   * @param {(pairing: object|null) => Promise<void>} io.savePairing
   * @param {(event: object) => void} [io.onPairingEvent]
   * @param {() => void} [io.onUnpaired]
   */
  constructor(io) {
    this.io = io;
    this.pairing = undefined; // undefined = not loaded yet, null = not paired
    this.pending = new Map();
    this.pairState = null;
  }

  async getPairing() {
    if (this.pairing === undefined) this.pairing = (await this.io.loadPairing()) || null;
    return this.pairing;
  }

  // ───────────────────────────── incoming ─────────────────────────────

  async receive(envelope) {
    if (envelope[0] === P.ENVELOPE_PLAIN) {
      const message = P.parsePlain(envelope);
      if (message) await this.#handlePairingMessage(message);
      return;
    }
    const keyId = P.sealedKeyId(envelope);
    if (!keyId) return;

    // A phone confirming a pairing that is still in progress
    if (this.pairState?.key && P.sameBytes(keyId, this.pairState.keyId)) {
      try {
        const message = await P.open(this.pairState.key, envelope);
        if (message.t === 'pair_confirm') {
          this.pairState.phoneConfirmed = true;
          this.pairState.phoneName = message.name || this.pairState.phoneName;
          this.pairState.lastCtr = message.ctr || 0;
          await this.#maybeFinishPairing();
        }
      } catch { /* not for us */ }
      return;
    }

    const pairing = await this.getPairing();
    if (!pairing || !P.sameBytes(keyId, pairing.keyId)) return;
    let message;
    try {
      message = await P.open(pairing.key, envelope);
    } catch {
      return;
    }
    if (typeof message.ctr !== 'number' || message.ctr <= (pairing.lastCtr || 0)) return; // replay
    pairing.lastCtr = message.ctr;
    await this.io.savePairing(pairing);

    if (message.t === 'unpair') {
      this.pairing = null;
      await this.io.savePairing(null);
      this.io.onUnpaired?.();
      return;
    }
    const waiter = message.id && this.pending.get(message.id);
    if (waiter) {
      this.pending.delete(message.id);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    }
  }

  // ───────────────────────────── requests ─────────────────────────────

  /** Sends a sealed message and resolves with the phone's reply (matched by id). */
  async request(message, timeoutMs = 15000) {
    const pairing = await this.getPairing();
    if (!pairing) throw new Error('not-paired');
    const id = P.randomId();
    const envelope = await P.seal(pairing.key, pairing.keyId, { ...message, id, ctr: P.nextCtr() });
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error('timeout'));
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });
      if (!this.io.send(envelope)) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error('not-connected'));
      }
    });
  }

  async unpair() {
    const pairing = await this.getPairing();
    if (!pairing) return;
    try {
      this.io.send(await P.seal(pairing.key, pairing.keyId, { t: 'unpair', ctr: P.nextCtr() }));
    } catch { /* best effort */ }
    this.pairing = null;
    await this.io.savePairing(null);
  }

  // ───────────────────────────── pairing ─────────────────────────────
  //
  //  browser                                   phone
  //    │ pair_commit { SHA256(pub ‖ nonce) }     │   browser is now locked to its key
  //    │────────────────────────────────────────▶│
  //    │                     pair_pub { pub }    │
  //    │◀────────────────────────────────────────│
  //    │ pair_reveal { pub, nonce }              │   phone checks the commitment
  //    │────────────────────────────────────────▶│
  //    │   both show SAS(pubB, pubP, nonce) — the person compares the six digits
  //    │                 sealed pair_confirm     │
  //    │◀────────────────────────────────────────│

  async startPairing(browserName) {
    this.cancelPairing();
    const keys = await P.createPairingKeys();
    this.pairState = {
      ...keys,
      keyId: await P.keyIdOf(keys.publicKey),
      stage: 'waiting-phone',
      userConfirmed: false,
      phoneConfirmed: false,
      timer: setTimeout(() => this.#failPairing('The phone did not answer. Is Safely open on “Pair a browser”?'), 60000),
    };
    const sent = this.io.send(P.plainEnvelope({ t: 'pair_commit', commit: P.toBase64(keys.commit), name: browserName }));
    if (!sent) this.#failPairing('Your Safely Key is not connected.');
  }

  confirmPairing() {
    if (!this.pairState || this.pairState.stage !== 'compare') return;
    this.pairState.userConfirmed = true;
    return this.#maybeFinishPairing();
  }

  cancelPairing(tellPhone = false) {
    if (!this.pairState) return;
    if (tellPhone) this.io.send(P.plainEnvelope({ t: 'pair_cancel', reason: 'Cancelled in the browser.' }));
    clearTimeout(this.pairState.timer);
    this.pairState = null;
  }

  pairingSnapshot() {
    const s = this.pairState;
    if (!s) return { stage: 'idle' };
    return { stage: s.stage, code: s.code, phoneName: s.phoneName, userConfirmed: s.userConfirmed, phoneConfirmed: s.phoneConfirmed };
  }

  async #handlePairingMessage(message) {
    const s = this.pairState;
    if (!s) return;
    if (message.t === 'pair_pub' && s.stage === 'waiting-phone') {
      let phonePublicKey;
      try {
        phonePublicKey = P.fromBase64(message.pub);
        s.key = await P.deriveSessionKey(s.privateKey, s.publicKey, phonePublicKey);
      } catch {
        return this.#failPairing('The phone sent an invalid key.');
      }
      s.phoneName = String(message.name || 'Phone').slice(0, 60);
      s.code = await P.sas(s.publicKey, phonePublicKey, s.nonce);
      s.stage = 'compare';
      this.io.send(P.plainEnvelope({ t: 'pair_reveal', pub: P.toBase64(s.publicKey), nonce: P.toBase64(s.nonce) }));
      this.io.onPairingEvent?.(this.pairingSnapshot());
    } else if (message.t === 'pair_cancel') {
      this.#failPairing(message.reason || 'Pairing was rejected on the phone.');
    }
  }

  async #maybeFinishPairing() {
    const s = this.pairState;
    if (!s) return;
    if (s.userConfirmed && s.phoneConfirmed) {
      clearTimeout(s.timer);
      this.pairing = { keyId: s.keyId, key: s.key, phoneName: s.phoneName, pairedAt: Date.now(), lastCtr: s.lastCtr || 0 };
      await this.io.savePairing(this.pairing);
      this.pairState = null;
      this.io.onPairingEvent?.({ stage: 'done', phoneName: this.pairing.phoneName });
    } else {
      this.io.onPairingEvent?.(this.pairingSnapshot());
    }
  }

  #failPairing(reason) {
    if (!this.pairState) return;
    clearTimeout(this.pairState.timer);
    this.pairState = null;
    this.io.onPairingEvent?.({ stage: 'failed', reason });
  }
}
