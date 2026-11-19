'use strict';
/**
 * lib/main/sentry-consent.js: crash reporting STARTS only for a shop that
 * opted in (read from the store on disk before the app is ready), and never
 * runs release-health sessions, whose envelopes bypass beforeSend (Mac
 * outbound audit, Nov 19). Fails closed. The launch-level proof, counting what
 * reaches a local Sentry, is scripts/e2e-sentry-consent-smoke.mjs.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const C = require('../lib/main/sentry-consent.js');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sentry-consent-'));
const write = (name, body) => { const f = path.join(dir, name); fs.writeFileSync(f, body); return f; };

test('no store, an empty or broken one: no', () => {
  assert.equal(C.crashConsentAtStartup(fs, path.join(dir, 'missing.json')), false);
  assert.equal(C.crashConsentAtStartup(fs, write('empty.json', '')), false);
  assert.equal(C.crashConsentAtStartup(fs, write('broken.json', '{"settings":{"telemetry":{"crashOptIn":true')), false);
  assert.equal(C.crashConsentAtStartup(fs, dir), false, 'a directory');
});

test('the default store (both streams off) and a usage-only opt-in: no', () => {
  assert.equal(C.crashConsentAtStartup(fs, write('off.json', JSON.stringify({ settings: { telemetry: { crashOptIn: false, usageOptIn: false } } }))), false);
  assert.equal(C.crashConsentAtStartup(fs, write('usage.json', JSON.stringify({ settings: { telemetry: { crashOptIn: false, usageOptIn: true } } }))), false);
  assert.equal(C.crashConsentAtStartup(fs, write('none.json', JSON.stringify({ settings: {} }))), false);
});

test('only crashOptIn === true is yes, wherever the text appears', () => {
  assert.equal(C.crashConsentAtStartup(fs, write('on.json', JSON.stringify({ settings: { telemetry: { crashOptIn: true } } }))), true);
  assert.equal(C.crashConsentAtStartup(fs, write('pretty.json', JSON.stringify({ settings: { telemetry: { crashOptIn: true } } }, null, 1))), true);
  // The phrase elsewhere (a note, another object) is not consent.
  assert.equal(C.crashConsentAtStartup(fs, write('elsewhere.json', JSON.stringify({ notes: '"crashOptIn":true', other: { crashOptIn: true }, settings: { telemetry: { crashOptIn: false } } }))), false);
  assert.equal(C.crashConsentAtStartup(fs, write('string.json', JSON.stringify({ settings: { telemetry: { crashOptIn: 'true' } } }))), false);
});

test('a store over the read limit is not parsed: no', () => {
  const big = { size: C.MAX_BYTES + 1, isFile: () => true };
  const fakeFs = { statSync: () => big, readFileSync: () => { throw new Error('must not read'); } };
  assert.equal(C.crashConsentAtStartup(fakeFs, 'x'), false);
});

test('sessions are dropped from the default integrations; the rest stay', () => {
  const defaults = ['SentryMinidump', 'MainProcessSession', 'OnUncaughtException', 'BrowserWindowSession', 'Console'].map((name) => ({ name }));
  assert.deepEqual(C.withoutSessions(defaults).map((i) => i.name), ['SentryMinidump', 'OnUncaughtException', 'Console']);
});

test('the SDK\'s own session integration is named as this module expects', () => {
  let src = '';
  try { src = fs.readFileSync(require.resolve('@sentry/electron/main/integrations/main-process-session.js'), 'utf8'); } catch (_) { return; }
  assert.match(src, /name: 'MainProcessSession'/, '@sentry/electron renamed its session integration: update SESSION_INTEGRATIONS');
});

test('main.js starts Sentry only behind the consent read, after the user-data override, without sessions', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const init = main.indexOf('sentry.init({');
  const gate = main.indexOf('SentryConsent.crashConsentAtStartup(');
  const userData = main.indexOf("app.setPath('userData', process.env.KHAYT_USER_DATA)");
  assert.ok(gate > 0 && gate < init, 'the consent read gates the init');
  assert.ok(userData > 0 && userData < gate, 'the store is read after the user-data path is final');
  assert.match(main.slice(init, init + 2500), /integrations: \(defaults\) => SentryConsent\.withoutSessions\(defaults\)/);
  assert.equal((main.match(/sentry\.init\(/g) || []).length, 1, 'one init');
});
