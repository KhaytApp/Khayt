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

  const api = { SECRET_PATHS, forEachSecret };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStoreSecretPaths = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
