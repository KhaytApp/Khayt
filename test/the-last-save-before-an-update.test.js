'use strict';
/**
 * The flush before an install went around every guarantee the store has.
 *
 * `hub:install-update` writes the renderer's final snapshot and then calls
 * quitAndInstall. It did that by hand:
 *
 *     const tmp = fp + '.tmp';
 *     await fs.promises.writeFile(tmp, serialized, 'utf8');
 *     await fs.promises.rename(tmp, fp);
 *
 * Four things wrong with it, all at the one moment the binary is about to be
 * replaced and the app cannot try again:
 *
 *   NO FSYNC            writeFile+rename leaves the bytes in the page cache, so
 *                       a power loss during the install can leave an empty or
 *                       partial store. atomicWriteStore fsyncs before swapping.
 *   NO .prev            the rename overwrote the primary without rotating it,
 *                       leaving the rollback copy describing a store two saves
 *                       old — which crash recovery then reads.
 *   BARE fp.tmp         the one filename recoverStoreRaw scans as a legacy
 *                       recovery candidate, so an interrupted flush left a file
 *                       the next launch would consider restoring from.
 *   OUTSIDE THE CHAIN   a renderer save already queued could land between this
 *                       rename and its own. The same race fixed for every LAN
 *                       endpoint in #898.
 *
 * The updater was only ever handed `encryptForDisk` and `dataFilePath`, so it
 * had no writer to call — which is how a second, weaker one came to exist.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const updater = code('lib/updater.js');

/** The pre-install flush block. */
function flushBlock() {
  const at = updater.indexOf("ipcMain.handle('hub:install-update'");
  assert.ok(at > 0, 'hub:install-update is gone');
  const end = updater.indexOf('quitAndInstall', at);
  assert.ok(end > at, 'the install no longer ends in quitAndInstall');
  return updater.slice(at, end);
}

test('the flush uses the shared writer', () => {
  assert.match(flushBlock(), /await writeStoreToDisk\(normalized\)/,
    'the pre-install flush writes the store by hand again');
});

test('it does not hand-roll a write', () => {
  const body = flushBlock();
  assert.ok(!/fs\.promises\.writeFile\(/.test(body),
    'the flush writes a file directly — no fsync, no .prev, outside the chain');
  assert.ok(!/fs\.promises\.rename\(/.test(body),
    'the flush renames into place itself, crossing generations with any queued save');
  assert.ok(!/fp \+ '\.tmp'/.test(body),
    "the flush writes the bare fp.tmp, which recoverStoreRaw treats as a recovery candidate");
});

test('main.js actually hands it the writer', () => {
  // Without the dep the flush silently does nothing, which is worse than the
  // bug: the last edits would rest on an earlier save with no message at all.
  const main = code('main.js');
  const at = main.indexOf('registerUpdater({');
  assert.ok(at > 0, 'registerUpdater is not called');
  const call = main.slice(at, main.indexOf('});', at));
  assert.match(call, /^\s*writeStoreToDisk,$/m,
    'registerUpdater is not given writeStoreToDisk — the flush would write nothing');
  assert.match(updater, /registerUpdater\(\{[^}]*writeStoreToDisk[^}]*\}\)/,
    'registerUpdater does not accept a writer');
});

test('a failed flush is logged loudly and does not block the install', () => {
  const body = flushBlock();
  assert.match(body, /catch \(e\)/, 'a throwing flush would take the install down with it');
  assert.match(body, /flush-save FAILED/, 'a failed flush is not distinguishable in the log');
  // The install still fires: the renderer is supposed to have saved already, and
  // stranding someone mid-update over an opportunistic flush is worse.
  assert.match(updater.slice(updater.indexOf("ipcMain.handle('hub:install-update'")),
    /quitAndInstall\(false, true\)/, 'the install no longer happens');
});

test('the shared writer still has the four properties this depends on', () => {
  // If any of these leave atomicWriteStore, routing the flush through it stops
  // buying anything and this whole change is undone silently.
  const io = code('lib/store-io.js');
  const at = io.indexOf('async function atomicWriteStoreUnsafe(');
  const body = io.slice(at, io.indexOf('\n  }', at));
  assert.match(body, /await fh\.sync\(\)/, 'the shared writer stopped fsyncing');
  assert.match(body, /rename\(fp, fp \+ '\.prev'\)/, 'the shared writer stopped keeping a rollback generation');
  assert.match(body, /\$\{fp\}\.tmp\.\$\{process\.pid\}/, 'the shared writer stopped using a unique temp name');
  assert.match(io, /_writeChain = run\.catch/, 'writes are no longer serialised through the chain');
});
