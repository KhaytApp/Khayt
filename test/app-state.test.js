const { test } = require('node:test');
const assert = require('node:assert/strict');

test('defaultSettings returns expected currency and mode defaults', () => {
  require('../lib/store.js');
  require('../renderer/util.js');
  const { defaultSettings } = require('../renderer/app-state.js');
  const s = defaultSettings();
  assert.equal(s.currency, 'SAR');
  assert.equal(s.mode, 'simple');
  assert.equal(s.lang, 'en');
  assert.ok(Array.isArray(s.acceptedPayments));
});

test('buildStoreSnapshot returns collections object', () => {
  require('../lib/store.js');
  require('../renderer/util.js');
  const { buildStoreSnapshot, collectStoreCollections } = require('../renderer/app-state.js');
  const snap = buildStoreSnapshot();
  const cols = collectStoreCollections();
  assert.ok(Array.isArray(snap.printLog));
  assert.equal(typeof cols.settings, 'object');
});

test('KhaytAppState exports persistence helpers', () => {
  const appState = require('../renderer/app-state.js');
  assert.equal(typeof appState.saveAll, 'function');
  assert.equal(typeof appState.loadAll, 'function');
  assert.equal(typeof appState.applyStoreFromSnapshot, 'function');
});
