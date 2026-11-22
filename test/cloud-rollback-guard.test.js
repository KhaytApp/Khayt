'use strict';

/**
 * A cloud that goes backwards is refused, not applied (lib/cloud-revision-memory.js),
 * the same rule as the Mac's CloudReader.RevisionMemory (#1712).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const sc = require('../lib/sync-crypto.js');
const { createCloudBackend } = require('../lib/cloud-backend.js');
const { createRevisionMemory, keyFor } = require('../lib/cloud-revision-memory.js');

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };

test('the memory raises on a pull, sets on a confirmed push, and survives a restart', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-revmem-'));
  try {
    const file = path.join(dir, 'highest-revisions.json');
    const m = createRevisionMemory({ file, url: 'https://Cloud.Example/', shopId: 'S1' });
    assert.equal(m.highest(), null);
    m.saw(7); m.saw(3);
    assert.equal(m.highest(), 7, 'a pull never lowers the mark');
    m.confirmed(2);
    assert.equal(m.highest(), 2, 'the server answered our own write: that is where it is');
    const again = createRevisionMemory({ file, url: 'https://cloud.example', shopId: 'S1' });
    assert.equal(again.highest(), 2, 'remembered across a relaunch, case and trailing slash folded');
    assert.equal(createRevisionMemory({ file, url: 'https://cloud.example', shopId: 'S2' }).highest(), null, 'per shop');
    assert.equal(keyFor('https://Cloud.Example/', 'S1'), 'https://cloud.example|S1', "the Mac's key");
    if (process.platform !== 'win32') assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    assert.equal(m.accept(), false, 'nothing refused, nothing to accept');
    m.refused(1);
    assert.equal(m.refusal(), 1);
    assert.equal(m.accept(), true);
    assert.equal(m.highest(), 1);
    assert.equal(m.refusal(), null);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

/** A server that can be rolled back to an earlier blob. */
function server() {
  const history = [];
  let cur = null;
  return {
    rollbackTo(rev) { cur = history.find((h) => h.rev === rev) || null; },
    async handle({ method, path: p, body }) {
      if (!/^\/v1\/shops\/[^/]+\/store/.test(String(p))) return { status: 404 };
      if (method === 'GET') return cur ? { status: 200, body: { ciphertext: cur.ciphertext, rev: cur.rev } } : { status: 204 };
      if (method === 'PUT') {
        const curRev = cur ? cur.rev : 0;
        if ((body.baseRev | 0) !== curRev) return { status: 409, body: { rev: curRev } };
        cur = { rev: curRev + 1, ciphertext: body.ciphertext };
        history.push(cur);
        return { status: 200, body: { rev: cur.rev } };
      }
      return { status: 405 };
    },
  };
}

test('a pull below the highest revision seen is refused, and the shop can accept it', async () => {
  const { keyset } = sc.createKeyset('p', { kdf: FAST_KDF });
  const dek = sc.unlockWithPassphrase('p', keyset);
  const srv = server();
  const mem = createRevisionMemory({ url: 'https://c', shopId: 'S' });
  const b = createCloudBackend({ transport: (r) => srv.handle(r), crypto: sc, shopId: 'S', getDek: () => dek, revMemory: mem });

  await b.push({ printLog: [{ id: 'o1', rev: 1 }] });
  await b.push({ printLog: [{ id: 'o1', rev: 1 }, { id: 'o2', rev: 1 }] });
  assert.equal(mem.highest(), 2);

  srv.rollbackTo(1);   // the server serves last month's store
  await assert.rejects(() => b.pull(), (e) => e.code === 'CLOUD_WENT_BACKWARDS' && e.seen === 2 && e.got === 1);
  assert.equal(b.rollbackRefusal(), 1);
  assert.equal(mem.highest(), 2, 'refusing does not move the mark');

  assert.equal(b.acceptRollback(), true, 'the shop restored it on purpose');
  const r = await b.pull();
  assert.equal(r.rev, 1);
  assert.deepEqual(r.store.printLog.map((o) => o.id), ['o1']);
});

test('no memory, no check: an old caller behaves exactly as before', async () => {
  const { keyset } = sc.createKeyset('p', { kdf: FAST_KDF });
  const dek = sc.unlockWithPassphrase('p', keyset);
  const srv = server();
  const b = createCloudBackend({ transport: (r) => srv.handle(r), crypto: sc, shopId: 'S', getDek: () => dek });
  await b.push({ printLog: [] }); await b.push({ printLog: [{ id: 'x', rev: 1 }] });
  srv.rollbackTo(1);
  assert.equal((await b.pull()).rev, 1);
  assert.equal(b.acceptRollback(), false);
});
