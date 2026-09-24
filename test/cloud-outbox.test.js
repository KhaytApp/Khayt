/**
 * What a read-only device may send to the cloud, and what it must not.
 *
 * `lib/cloud-outbox.js` exists for the native Mac app, which pulls the cloud
 * store, shows the shop the difference, and offers to send the half that is
 * only here. It never merges and it never pushes a whole store, so its rule
 * has to be one-directional in a way the desktop's cursor-based
 * `changesSincePush` is not.
 *
 * The load-bearing test is not "does it produce the right list" — it is
 * `foldsIntoAgreement` at the bottom, which takes the payload this module
 * builds and runs it through the real `KhaytSync.applyDeltas`, the same fold
 * every other device performs on the chain. A payload that looks right and
 * folds wrong is the only kind of bug that matters here.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/store-secret-paths.js');
const { changesToSend, forCloud } = require('../lib/cloud-outbox.js');
const sync = require('../lib/sync.js');

const clone = (o) => JSON.parse(JSON.stringify(o));

test('a record the cloud has never seen is sent', () => {
  const out = changesToSend({ orders: [{ id: 'o1', rev: 1 }] }, { orders: [] });
  assert.deepEqual(out.deltas, [{ collection: 'orders', record: { id: 'o1', rev: 1 } }]);
});

test('a record edited here since the cloud saw it is sent', () => {
  const out = changesToSend({ orders: [{ id: 'o1', rev: 5 }] }, { orders: [{ id: 'o1', rev: 4 }] });
  assert.equal(out.deltas.length, 1);
});

test('a record the cloud holds at the same rev is not sent', () => {
  const out = changesToSend({ orders: [{ id: 'o1', rev: 4 }] }, { orders: [{ id: 'o1', rev: 4 }] });
  assert.deepEqual(out.deltas, []);
});

/**
 * The one that separates this from the desktop's rule. `changesSincePush` ships
 * anything that DISAGREES with its cursor; here, disagreeing in the cloud's
 * favour means this device is behind, and behind is not something you send.
 */
test('a record the cloud holds at a HIGHER rev is left alone, not pushed back', () => {
  const out = changesToSend({ orders: [{ id: 'o1', rev: 2, note: 'stale' }] },
                            { orders: [{ id: 'o1', rev: 9, note: 'newer' }] });
  assert.deepEqual(out.deltas, []);
});

test('a deletion made here is sent as a tombstone', () => {
  const out = changesToSend(
    { orders: [], tombstones: [{ collection: 'orders', id: 'o1', rev: 3, deletedAt: '2026-09-01' }] },
    { orders: [{ id: 'o1', rev: 3 }], tombstones: [] });
  assert.equal(out.tombstones.length, 1);
  assert.equal(out.tombstones[0].id, 'o1');
});

test('a deletion the cloud already knows about is not sent again', () => {
  const t = { collection: 'orders', id: 'o1', rev: 3, deletedAt: '2026-09-01' };
  const out = changesToSend({ orders: [], tombstones: [t] }, { orders: [], tombstones: [t] });
  assert.deepEqual(out.tombstones, []);
});

/**
 * Ids are unique within a collection, not across them. Keying a deletion by id
 * alone let one deleted record stand in for an unrelated one, and the one it
 * stood in for was never sent — the same defect that was in the comparison
 * screen.
 */
test('two deletions with the same id in different collections are both sent', () => {
  const out = changesToSend(
    { tombstones: [{ collection: 'orders', id: 'x', deletedAt: 'a' },
                   { collection: 'spools', id: 'x', deletedAt: 'a' }] },
    { tombstones: [{ collection: 'orders', id: 'x', deletedAt: 'a' }] });
  assert.equal(out.tombstones.length, 1);
  assert.equal(out.tombstones[0].collection, 'spools');
});

test('a record deleted here is not also sent as a record', () => {
  const out = changesToSend(
    { orders: [{ id: 'o1', rev: 3 }], tombstones: [{ collection: 'orders', id: 'o1', rev: 3, deletedAt: 'a' }] },
    { orders: [], tombstones: [] });
  assert.deepEqual(out.deltas, []);
  assert.equal(out.tombstones.length, 1);
});

test('a record another device deleted is not resurrected', () => {
  const out = changesToSend(
    { orders: [{ id: 'o1', rev: 3 }] },
    { orders: [], tombstones: [{ collection: 'orders', id: 'o1', rev: 3, deletedAt: 'a' }] });
  assert.deepEqual(out.deltas, []);
});

test('a record with no id is skipped rather than sent without one', () => {
  const out = changesToSend({ orders: [{ rev: 1 }, null, 'nonsense'] }, { orders: [] });
  assert.deepEqual(out.deltas, []);
});

test('tombstones is not itself a collection to diff', () => {
  const out = changesToSend({ tombstones: [] }, { tombstones: [] });
  assert.deepEqual(out.deltas, []);
});

/**
 * Settings are one object, not revisioned records, so the delta shape has
 * nowhere to put them. Reporting that is the whole obligation — the screen has
 * to be able to say "open Khayt to send those" rather than drop them silently.
 */
test('a settings change is reported, not sent', () => {
  const out = changesToSend({ settings: { currency: 'SAR' } }, { settings: { currency: 'USD' } });
  assert.deepEqual(out.deltas, []);
  assert.equal(out.settingsDiffer, true);
});

test('settings that match in a different key order do not count as a change', () => {
  const out = changesToSend({ settings: { a: 1, b: 2 } }, { settings: { b: 2, a: 1 } });
  assert.equal(out.settingsDiffer, false);
});

/**
 * THE CLOUD DOES NOT CARRY SECRETS, AND THAT IS NOT A DIFFERENCE.
 *
 * `redactSettingsForExport` in lib/store.js replaces every credential with
 * `__KHAYT_MASKED__` before the store is pushed. So the API key, the sync token
 * and the print library's S3 secret are all masks up there and encrypted blobs
 * down here — and comparing them as values made "your settings differ" true for
 * ever for any shop that has configured anything at all.
 *
 * Found against the real service: this shop's three differing settings keys
 * were `ai`, `cloud` and `printLibrary`, and every one of them differed ONLY in
 * a masked field.
 */
test('a secret the cloud masks is not a settings change', () => {
  const M = require('../lib/store.js').SECRET_MASK;
  const out = changesToSend(
    { settings: { ai: { apiKey: '__enc__abc' }, printLibrary: { s3: { secretAccessKey: '__enc__d' } } } },
    { settings: { ai: { apiKey: M }, printLibrary: { s3: { secretAccessKey: M } } } });
  assert.equal(out.settingsDiffer, false);
});

test('a real change sitting beside a masked secret is still seen', () => {
  const M = require('../lib/store.js').SECRET_MASK;
  const out = changesToSend(
    { settings: { currency: 'SAR', ai: { apiKey: '__enc__abc' } } },
    { settings: { currency: 'USD', ai: { apiKey: M } } });
  assert.equal(out.settingsDiffer, true);
});

/**
 * The earlier fix excluded the whole `cloud` subtree, which would have hidden
 * this. Only the one bookkeeping field is exempt now.
 */
test('a changed cloud address is still a settings change', () => {
  const out = changesToSend(
    { settings: { cloud: { url: 'https://a.example', lastServerRev: 1 } } },
    { settings: { cloud: { url: 'https://b.example', lastServerRev: 9 } } });
  assert.equal(out.settingsDiffer, true);
});

/**
 * THE ONE THAT WAS WRONG ON A REAL SHOP'S SCREEN.
 *
 * The desktop writes `settings.cloud.lastServerRev` AFTER a successful push, so
 * the blob that went up carries the previous value and the local copy is one
 * ahead of it — permanently, for every shop that has ever synced. Compared
 * raw, "your settings differ" was true for ever, and the sheet said so under a
 * heading reporting that the two held the same records.
 */
test("the sync's own bookkeeping is not a settings change", () => {
  const out = changesToSend(
    { settings: { currency: 'SAR', cloud: { lastServerRev: 16, token: 'a' } } },
    { settings: { currency: 'SAR', cloud: { lastServerRev: 15, token: 'a' } } });
  assert.equal(out.settingsDiffer, false);
});

test('a setting the shop actually changed still counts', () => {
  const out = changesToSend(
    { settings: { currency: 'SAR', cloud: { lastServerRev: 16 } } },
    { settings: { currency: 'USD', cloud: { lastServerRev: 16 } } });
  assert.equal(out.settingsDiffer, true);
});

test('a settings change beside identical cloud bookkeeping is still seen', () => {
  const out = changesToSend(
    { settings: { vatRate: 15, cloud: { lastServerRev: 3 } } },
    { settings: { vatRate: 5, cloud: { lastServerRev: 99 } } });
  assert.equal(out.settingsDiffer, true, 'a real change was hidden by the exclusion');
});

/**
 * The real proof. Build the payload, fold it into the cloud's store with the
 * shipped merge engine, and require that the two sides now agree everywhere the
 * payload was allowed to touch — and that the record the cloud held at a higher
 * rev came through the fold unharmed.
 */
test('the payload folds the cloud into agreement without losing its newer record', () => {
  const local = {
    orders: [
      { id: 'new-here', rev: 1, title: 'made on the Mac' },
      { id: 'edited-here', rev: 7, title: 'edited on the Mac' },
      { id: 'newer-there', rev: 2, title: 'the stale copy' },
    ],
    spools: [{ id: 's1', rev: 4, grams: 900 }],
    tombstones: [{ collection: 'spools', id: 'gone', rev: 2, deletedAt: '2026-09-02' }],
  };
  const server = {
    orders: [
      { id: 'edited-here', rev: 6, title: 'the older copy' },
      { id: 'newer-there', rev: 9, title: 'edited elsewhere' },
    ],
    spools: [{ id: 's1', rev: 4, grams: 900 }, { id: 'gone', rev: 2 }],
    tombstones: [],
  };

  const payload = changesToSend(local, server);
  const folded = clone(server);
  const report = sync.applyDeltas(folded, clone(payload), { appendOnly: [] });

  const byId = (store, coll, id) => (store[coll] || []).find((r) => r.id === id);

  assert.equal(byId(folded, 'orders', 'new-here').title, 'made on the Mac');
  assert.equal(byId(folded, 'orders', 'edited-here').title, 'edited on the Mac');
  // Never sent, so never touched — this is the direction that destroys data.
  assert.equal(byId(folded, 'orders', 'newer-there').title, 'edited elsewhere');
  assert.equal(byId(folded, 'spools', 'gone'), undefined);
  assert.equal(report.applied, 2);
  assert.equal(report.removed, 1);

  // And a second run has nothing left to say: the cloud now holds what we hold.
  const again = changesToSend(local, folded);
  assert.deepEqual(again.deltas, []);
  assert.deepEqual(again.tombstones, []);
});

/* ── What may go up ──────────────────────────────────────────────────────────
   The cloud never receives a shop's credentials. On the desktop that is true
   by layering — `maskStoreSecretsForRenderer` replaces every secret before the
   renderer sees the store, so the snapshot it pushes has always carried masks.
   A host that reads the store from DISK holds the real `__enc__` values, and
   would put the shop's API key, sync token and S3 secret in the blob. */

const { SECRET_PATHS } = require('../lib/store-secret-paths.js');

test('every credential is masked before a whole store goes up', () => {
  const store = {
    settings: {
      ai: { apiKey: '__enc__AAA' },
      cloud: { token: '__enc__BBB', url: 'https://cloud.example' },
      printLibrary: { s3: { secretAccessKey: '__enc__CCC' } },
    },
    printLog: [{ id: 'o1', rev: 1 }],
  };
  const out = forCloud(store);
  assert.equal(out.settings.ai.apiKey, '__KHAYT_MASKED__');
  assert.equal(out.settings.cloud.token, '__KHAYT_MASKED__');
  assert.equal(out.settings.printLibrary.s3.secretAccessKey, '__KHAYT_MASKED__');
  // Not everything — an address is not a secret.
  assert.equal(out.settings.cloud.url, 'https://cloud.example');
  assert.deepEqual(out.printLog, [{ id: 'o1', rev: 1 }]);
});

test('the caller\'s own store is not touched', () => {
  // It is the book on disk. Masking it in place would blank the shop's own
  // credentials the next time anything wrote it back.
  const store = { settings: { ai: { apiKey: '__enc__AAA' } } };
  forCloud(store);
  assert.equal(store.settings.ai.apiKey, '__enc__AAA');
});

test('no path in the secret list survives a round through forCloud', () => {
  // Driven from the list itself, so a credential added there cannot be
  // forgotten here.
  assert.ok(SECRET_PATHS.length > 10, `only ${SECRET_PATHS.length} secret paths`);
  const store = {};
  const put = (path) => {
    let node = store;
    const parts = String(path).split('.');
    for (const part of parts.slice(0, -1)) {
      if (part === '[]') return null;              // array paths need a shape
      node = node[part] = node[part] || {};
    }
    node[parts[parts.length - 1]] = '__enc__SECRET';
    return node;
  };
  const simple = SECRET_PATHS.filter((p) => !String(p).includes('[]'));
  for (const path of simple) put(path);
  const out = forCloud(store);
  const readable = JSON.stringify(out);
  assert.ok(!readable.includes('__enc__SECRET'),
    'a secret survived: ' + readable.slice(0, 200));
});

test('a send refuses outright when the secret list is missing', () => {
  // Failing closed. Sending with an unmasked store would be worse than not
  // sending at all.
  const saved = globalThis.KhaytStoreSecretPaths;
  try {
    globalThis.KhaytStoreSecretPaths = undefined;
    assert.throws(() => forCloud({}), /secret list is not loaded, refusing to send/);
  } finally { globalThis.KhaytStoreSecretPaths = saved; }
});

test('a value sealed on disk never goes up, even when its path is missing from the list', () => {
  // SEC-011 (the Mac's September scan). The list decides what gets sealed, but a
  // host that reads the store from disk — the Mac — could hold a sealed value the
  // list has not heard of. Its ciphertext must not reach the cloud blob.
  const store = {
    settings: {
      someNewIntegration: { apiKey: '__enc__AAAAciphertext' },   // not on the list
      ntfy: { token: '__enc__BBBB', server: 'https://ntfy.sh' },  // on the list; server is plain
    },
    machines: [{ id: 'm1', extra: ['__enc__CCCC', 'plain'] }],
  };
  const out = forCloud(store);
  const M = require('../lib/store.js').SECRET_MASK;
  assert.notEqual(out.settings.someNewIntegration.apiKey.slice(0, 7), '__enc__', 'unlisted sealed value shipped');
  assert.equal(out.settings.someNewIntegration.apiKey, M);
  assert.equal(out.settings.ntfy.token, M);
  assert.equal(out.settings.ntfy.server, 'https://ntfy.sh', 'a plain value is not a secret by accident');
  assert.deepEqual(out.machines[0].extra, [M, 'plain'], 'sealed values inside arrays');
  assert.equal(store.settings.someNewIntegration.apiKey, '__enc__AAAAciphertext', 'the caller\'s store is untouched');
});

test('the ntfy topic and webhook URLs are shown on this computer and never go up (SEC-011)', () => {
  const store = { settings: {
    ntfy: { topic: 'shop-7f3a-alerts', server: 'https://ntfy.sh' },
    webhooks: {
      subscriptions: [{ id: 's1', url: 'https://hooks.slack.com/services/T0/B0/secret', events: ['order_created'] }],
      events: { order_created: 'https://discord.com/api/webhooks/1/abc', status_changed: '' },
    },
  } };
  const M = require('../lib/store.js').SECRET_MASK;
  const out = forCloud(store);
  assert.equal(out.settings.ntfy.topic, M);
  assert.equal(out.settings.ntfy.server, 'https://ntfy.sh');
  assert.equal(out.settings.webhooks.subscriptions[0].url, M);
  assert.deepEqual(out.settings.webhooks.subscriptions[0].events, ['order_created'], 'only the URL is private');
  assert.equal(out.settings.webhooks.events.order_created, M);
  assert.equal(out.settings.webhooks.events.status_changed, '', 'an empty slot stays empty');
  assert.equal(store.settings.ntfy.topic, 'shop-7f3a-alerts', 'the caller keeps the real value');
});
