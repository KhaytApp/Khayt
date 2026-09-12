const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const P = require('../lib/ai-privacy.js');
const reply = require('../lib/ai-reply.js');
const assistant = require('../lib/ai-assistant.js');
const tools = require('../lib/ai-tools.js');

const ROOT = path.join(__dirname, '..');

/**
 * AI used to be one global toggle labelled "AI quote" gating four features that
 * transmit very different things — while the privacy screen told the owner
 * "Customer data stays on this machine". That stopped being true when reply
 * drafting shipped: buildReplyRequest() sends the customer's name to Anthropic.
 *
 * These tests pin two promises: the disclosure matches what the request
 * builders actually send, and consent for customer data is never inherited
 * from a toggle that never mentioned it.
 */

test('every AI task has a disclosure row', () => {
  // A new feature in ai-tools.js without a row here would transmit undisclosed.
  assert.deepEqual(Object.keys(P.AI_FEATURES).sort(), Object.keys(tools.AI_TASKS).sort());
});

test('each row declares a known data class and a non-empty field list', () => {
  const classes = new Set(Object.values(P.DATA_CLASS));
  for (const [id, f] of Object.entries(P.AI_FEATURES)) {
    assert.ok(classes.has(f.dataClass), `${id} has unknown data class ${f.dataClass}`);
    assert.ok(Array.isArray(f.sends) && f.sends.length, `${id} discloses nothing`);
    assert.ok(f.labelKey && f.sendsKey, `${id} missing locale keys`);
  }
});

test('reply is classified as customer data because it really sends a name', () => {
  // Ground the classification in the builder, so the two cannot drift apart.
  const req = reply.buildReplyRequest({
    order: { id: 'o1', project: 'Sign', status: 'printing', price: 100 },
    client: { name: 'Layla Al-Otaibi' },
    intent: 'status_update',
  });
  assert.match(req, /Layla Al-Otaibi/, 'buildReplyRequest sends the customer name');
  assert.equal(P.AI_FEATURES.reply.dataClass, P.DATA_CLASS.CUSTOMER);
  assert.deepEqual(P.customerDataFeatures(), ['reply']);
});

test('the assistant summary carries no client names — its row must not claim otherwise', () => {
  // This is the claim "order and client counts (not names)" in the disclosure.
  const ctx = assistant.buildShopContext({
    printLog: [{ id: 'o1', status: 'printing', project: 'Sign', price: 100, clientId: 'c1' }],
    clients: [{ id: 'c1', name: 'Layla Al-Otaibi', email: 'l@example.com', phone: '+9665' }],
    inventory: [],
    settings: {},
  }, { now: Date.now() });
  const blob = JSON.stringify(ctx);
  assert.equal(/Layla|example\.com|\+9665/.test(blob), false,
    'assistant context leaked client PII: ' + blob);
  assert.equal(P.AI_FEATURES.assistant.dataClass, P.DATA_CLASS.BUSINESS);
});

test('the quote feature sends only the owner’s own input', () => {
  assert.equal(P.AI_FEATURES.quote.dataClass, P.DATA_CLASS.OWN);
});

test('the old global toggle does not carry consent for customer data', () => {
  // An owner who ticked "AI quote" never agreed to send a customer's name.
  const { features, reconsentRequired } = P.migrateConsent({ enabled: true, apiKey: 'k' });
  assert.equal(features.quote, true);
  assert.equal(features.price, true);
  assert.equal(features.assistant, true);
  assert.equal(features.reply, false, 'reply must not inherit the old toggle');
  assert.deepEqual(reconsentRequired, ['reply']);
});

test('an owner who never enabled AI gets everything off and no re-consent notice', () => {
  const { features, reconsentRequired } = P.migrateConsent({ enabled: false });
  assert.deepEqual(Object.values(features), [false, false, false, false]);
  // Nothing broke for them, so there is nothing to explain.
  assert.deepEqual(reconsentRequired, []);
});

test('migration is idempotent — a saved choice is never re-disabled', () => {
  // Re-running on an already-migrated store must not undo a later opt-in.
  const saved = { enabled: true, features: { quote: true, price: false, reply: true, assistant: false } };
  const once = P.migrateConsent(saved);
  assert.equal(once.features.reply, true, 're-migration turned off an explicit opt-in');
  assert.deepEqual(once.reconsentRequired, []);
  const twice = P.migrateConsent({ ...saved, features: once.features });
  assert.deepEqual(twice.features, once.features);
});

test('a feature needs BOTH the master switch and its own consent', () => {
  const ai = { enabled: true, features: { quote: true, price: false, reply: true, assistant: false } };
  assert.equal(P.isFeatureEnabled(ai, 'quote'), true);
  assert.equal(P.isFeatureEnabled(ai, 'price'), false);
  // Master off disables everything without erasing the choices underneath.
  assert.equal(P.isFeatureEnabled({ ...ai, enabled: false }, 'quote'), false);
  assert.equal(P.isFeatureEnabled({ ...ai, enabled: false }, 'reply'), false);
});

test('isFeatureEnabled rejects unknown and malformed input rather than defaulting open', () => {
  const ai = { enabled: true, features: { quote: true } };
  assert.equal(P.isFeatureEnabled(ai, 'nope'), false);
  for (const bad of [undefined, null, {}, { enabled: true }]) {
    assert.equal(P.isFeatureEnabled(bad, 'reply'), false, `${JSON.stringify(bad)} must not enable reply`);
  }
});

test('the privacy claim is qualified exactly when it stops being true', () => {
  const off = { enabled: true, features: { quote: true, price: true, reply: false, assistant: true } };
  assert.equal(P.transmitsCustomerData(off), false, 'no customer data leaves — claim stands');
  assert.deepEqual(P.activeCustomerDataFeatures(off), []);

  const on = { ...off, features: { ...off.features, reply: true } };
  assert.equal(P.transmitsCustomerData(on), true, 'reply on — claim needs qualifying');
  assert.deepEqual(P.activeCustomerDataFeatures(on), ['reply']);

  // Master off means nothing transmits, so the claim holds again.
  assert.equal(P.transmitsCustomerData({ ...on, enabled: false }), false);
});

test('every disclosure locale key exists in every shipped bundle', () => {
  const dir = path.join(ROOT, 'renderer/locales');
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.js'))) {
    vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8'), ctx, { filename: f });
  }
  const L = ctx.globalThis.KhaytLocales || {};
  const needed = [
    // `set.ai_sends_to`, not `set.ai_sends`. The old key hard-coded
    // "Sends to Anthropic:" and became a lie the moment a shop could choose a
    // provider; the live one takes {provider} and both apps render it.
    'set.ai_master', 'set.ai_sends_to', 'set.ai_pii_badge', 'set.ai_reconsent',
    'priv.ai_active', 'priv.ai_review',
    ...Object.values(P.AI_FEATURES).flatMap((f) => [f.labelKey, f.sendsKey]),
  ];
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'tr', 'zh']) {
    const missing = needed.filter((k) => !L[code] || !L[code][k]);
    assert.deepEqual(missing, [], `${code} missing disclosure keys: ${missing.join(', ')}`);
  }
});

test('the main process enforces consent, not just the renderer', () => {
  // The renderer gate is a courtesy; the handler is the only place shop data
  // actually leaves the device, so it must refuse an unconsented feature even
  // if a call site forgets to check.
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  const handler = main.slice(main.indexOf("ipcMain.handle('hub:ai-extract'"));
  const body = handler.slice(0, handler.indexOf('\n});'));
  assert.match(body, /aiPrivacy\.isFeatureEnabled/, 'hub:ai-extract does not check consent');
  // and it must do so before the network call, not after.
  //
  // This pinned `api.anthropic.com`, which was the only address the handler
  // could reach. The provider is the shop's choice now and the hostname lives
  // in lib/ai-providers.js, so what is pinned is the `fetch` itself — which is
  // the invariant the test always meant and does not move with the vendor.
  const sends = body.indexOf('await fetch(');
  assert.ok(sends > 0, 'hub:ai-extract no longer makes the request here');
  assert.ok(
    body.indexOf('aiPrivacy.isFeatureEnabled') < sends,
    'consent is checked after the request is already sent',
  );
});

test('every renderer AI entry point gates on its own feature', () => {
  // A gate left on the bare master switch would let a declined feature run.
  const files = ['renderer/build.js', 'renderer/integrations.js'];
  let gates = 0;
  for (const rel of files) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    for (const m of src.matchAll(/KhaytAiPrivacy\.isFeatureEnabled\(\s*\w+\s*,\s*'([a-z]+)'/g)) {
      assert.ok(P.AI_FEATURES[m[1]], `${rel}: gate names unknown feature '${m[1]}'`);
      gates++;
    }
    assert.equal(/!\s*ai\.enabled\s*\|\||ai\.enabled\s*&&\s*ai\.apiKey/.test(src), false,
      `${rel} still gates an AI feature on the bare master switch`);
  }
  assert.equal(gates, 4, `expected 4 per-feature gates, found ${gates}`);
});

/* ============================================================
   Changing provider must not change consent
   ============================================================ */

test('the provider dropdown carries the consent boxes across its own redraw', () => {
  /*
   * `renderAiSettings()` derives the checkboxes from SAVED settings via
   * `migrateConsent`, not from the DOM. Changing provider has to redraw the
   * whole panel — every feature row states which provider it sends to — so the
   * handler must fold what is on screen back into `settings.ai` first.
   *
   * Without that, touching the dropdown silently reverted an unsaved tick. The
   * dangerous direction is the other one: a shop that UNTICKED `reply`, which
   * sends a customer's name, then changed provider, had that consent restored
   * and no way to know.
   *
   * Read out of the source rather than by driving a DOM: the whole panel is one
   * innerHTML string and standing up enough of a document to render it would
   * prove less than reading the four lines that matter.
   */
  const src = fs.readFileSync(path.join(ROOT, 'renderer/settings.js'), 'utf8');
  const at = src.indexOf("#aiProviderSetting')?.addEventListener('change'");
  assert.notEqual(at, -1, 'the provider change handler is gone');
  const handler = src.slice(at, src.indexOf('\n  });', at));

  assert.match(handler, /\.ai-feat-toggle/,
    'the provider handler redraws without reading the consent boxes — an unsaved tick is lost');
  assert.match(handler, /features: Object\.assign\(/,
    'the consent boxes are read but not carried into settings.ai');
  // The model is cleared on purpose; nothing else should be.
  assert.match(handler, /model: ''/, 'the model is no longer cleared when the provider changes');
  assert.match(handler, /enabled:/, 'the master toggle is dropped by the redraw');
  assert.match(handler, /baseUrl:/, 'a typed address is dropped by the redraw');
  assert.match(handler, /secretInputSave\(/,
    'the key is carried without the mask helper, so the literal mask can be written back');
});

test('every feature the consent list draws is one the gate actually checks', () => {
  // A row for a feature `isFeatureEnabled` does not know about is a switch
  // wired to nothing; a feature with no row is one that sends data with no
  // disclosure. Both have happened in this file's history.
  for (const id of Object.keys(P.AI_FEATURES)) {
    assert.equal(P.isFeatureEnabled({ enabled: true, features: { [id]: true } }, id), true,
      `${id} has a consent row the gate refuses to honour`);
    assert.equal(P.isFeatureEnabled({ enabled: true, features: { [id]: false } }, id), false,
      `${id} cannot be turned off`);
  }
  // And the gate refuses anything it has no row for, rather than defaulting on.
  assert.equal(P.isFeatureEnabled({ enabled: true, features: { invented: true } }, 'invented'), false);
});
