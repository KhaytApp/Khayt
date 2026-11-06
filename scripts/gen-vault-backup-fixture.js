'use strict';
/**
 * Writes test/fixtures/vault-backup-meta/: what a Windows/Linux backup of one
 * library model puts in the vault, for the Mac to run through its VaultApply
 * matching (the record must gain vaultFileId on the SAME record, no new record,
 * no 7-day hold). Runs the real lib/main/vault-backup.js against a fake vault.
 *
 *   node scripts/gen-vault-backup-fixture.js         (re-write; ciphertext changes)
 *   node scripts/gen-vault-backup-fixture.js --check (the meta plaintext still matches)
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const VC = require('../lib/vault-crypto.js');
const VaultLinks = require('../lib/vault-links.js');
const { createVaultBackup } = require('../lib/main/vault-backup.js');

const OUT = path.join(__dirname, '..', 'test', 'fixtures', 'vault-backup-meta');
const DEK = Uint8Array.from({ length: 32 }, (_, i) => i + 1);
// A record id with a slash, a colon and a space: its folder name is the
// itemDirName transform's whole job, and the Mac must reach the same folder.
const RECORD = { id: 'PF-2026/ab:c d', name: 'Dragon', sourceFile: { filename: 'Dragon.3MF' } };
const BYTES = Buffer.from('solid fixture\nfacet normal 0 0 1\nendsolid fixture\n'.repeat(40));

async function run() {
  const rows = new Map(); let rev = 0;
  const uploads = new Map(); let n = 0;
  globalThis.fetch = async (url, init) => {
    const json = (s, b) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } });
    if (url.startsWith('https://store.example/')) { const [, id, i] = new URL(url).pathname.match(/^\/up\/([^/]+)\/(\d+)$/); uploads.get(id).parts[i] = Buffer.from(init.body).toString('base64'); return new Response('', { status: 200 }); }
    const tail = url.replace(/^https:\/\/cloud\.example\/v1\/shops\/shop_1/, '');
    const b = init.body ? JSON.parse(init.body) : null;
    let m;
    if (init.method === 'GET' && tail.startsWith('/vault/files')) return json(200, { rev, more: false, files: [...rows.values()] });
    if (init.method === 'POST' && tail === '/vault/uploads') {
      const fileId = 'fixtureFile1', uploadId = 'fixtureUpload' + (++n);
      uploads.set(uploadId, { fileId, sizes: b.sizes, parts: {} });
      return json(201, { uploadId, fileId, version: 1, expiresAt: 'x', parts: b.sizes.map((size, index) => ({ index, size, url: `https://store.example/up/${uploadId}/${index}` })) });
    }
    if (init.method === 'POST' && (m = tail.match(/^\/vault\/uploads\/([^/]+)\/complete$/))) {
      const u = uploads.get(m[1]);
      rows.set(u.fileId, { fileId: u.fileId, head: 1, meta: b.meta, metaRev: 1,
        versions: [{ version: 1, uploadId: m[1], wrappedKey: b.wrappedKey, versionMeta: b.versionMeta, manifestHash: b.manifestHash, chunks: u.sizes.length, bytes: u.sizes.reduce((a, x) => a + x, 0),
          // The real cloud always sends it (khayt-cloud src/store.js), and the Mac's
          // VaultClient.Version will not decode a row without it.
          chunkBytes: 4194304 }],
        _sealedChunksB64: u.parts });
      rev++;
      return json(201, { fileId: u.fileId, version: 1, rev, conflict: false });
    }
    throw new Error('unexpected ' + init.method + ' ' + url);
  };
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'vbfx-'));
  const lib = fs.mkdtempSync(path.join(os.tmpdir(), 'vbfx-lib-'));
  const { itemDirName } = require('../lib/print-library-location.js');
  fs.mkdirSync(path.join(lib, itemDirName(RECORD.id)));
  fs.writeFileSync(path.join(lib, itemDirName(RECORD.id), RECORD.sourceFile.filename), BYTES);
  const vb = createVaultBackup({
    app: { getPath: () => userData },
    readBook: () => ({ settings: { cloud: { enabled: true, shopId: 'shop_1', url: 'https://cloud.example', token: 't' } }, printFiles: [RECORD] }),
    getDek: () => DEK, cloudToken: (t) => t, isVaultOn: () => true,
    itemDir: (id) => path.join(lib, itemDirName(id)), isModelFile: (x) => /\.(3mf|stl)$/i.test(x), deviceId: 'desktop', log: { warn() {} },
  });
  const r = await vb.backUp([RECORD.id]);
  if (!r.ok) throw new Error('backup failed: ' + JSON.stringify(r));
  const row = rows.get('fixtureFile1');
  const meta = await VaultLinks.openShopMeta(await VC.deriveVaultKey(DEK), row);
  return { row, meta };
}

(async () => {
  const { row, meta } = await run();
  const stable = { key: meta.key, kind: meta.kind, name: meta.name, path: meta.path, seq: meta.seq, size: meta.size, sha256: meta.sha256, hasRecordId: 'recordId' in meta };
  if (process.argv.includes('--check')) {
    const want = JSON.parse(fs.readFileSync(path.join(OUT, 'expected.json'), 'utf8')).metaStable;
    if (JSON.stringify(want) !== JSON.stringify(stable)) { console.error('meta changed:', stable, 'expected', want); process.exit(1); }
    console.log('vault-backup fixture: meta matches'); return;
  }
  fs.writeFileSync(path.join(OUT, 'inputs.json'), JSON.stringify({ dekHex: Buffer.from(DEK).toString('hex'), record: RECORD, fileBytesB64: BYTES.toString('base64') }, null, 2) + '\n');
  fs.writeFileSync(path.join(OUT, 'feed-row.json'), JSON.stringify(row, null, 2) + '\n');
  fs.writeFileSync(path.join(OUT, 'expected.json'), JSON.stringify({ metaStable: stable, metaPlain: meta,
    expectAfterVaultApply: { recordId: RECORD.id, vaultFileId: row.fileId, contentHash: meta.sha256, sourceFileSize: meta.size, newRecords: 0, held: false } }, null, 2) + '\n');
  console.log('wrote', OUT);
})().catch((e) => { console.error(e); process.exit(1); });
