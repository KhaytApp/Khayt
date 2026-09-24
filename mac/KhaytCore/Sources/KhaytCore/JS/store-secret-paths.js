'use strict';
/**
 * Every field in the store that holds a credential — in one place.
 *
 * This list used to be written out by hand three times inside store-io.js:
 * once to encrypt on save, once to decrypt on load, once to decide whether
 * saving would touch the OS keychain. Three lists over thirty-two paths, kept
 * in step by care alone, and the failure mode is not subtle:
 *
 *   in encrypt but not decrypt → the app uses "__enc__AAAA…" AS the API key
 *   in neither                → the secret sits on disk in cleartext, and the
 *                               store is the file people copy around
 *
 * The second one has already happened here. `eventWebhooks.secret` was treated
 * as a credential by export redaction and by resolveStoreSecret, but not by the
 * at-rest layer, so it was written in the clear and reached the renderer
 * unmasked. Adding a secret meant remembering five places; it only takes
 * forgetting one.
 *
 * The native macOS app would have made it a sixth. It doesn't: this module is
 * pure data, so it runs unchanged in JavaScriptCore and both apps encrypt
 * exactly the same fields.
 *
 * ADDING A SECRET: add its path here and nowhere else.
 */

/**
 * Dotted paths under the store root. `machines[]` means "every element of the
 * machines array" — the only collection in the store that carries credentials
 * (a printer's API key and its LAN access code).
 */
/*
 * WRAPPED IN AN IIFE, like every other shared module.
 *
 * It declared `const api` at the top level. In a browser that is module-scoped
 * and harmless; in the ONE JavaScriptCore context the Mac app loads every
 * module into, it is a global — and the second module to declare it fails the
 * whole runtime with "Can't create duplicate variable: 'api'", which does not
 * raise anywhere a shop can see: the app comes up with no words, no tax and no
 * writes. `lib/upgrade-backup.js` was the second, the day it was bundled.
 */
(function (global) {

  const SECRET_PATHS = Object.freeze([
    'settings.emailConfig.apiKey',
    'settings.emailConfig.smtpPassword',
    'settings.smsConfig.authToken',
    'settings.smsConfig.token',
    'settings.smsConfig.appSid',
    'settings.smsConfig.secret',
    'settings.accountingSync.secret',
    // The bucket that holds the shop's models.
    'settings.printLibrary.s3.secretAccessKey',
    // The Drive refresh token outranks the bucket secret: a leaked bucket key
    // reaches one bucket, this reaches every file Khayt ever put in their Drive,
    // and it does not expire.
    'settings.printLibrary.gdrive.refreshToken',
    'settings.printLibrary.gdrive.clientSecret',
    'machines[].printerApi.apiKey',
    'machines[].printerApi.accessCode',
    'machines[].smartPlug.token',
    'machines[].smartPlug.password',
    'settings.zatcaPhase2.csid',
    'settings.zatcaPhase2.pcsid',
    'settings.bnpl.tabby.apiKey',
    'settings.bnpl.tamara.apiKey',
    'settings.bnpl.tamara.notificationToken',
    'settings.bnpl.stripe.apiKey',
    'settings.telegram.botToken',
    // An ntfy access token, for a self-hosted server or a protected topic.
    'settings.ntfy.token',
    // A carrier's API key and the secret its status webhooks are signed with.
    // Missing until Sep 2026 while `carriers.js` marked both `secret: true`:
    // written to disk in the clear and handed to the renderer unmasked. Listed
    // per carrier because this list names paths, not patterns —
    // every-secret-is-protected.test.js fails if a carrier gains a secret
    // field that is not here.
    'settings.shipping.smsa.apiKey',
    'settings.shipping.smsa.webhookSecret',
    'settings.shipping.aramex.apiKey',
    'settings.shipping.aramex.webhookSecret',
    'settings.shipping.spl.apiKey',
    'settings.shipping.spl.webhookSecret',
    'settings.lanApi.webhookToken',
    'settings.lanApi.sallaWebhookSecret',
    'settings.lanApi.zidWebhookSecret',
    'settings.lanApi.pin',
    'settings.lanApi.intakeToken',
    'settings.lanApi.intakePin',
    'settings.lanApi.calendarToken',
    'settings.webhooks.secret',
    // An HMAC signing key like webhooks.secret, and the reason this module exists.
    'settings.eventWebhooks.secret',
    'settings.ai.apiKey',
    'settings.cloud.token',
  ]);

  /**
   * Visit every secret that is actually present, in list order.
   *
   * `visit(value, set)` is called only for truthy values; `set(next)` writes back
   * in place. Missing branches are skipped rather than created — a store with no
   * `settings.bnpl` must not grow one just because it was walked.
   */
  function forEachSecret(data, visit) {
    if (!data || typeof data !== 'object' || typeof visit !== 'function') return;
    for (const path of SECRET_PATHS) {
      const [head, tail] = path.includes('[]') ? path.split('[].') : [null, path];
      if (head === null) {
        visitOne(data, tail.split('.'), visit);
      } else {
        const arr = walk(data, head.split('.'));
        if (Array.isArray(arr)) for (const item of arr) visitOne(item, tail.split('.'), visit);
      }
    }
  }

  function walk(obj, keys) {
    let cur = obj;
    for (const k of keys) {
      if (!cur || typeof cur !== 'object') return undefined;
      cur = cur[k];
    }
    return cur;
  }

  function visitOne(root, keys, visit) {
    const parent = walk(root, keys.slice(0, -1));
    if (!parent || typeof parent !== 'object') return;
    const leaf = keys[keys.length - 1];
    const value = parent[leaf];
    if (!value) return;
    visit(value, (next) => { parent[leaf] = next; });
  }

  /* ── DEVICE-PRIVATE: shown here, never sent to a phone or the cloud ──────
   *
   * Not credentials in the SECRET_PATHS sense — the settings screen has to show
   * them, so they are not sealed on disk or masked for the renderer — but each
   * one is, in practice, a password:
   *
   *   settings.ntfy.topic                  on public ntfy.sh the topic IS the
   *                                        only secret: anyone who knows it
   *                                        reads every alert and can post fakes
   *   settings.webhooks.subscriptions[].url  Slack, Discord and most webhook
   *   settings.webhooks.events{}             URLs carry their secret in the path
   *                                        (the second is the legacy one-URL-
   *                                        per-event map; lib/webhook-bus.js)
   *
   * The phone never needs them, and the cloud blob is readable by anyone who
   * holds the shop's passphrase. So /api/store (the Mac's LanServer) and the
   * cloud push (cloud-outbox forCloud, and the desktop's cloud-backend through
   * it) mask these; nothing else does. Decided by the maintainer on 2026-09-24
   * (SEC-011). Grammar: `a.b`, `a.b[].c` (every element), `a.b{}` (every value).
   */
  const DEVICE_PRIVATE_PATHS = Object.freeze([
    'settings.ntfy.topic',
    'settings.webhooks.subscriptions[].url',
    'settings.webhooks.events{}',
  ]);

  /* ── MACHINE-LOCAL: belongs to the computer it was set on ────────────────
   *
   * A slicer's path and its argument template RUN on this computer, and both
   * arrive otherwise in a restored backup or a cloud sync. A genuine slicer
   * given attacker-chosen arguments (PrusaSlicer's `--post-process <cmd>`, or
   * `--load` of a config carrying a post-processing script) runs any command,
   * and no check on the binary can stop that. So a restore or a sync never
   * changes these: each computer sets up its own slicer once. Decided by the
   * maintainer on 2026-09-24 (SEC-014). Cloud pulls already leave settings
   * alone (lib/cloud-inbox.js), so this is for every restore and import.
   */
  const MACHINE_LOCAL_PATHS = Object.freeze([
    'settings.slicers',
    'settings.slicer',
    'settings.slicersAutoDetected',
  ]);

  /** Visit every non-empty string at a DEVICE_PRIVATE path, with a setter. */
  function forEachDevicePrivate(data, visit) {
    if (!data || typeof data !== 'object' || typeof visit !== 'function') return;
    for (const p of DEVICE_PRIVATE_PATHS) {
      const leafStrings = (parent, key) => {
        const v = parent[key];
        if (typeof v === 'string' && v) visit(v, (next) => { parent[key] = next; });
      };
      if (p.endsWith('{}')) {
        const obj = walk(data, p.slice(0, -2).split('.'));
        if (obj && typeof obj === 'object' && !Array.isArray(obj)) for (const k of Object.keys(obj)) leafStrings(obj, k);
      } else if (p.includes('[].')) {
        const [head, tail] = p.split('[].');
        const arr = walk(data, head.split('.'));
        if (Array.isArray(arr)) {
          for (const item of arr) {
            const parent = walk(item, tail.split('.').slice(0, -1));
            if (parent && typeof parent === 'object') leafStrings(parent, tail.split('.').pop());
          }
        }
      } else {
        const keys = p.split('.');
        const parent = walk(data, keys.slice(0, -1));
        if (parent && typeof parent === 'object') leafStrings(parent, keys[keys.length - 1]);
      }
    }
  }

  const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

  /**
   * Make an INCOMING store (a restore, an import, a cloud snapshot) keep what
   * belongs to this computer. Mutates and returns `incoming`.
   *
   *  - MACHINE_LOCAL paths take `local`'s value, whatever came in, including
   *    "absent" when this computer has none.
   *  - A DEVICE_PRIVATE value that arrives as `mask` takes `local`'s value, so a
   *    cloud snapshot never replaces a real topic or URL with the mask. A real
   *    value that arrives (a local backup) is taken as it came.
   *
   * Webhook subscriptions are matched by `id`, then by position; a masked URL
   * with no local counterpart is emptied rather than kept as the mask, because
   * the mask is not an address anything can be delivered to.
   */
  function keepMachineLocal(local, incoming, mask) {
    if (!incoming || typeof incoming !== 'object') return incoming;
    const loc = local && typeof local === 'object' ? local : {};
    for (const p of MACHINE_LOCAL_PATHS) {
      const keys = p.split('.');
      const leaf = keys.pop();
      const lv = walk(loc, keys.concat(leaf));
      let parent = incoming;
      for (const k of keys) {
        if (!parent[k] || typeof parent[k] !== 'object') parent[k] = {};
        parent = parent[k];
      }
      if (lv === undefined) delete parent[leaf]; else parent[leaf] = clone(lv);
    }
    if (mask === undefined) return incoming;
    const lTopic = walk(loc, ['settings', 'ntfy', 'topic']);
    const iNtfy = walk(incoming, ['settings', 'ntfy']);
    if (iNtfy && iNtfy.topic === mask) iNtfy.topic = typeof lTopic === 'string' ? lTopic : '';
    const lSubs = walk(loc, ['settings', 'webhooks', 'subscriptions']);
    const iSubs = walk(incoming, ['settings', 'webhooks', 'subscriptions']);
    if (Array.isArray(iSubs)) {
      iSubs.forEach((sub, i) => {
        if (!sub || sub.url !== mask) return;
        const byId = Array.isArray(lSubs) && sub.id ? lSubs.find((x) => x && x.id === sub.id) : null;
        const mine = byId || (Array.isArray(lSubs) ? lSubs[i] : null);
        sub.url = mine && typeof mine.url === 'string' && mine.url !== mask ? mine.url : '';
      });
    }
    const lEvents = walk(loc, ['settings', 'webhooks', 'events']);
    const iEvents = walk(incoming, ['settings', 'webhooks', 'events']);
    if (iEvents && typeof iEvents === 'object') {
      for (const k of Object.keys(iEvents)) {
        if (iEvents[k] !== mask) continue;
        const mine = lEvents && typeof lEvents[k] === 'string' ? lEvents[k] : '';
        iEvents[k] = mine === mask ? '' : mine;
      }
    }
    return incoming;
  }

  const api = {
    SECRET_PATHS, forEachSecret,
    DEVICE_PRIVATE_PATHS, forEachDevicePrivate,
    MACHINE_LOCAL_PATHS, keepMachineLocal,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStoreSecretPaths = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
