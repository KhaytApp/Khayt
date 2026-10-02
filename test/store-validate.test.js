const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  STORE_VERSION,
  validateStoreSnapshot,
  normalizeStoreSnapshot,
  isValidOrder,
} = require('../lib/store-validate');

test('isValidOrder keeps any job that has an id', () => {
  assert.equal(isValidOrder({ id: 'O-1', date: '2026-01-01', status: 'queued', project: 'X' }), true);
  assert.equal(isValidOrder({ id: 'O-2' }), true, 'missing date/status/project is kept, not dropped');
  assert.equal(isValidOrder({ id: '', date: '2026-01-01', status: 'queued', project: 'X' }), false);
  assert.equal(isValidOrder({ date: '2026-01-01' }), false);
  assert.ok(!isValidOrder(null));
  assert.ok(!isValidOrder([]));
});

test('a job missing its date, status or project survives load and save, read as ""', () => {
  // Found in the Mac's data-loss audit: such a job came in by phone, cloud or
  // import, the desktop dropped it on load, and the next save erased it.
  const { normalizeOrder } = require('../lib/store-validate');
  const whole = { id: 'O-1', date: '2026-01-01', status: 'queued', project: 'X', price: 5 };
  const bare = { id: 'O-2', price: 7, date: null, status: 3 };
  const { normalized, warnings } = normalizeStoreSnapshot({ printLog: [whole, bare] });
  assert.equal(normalized.printLog.length, 2);
  assert.equal(warnings.some((w) => /printLog/.test(w)), false, 'nothing dropped');
  assert.equal(normalized.printLog[0], whole, 'a well-formed job is not copied');
  assert.deepEqual(normalized.printLog[1], { id: 'O-2', price: 7, date: '', status: '3', project: '' });
  assert.deepEqual(bare, { id: 'O-2', price: 7, date: null, status: 3 }, 'the input is not mutated');
  // Saved and loaded again, it stays.
  const again = normalizeStoreSnapshot(JSON.parse(JSON.stringify(normalized))).normalized;
  assert.deepEqual(again.printLog.map((o) => o.id), ['O-1', 'O-2']);
  assert.equal(normalizeOrder(whole), whole);
});

test('validateStoreSnapshot rejects non-objects', () => {
  const r = validateStoreSnapshot([]);
  assert.equal(r.ok, false);
  assert.match(r.errors[0], /plain object/);
});

test('validateStoreSnapshot accepts minimal disk snapshot', () => {
  const r = validateStoreSnapshot({ printLog: [], settings: {} });
  assert.equal(r.ok, true);
});

test('validateStoreSnapshot flags wrong collection types', () => {
  const r = validateStoreSnapshot({ printLog: 'not-array' });
  assert.equal(r.ok, false);
  assert.ok(r.errors.some(e => e.includes('printLog')));
});

test('normalizeStoreSnapshot drops invalid orders and keeps valid ones', () => {
  const { normalized, warnings } = normalizeStoreSnapshot({
    printLog: [
      { id: 'O-1', date: '2026-01-01', status: 'queued', project: 'A' },
      { id: '', date: '2026-01-01', status: 'queued', project: 'B' },
    ],
  });
  assert.equal(normalized.printLog.length, 1);
  assert.equal(normalized.printLog[0].id, 'O-1');
  assert.ok(warnings.some(w => w.includes('printLog')));
});

test('normalizeStoreSnapshot persists subscriptions and auditLog (regression: were being dropped)', () => {
  const { normalized } = normalizeStoreSnapshot({
    subscriptions: [{ id: 'SUB1', clientId: 'C1', amount: 100 }],
    auditLog: [{ at: 1, actor: 'me', action: 'edit' }],
  });
  assert.equal(normalized.subscriptions.length, 1);
  assert.equal(normalized.subscriptions[0].id, 'SUB1');
  assert.equal(normalized.auditLog.length, 1);
  assert.equal(normalized.auditLog[0].action, 'edit');
});

test('normalizeStoreSnapshot salvages valid collections when one is malformed', () => {
  // One bad collection (printLog not an array) must NOT discard the whole store.
  const { normalized, errors } = normalizeStoreSnapshot({
    printLog: 'corrupt',
    clients: [{ id: 'C1' }, { id: 'C2' }],
    inventory: [{ id: 'S1' }],
  });
  assert.ok(normalized, 'should salvage rather than return null');
  assert.equal(normalized.clients.length, 2);
  assert.equal(normalized.inventory.length, 1);
  assert.equal(normalized.printLog, undefined); // bad collection skipped, not wiped
  assert.ok(errors.some(e => e.includes('printLog')));
});

test('normalizeStoreSnapshot returns null only for fatal input', () => {
  assert.equal(normalizeStoreSnapshot(null).normalized, null);
  assert.equal(normalizeStoreSnapshot('nope').normalized, null);
  assert.equal(normalizeStoreSnapshot([]).normalized, null);
});

test('normalizeStoreSnapshot strips prototype pollution keys from settings', () => {
  const polluted = JSON.parse('{"settings":{"lang":"en","__proto__":{"polluted":true}}}');
  const { normalized } = normalizeStoreSnapshot(polluted);
  assert.equal(normalized.settings.lang, 'en');
  assert.equal(Object.prototype.polluted, undefined);
});

test('normalizeStoreSnapshot passes through corrupt marker', () => {
  const corrupt = { __corrupt: true, error: 'bad' };
  const { normalized } = normalizeStoreSnapshot(corrupt);
  assert.equal(normalized.__corrupt, true);
});

test('export version newer than supported yields warning only', () => {
  const { ok, warnings } = validateStoreSnapshot({ version: STORE_VERSION + 1, settings: {} });
  assert.equal(ok, true);
  assert.ok(warnings.some(w => w.includes('newer')));
});

test('isValidClient requires non-empty id', () => {
  const { isValidClient } = require('../lib/store-validate');
  assert.equal(isValidClient({ id: 'C1' }), true);
  assert.equal(isValidClient({ id: '' }), false);
  assert.ok(!isValidClient(null));
});

test('normalizeStoreSnapshot drops invalid clients', () => {
  const { normalized, warnings } = normalizeStoreSnapshot({
    clients: [{ id: 'C1' }, { id: '' }],
  });
  assert.equal(normalized.clients.length, 1);
  assert.ok(warnings.some(w => w.includes('clients')));
});

test('upgrade: an older store snapshot (pre beta.7–11 keys) normalizes cleanly', () => {
  // A representative store from an older version: orders/clients WITHOUT the
  // fields beta.7–11 added (recurring.paused, marketingOptOut, accountingPushedAt),
  // and settings WITHOUT the new config blocks (smsConfig/accountingSync/storefront/
  // autoSchedule). Must round-trip without dropping data or erroring.
  const old = {
    version: 1,
    printLog: [{ id: 'O-1', date: '2024-01-01', status: 'completed', project: 'Legacy', price: 100, parts: [{ filamentId: 'pla', grams: 50 }] }],
    clients: [{ id: 'C-1', nameEn: 'Old Client', phone: '+966500000000' }],
    inventory: [{ id: 'pla', material: 'PLA', weight: 800 }],
    settings: { bizEn: 'Legacy Shop', currency: 'SAR' }, // none of the new keys
  };
  const { normalized, errors } = normalizeStoreSnapshot(old);
  assert.deepEqual(errors, []);
  assert.ok(normalized);
  assert.equal(normalized.printLog.length, 1);
  assert.equal(normalized.printLog[0].id, 'O-1');
  assert.equal(normalized.clients[0].nameEn, 'Old Client');
  assert.equal(normalized.inventory[0].material, 'PLA');
  // settings preserved as-is here; the renderer merges defaults over them on load,
  // so absent new keys (smsConfig/accountingSync/storefront/autoSchedule) get defaulted.
  assert.equal(normalized.settings.bizEn, 'Legacy Shop');
});
