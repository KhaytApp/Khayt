/**
 * Two branches, one org, end to end — the crypto layer and the delta engine
 * driven together for the first time.
 *
 * Everything up to now tested them apart. test/sync-crypto-org.test.js proves the
 * Org Data Key opens two shops; test/phase3-delta-roundtrip.test.js proves the
 * engine converges. Neither proves they compose, and the seam between them is
 * where a multi-shop failure would actually live:
 *
 *   - The engine's metadata (`rev`, `updatedAt`, `tombstones`) has to survive a
 *     trip through JSON.stringify → AES-GCM → JSON.parse. If encryptStore quietly
 *     dropped or reshaped any of it, sync would still appear to work and would
 *     stop converging — the failure that never announces itself.
 *   - One device holds several branches, so it runs the engine repeatedly against
 *     different stores in one process. That is the exact shape that used to
 *     tombstone shop A's records into shop B.
 *
 * No server and no network: the "upload" is a variable holding ciphertext, which
 * is all the server ever is in this design.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const sc = require('../lib/sync-crypto.js');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');
const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };

/** A fresh engine instance — one per simulated device, as separate machines have. */
function device() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

const snap = (over = {}) => ({ printLog: [], clients: [], inventory: [], tombstones: [], ...over });

/** Order-insensitive comparison, reserved fields included — convergence, not shape. */
const canon = (s) => JSON.stringify(
  Object.fromEntries(Object.entries(s).filter(([, v]) => Array.isArray(v)).sort()
    .map(([k, arr]) => [k, [...arr].sort((a, b) => String(a.id).localeCompare(String(b.id)))])),
);

/** An org with two branches, each with its own passphrase, recovery key and DEK. */
function buildOrg() {
  const { orgKeyset, orgKey, recoveryKey: orgRecovery } = sc.createOrgKeyset('hq-passphrase', { kdf: FAST_KDF });
  const shops = {};
  for (const [id, pass] of [['shop-riyadh', 'riyadh-pass'], ['shop-jeddah', 'jeddah-pass']]) {
    const { keyset, recoveryKey } = sc.createKeyset(pass, { kdf: FAST_KDF });
    const dek = sc.unlockWithPassphrase(pass, keyset);
    shops[id] = { id, pass, recoveryKey, dek, keyset: sc.joinOrg(keyset, dek, orgKey, orgKeyset.orgId) };
  }
  return { orgKeyset, orgKey, orgRecovery, shops };
}

test('one org passphrase opens both branches’ encrypted stores', () => {
  const { orgKeyset, shops } = buildOrg();
  const cloud = {};   // shopId -> ciphertext, i.e. everything the server holds
  for (const s of Object.values(shops)) {
    cloud[s.id] = sc.encryptStore(snap({ printLog: [{ id: 'o1', project: s.id }] }), s.dek);
  }

  // The HQ device: one passphrase, then every branch.
  const odk = sc.unlockOrgWithPassphrase('hq-passphrase', orgKeyset);
  for (const s of Object.values(shops)) {
    const dek = sc.unlockWithOrg(odk, orgKeyset.orgId, s.keyset);
    assert.equal(sc.decryptStore(cloud[s.id], dek).printLog[0].project, s.id);
  }

  // A branch device holds one shop's passphrase and must reach exactly that shop.
  const riyadhDek = sc.unlockWithPassphrase('riyadh-pass', shops['shop-riyadh'].keyset);
  assert.deepEqual(sc.decryptStore(cloud['shop-riyadh'], riyadhDek).printLog[0].project, 'shop-riyadh');
  assert.throws(() => sc.decryptStore(cloud['shop-jeddah'], riyadhDek),
    'Riyadh’s key must not open Jeddah’s store');
});

test('sync metadata survives the round trip through ciphertext', () => {
  // The seam. rev, updatedAt and tombstones are what the engine reasons with; if
  // encrypt/decrypt reshaped any of them, sync would keep running and stop
  // converging. Asserted on a store that has all three, not an empty one.
  const D = device();
  const { shops } = buildOrg();
  const s = shops['shop-riyadh'];

  const local = snap({
    printLog: [{ id: 'o1', project: 'bracket', price: 100 }, { id: 'o2', project: 'vase' }],
    clients: [{ id: 'c1', name: 'سارة' }],
  });
  D.setScope(s.id);
  D.seedIndex(local);
  local.printLog[0].price = 175;               // an edit  → rev bump
  local.printLog = local.printLog.filter((r) => r.id !== 'o2');  // a delete → tombstone
  D.stampChanges(local);

  assert.equal(local.printLog[0].rev, 1);
  assert.equal(local.tombstones.length, 1);
  assert.ok(local.printLog[0].updatedAt, 'stamped with a timestamp');

  const back = sc.decryptStore(sc.encryptStore(local, s.dek), s.dek);
  assert.deepEqual(back, local, 'byte-for-byte, metadata included');
  assert.equal(back.printLog[0].rev, 1, 'rev survived');
  assert.equal(back.printLog[0].updatedAt, local.printLog[0].updatedAt, 'updatedAt survived');
  assert.deepEqual(back.tombstones, local.tombstones, 'tombstones survived');
});

test('two devices in one branch converge through ciphertext', () => {
  // The ordinary case, but with every exchange actually encrypted, so a metadata
  // loss in the envelope shows up as a failure to converge rather than in review.
  const { orgKeyset, shops } = buildOrg();
  const s = shops['shop-riyadh'];
  const hq = device();
  const branch = device();

  // The HQ device reaches this shop through the org; the branch device through
  // its own passphrase. Both must arrive at the same DEK or nothing else matters.
  const odk = sc.unlockOrgWithPassphrase('hq-passphrase', orgKeyset);
  const hqDek = sc.unlockWithOrg(odk, orgKeyset.orgId, s.keyset);
  const branchDek = sc.unlockWithPassphrase('riyadh-pass', s.keyset);
  assert.deepEqual(hqDek, branchDek);

  let cloud = null;
  const upload = (store, dek) => { cloud = sc.encryptStore(store, dek); };
  const download = (dek) => (cloud ? sc.decryptStore(cloud, dek) : null);

  // Branch creates two orders and pushes. Seed on the empty store FIRST, the way
  // launch does, then add the orders — seeding after the fact would record them as
  // already-known and stamp no rev, so there would be nothing to send.
  const bStore = snap();
  branch.setScope(s.id);
  branch.seedIndex(bStore);
  bStore.printLog.push({ id: 'o1', project: 'bracket' }, { id: 'o2', project: 'vase' });
  branch.stampChanges(bStore);
  assert.ok(bStore.printLog.every((r) => r.rev >= 1), 'new orders were stamped');
  upload(bStore, branchDek);

  // HQ pulls, merges, edits one order, deletes the other, pushes.
  const hStore = snap();
  hq.setScope(s.id);
  hq.seedIndex(hStore);
  const pulled = download(hqDek);
  hq.applyDeltas(hStore, hq.extractDeltas(pulled, { rev: 0, ts: '' }), { appendOnly: [] });
  hq.seedIndex(hStore);
  assert.equal(hStore.printLog.length, 2, 'HQ received both orders through the envelope');

  hStore.printLog.find((r) => r.id === 'o1').project = 'bracket v2';
  hStore.printLog = hStore.printLog.filter((r) => r.id !== 'o2');
  hq.stampChanges(hStore);
  upload(hStore, hqDek);

  // Branch pulls back.
  const back = download(branchDek);
  branch.applyDeltas(bStore, branch.extractDeltas(back, { rev: 0, ts: '' }), { appendOnly: [] });

  assert.equal(canon(bStore), canon(hStore), 'both devices agree, byte for byte');
  assert.equal(bStore.printLog.length, 1, 'the delete propagated');
  assert.equal(bStore.printLog[0].project, 'bracket v2', 'the edit propagated');
});

test('one device syncing both branches keeps them separate', () => {
  // The failure the per-shop index exists to stop, now driven the way the app
  // drives it: no explicit scope arguments, real ciphertext between the two.
  const { orgKeyset, shops } = buildOrg();
  const hq = device();
  const odk = sc.unlockOrgWithPassphrase('hq-passphrase', orgKeyset);

  const cloud = {};
  const stores = {};
  for (const [id, order] of [['shop-riyadh', 'riyadh-bracket'], ['shop-jeddah', 'jeddah-vase']]) {
    const s = shops[id];
    const dek = sc.unlockWithOrg(odk, orgKeyset.orgId, s.keyset);
    const store = snap({ printLog: [{ id: `${id}-o1`, project: order }] });
    hq.setScope(id);
    hq.seedIndex(store);
    hq.stampChanges(store);
    cloud[id] = sc.encryptStore(store, dek);
    stores[id] = store;
  }

  // Riyadh was stamped first, then Jeddah, in one process. Before the per-shop
  // index that wrote a tombstone for every Riyadh record into Jeddah's store —
  // and tombstones win unconditionally, so they would go on to delete live rows.
  for (const [id, store] of Object.entries(stores)) {
    assert.deepEqual(store.tombstones, [], `${id} received no foreign deletions`);
    assert.equal(store.printLog.length, 1, `${id} kept exactly its own record`);
  }

  // And what landed in the cloud is per-shop, readable only with that shop's key.
  const riyadhDek = sc.unlockWithOrg(odk, orgKeyset.orgId, shops['shop-riyadh'].keyset);
  const jeddahDek = sc.unlockWithOrg(odk, orgKeyset.orgId, shops['shop-jeddah'].keyset);
  assert.equal(sc.decryptStore(cloud['shop-riyadh'], riyadhDek).printLog[0].project, 'riyadh-bracket');
  assert.throws(() => sc.decryptStore(cloud['shop-jeddah'], riyadhDek));
  assert.equal(sc.decryptStore(cloud['shop-jeddah'], jeddahDek).printLog[0].project, 'jeddah-vase');
});

test('the org recovery key reaches every branch when the passphrase is lost', () => {
  // The recovery story the design doc argues for: ONE org key, and losing the org
  // passphrase must not cost the owner their branches.
  const { orgKeyset, orgRecovery, shops } = buildOrg();
  const cloud = {};
  for (const s of Object.values(shops)) {
    cloud[s.id] = sc.encryptStore(snap({ printLog: [{ id: 'o1', project: s.id }] }), s.dek);
  }

  const odk = sc.unlockOrgWithRecovery(orgRecovery, orgKeyset);
  for (const s of Object.values(shops)) {
    const dek = sc.unlockWithOrg(odk, orgKeyset.orgId, s.keyset);
    assert.equal(sc.decryptStore(cloud[s.id], dek).printLog[0].project, s.id);
  }

  // And the per-shop recovery keys still work independently — a shop that joined
  // an org did not hand its own recovery path over to the org.
  for (const s of Object.values(shops)) {
    const dek = sc.unlockWithRecovery(s.recoveryKey, s.keyset);
    assert.equal(sc.decryptStore(cloud[s.id], dek).printLog[0].project, s.id);
  }
});

test('a branch that leaves the org keeps its data and closes the org’s way in', () => {
  const { orgKeyset, shops } = buildOrg();
  const s = shops['shop-jeddah'];
  const odk = sc.unlockOrgWithPassphrase('hq-passphrase', orgKeyset);
  const blob = sc.encryptStore(snap({ printLog: [{ id: 'o1', project: 'jig' }] }), s.dek);

  const left = sc.leaveOrg(s.keyset);
  assert.throws(() => sc.unlockWithOrg(odk, orgKeyset.orgId, left));

  // The branch's own owner is unaffected — both of their paths still open it.
  for (const dek of [sc.unlockWithPassphrase('jeddah-pass', left), sc.unlockWithRecovery(s.recoveryKey, left)]) {
    assert.equal(sc.decryptStore(blob, dek).printLog[0].project, 'jig');
  }

  // The other branch is untouched by one leaving.
  const other = shops['shop-riyadh'];
  assert.deepEqual(sc.unlockWithOrg(odk, orgKeyset.orgId, other.keyset), other.dek);
});
