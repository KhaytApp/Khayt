'use strict';
/**
 * A store-io wired to a fake keychain, for asserting what actually happens to a
 * secret rather than what the source text looks like.
 *
 * The wiring guards used to match regexes against lib/store-io.js — "is
 * `d.settings.printLibrary.s3.secretAccessKey = encryptStoreField(` present".
 * That pinned one spelling of the code, so consolidating the four hand-written
 * secret lists onto one broke three guards without breaking any behaviour. A
 * guard that fails when correct code is rearranged, and would pass if the list
 * were driven from a table that omitted the field, is guarding the wrong thing.
 *
 * These run the real functions instead.
 */
const { createStoreIo } = require('../../lib/store-io.js');
const fsx = require('fs');
const os = require('os');
const pathx = require('path');

const MASK = '__KHAYT_MASKED__';

/**
 * Each harness gets its own userData directory. mergeStoreSecretsFromDisk reads
 * the real file rather than taking it as an argument, so "what is on disk" has
 * to be a real file — and a shared one would let tests see each other's secrets.
 */
function harness() {
  const dir = fsx.mkdtempSync(pathx.join(os.tmpdir(), 'khayt-store-io-'));
  const io = createStoreIo({
    app: { getPath: () => dir },
    fs: require('fs'),
    crypto: require('crypto'),
    safeJsonParse: JSON.parse,
    safeStorage: {
      isEncryptionAvailable: () => true,
      encryptString: (s) => Buffer.from('enc:' + s),
      decryptString: (b) => String(b).slice(4),
    },
  });
  io.userDataDir = dir;
  /** Put a store on disk in the encrypted-at-rest form, as a real save would. */
  io.putOnDisk = (store) => {
    fsx.writeFileSync(pathx.join(dir, 'khayt-store.json'),
      JSON.stringify(io.encryptForDisk(store)));
  };
  return io;
}

/**
 * Where a dotted path lands in a store: `a.b[].c` is the first element of the
 * array at `a.b` (`machines[]` or `settings.plugins[]`), and a trailing `{}`
 * is one value of the object there. Returns [root, keys].
 */
function locate(store, path, create) {
  const p = path.endsWith('{}') ? path.slice(0, -2) + '.k1' : path;
  if (!p.includes('[].')) return [store, p.split('.')];
  const [head, tail] = p.split('[].');
  let cur = store;
  const hk = head.split('.');
  for (const k of hk.slice(0, -1)) cur = cur[k] || (create ? (cur[k] = {}) : {});
  const last = hk[hk.length - 1];
  if (!Array.isArray(cur[last]) && create) cur[last] = [{ id: 'ITEM-1' }];
  return [(cur[last] || [])[0] || {}, tail.split('.')];
}

/** Build a store with one value at a dotted path. Any `x[]` and a trailing `{}` are supported. */
function storeWith(path, value) {
  const store = { settings: {}, machines: [{ id: 'MACH-1', printerApi: {} }] };
  const [root, keys] = locate(store, path, true);
  let cur = root;
  for (const k of keys.slice(0, -1)) cur = cur[k] || (cur[k] = {});
  cur[keys[keys.length - 1]] = value;
  return store;
}

function valueAt(store, path) {
  const [root, keys] = locate(store, path, false);
  let cur = root;
  for (const k of keys) { if (!cur || typeof cur !== 'object') return undefined; cur = cur[k]; }
  return cur;
}

/**
 * The four things that must be true of every credential in the store, checked by
 * doing them. Each has its own failure in the field:
 *   not encrypted → the secret sits in cleartext in the file people copy around
 *   not decrypted → the app uses "__enc__AAAA…" as the credential
 *   not masked    → the renderer holds the real secret; so does any screenshot
 *   not restored  → saving an unrelated setting writes the mask over it, and the
 *                   credential is gone for good
 */
function assertProtected(assert, path, what) {
  const io = harness();
  const secret = 'S3CR3T-' + path;

  const onDisk = io.encryptForDisk(storeWith(path, secret));
  assert.match(String(valueAt(onDisk, path)), /^__enc__/,
    `${what} is written to the store in plaintext`);

  const back = io.decryptStoreSecrets(JSON.parse(JSON.stringify(onDisk)));
  assert.equal(valueAt(back, path), secret,
    `${what} is never decrypted coming back, so the feature silently stops working`);

  const shown = io.maskStoreSecretsForRenderer(storeWith(path, secret));
  assert.equal(valueAt(shown, path), MASK,
    `${what} is handed to the renderer in the clear`);

  io.putOnDisk(storeWith(path, secret));
  const merged = io.mergeStoreSecretsFromDisk(storeWith(path, MASK));
  assert.equal(valueAt(merged, path), secret,
    `saving an unrelated setting writes the mask over ${what} and destroys it`);

  assert.equal(io.hasPlaintextSecrets(storeWith(path, secret)), true,
    `a plaintext ${what} is not counted as one worth warning about`);
}

module.exports = { harness, storeWith, valueAt, assertProtected, MASK };
