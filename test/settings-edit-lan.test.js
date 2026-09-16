/**
 * The LAN block of the settings save.
 *
 * The Electron page never saved this block through `settings-edit`: its
 * `saveLanApiSettingsFromForm` merged the pane's fields over the stored block
 * itself. The Mac app's Online pane saves through the rule, so the rule now
 * takes a `lanApi` object in the form and merges it THE SAME WAY — these tests
 * hold it to that page's three habits: fields the pane does not show survive,
 * a blank PIN keeps the stored one, and a port that is not a port is 3219.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { apply } = require('../lib/settings-edit.js');

const stored = {
  lanApi: { enabled: false, port: 3219, pin: 'sealed:abc', webhookToken: 'wh-1', bindLan: false,
            intakeQuote: { enabled: true, marginPct: 30 } },
};

test('a form without the block leaves it exactly as stored', () => {
  const out = apply(stored, { phone: '1' });
  assert.deepEqual(out.lanApi, stored.lanApi);
});

test('the pane\'s fields land over the stored block, and the rest survives', () => {
  const out = apply(stored, { lanApi: { enabled: true, port: 8080, bindLan: true, pin: '4321' } });
  assert.equal(out.lanApi.enabled, true);
  assert.equal(out.lanApi.port, 8080);
  assert.equal(out.lanApi.bindLan, true);
  assert.equal(out.lanApi.pin, '4321');
  // Never shown by the pane, never lost by it.
  assert.equal(out.lanApi.webhookToken, 'wh-1');
  assert.deepEqual(out.lanApi.intakeQuote, { enabled: true, marginPct: 30 });
});

test('a blank PIN keeps the stored one — "leave blank to keep current"', () => {
  for (const blank of ['', '   ', null, undefined]) {
    const out = apply(stored, { lanApi: { enabled: true, pin: blank } });
    assert.equal(out.lanApi.pin, 'sealed:abc', `pin ${JSON.stringify(blank)} did not keep the stored one`);
  }
  // A typed PIN is trimmed, as every secret field on the page is.
  assert.equal(apply(stored, { lanApi: { pin: ' 99 ' } }).lanApi.pin, '99');
});

test('a port that is not a port is the default, as the page\'s parseInt || 3219', () => {
  for (const bad of ['', 'abc', 0, -5, 70000, NaN]) {
    assert.equal(apply(stored, { lanApi: { port: bad } }).lanApi.port, 3219, `port ${String(bad)}`);
  }
  assert.equal(apply(stored, { lanApi: { port: '4000' } }).lanApi.port, 4000);
  assert.equal(apply(stored, { lanApi: { port: 4000.7 } }).lanApi.port, 4000);
});

test('a field the pane did not send keeps its stored value', () => {
  const out = apply(stored, { lanApi: { port: 5000 } });
  assert.equal(out.lanApi.enabled, false);
  assert.equal(out.lanApi.bindLan, false);
  assert.equal(out.lanApi.pin, 'sealed:abc');
});

test('a shop that never had the block gets the default shape', () => {
  const out = apply({}, { lanApi: { enabled: true } });
  assert.deepEqual(out.lanApi, { enabled: true, port: 3219, pin: '', bindLan: false });
});
