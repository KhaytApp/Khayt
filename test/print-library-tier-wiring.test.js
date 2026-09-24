/**
 * Tiering is the only thing in Khayt that deletes a customer's model on purpose.
 *
 * The pure logic is covered in print-library-tier.test.js. What that file cannot
 * see is the ORDER of operations in main.js, and the order is the whole safety
 * argument. Each test here pins one step that, reversed or dropped, loses models
 * silently — the shop finds out months later, opening an old order.
 *
 * These are source assertions rather than behaviour, for the same reason the S3
 * wiring test is: main.js needs an Electron main process, and a guarantee that
 * can only be checked by running the app is a guarantee nobody checks.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const mainJs = read('main.js');
const preload = read('preload.js');
const settingsJs = read('renderer/settings.js');
const wire = read('renderer/wire-events.js');
const html = read('renderer/index.html');

/** The body of a named function or handler, for order-of-operations checks. */
function bodyOf(needle, len = 3000) {
  const at = mainJs.indexOf(needle);
  assert.ok(at > -1, `${needle} went missing`);
  return mainJs.slice(at, at + len);
}

test('a local file is never deleted before the sidecar that records where it went', () => {
  // Reversed, a crash between the two steps loses the model outright: no file,
  // no record, nothing to tell the shop it was ever in a bucket.
  const body = bodyOf("ipcMain.handle('hub:printlib-tier-run'", 4000);
  const writeAt = body.indexOf('writeFile(f.fullPath + PLT.SIDECAR_EXT');
  const unlinkAt = body.indexOf('unlink(f.fullPath)');
  assert.ok(writeAt > -1, 'the sidecar is never written');
  assert.ok(unlinkAt > -1, 'the local file is never removed — nothing is freed');
  assert.ok(writeAt < unlinkAt, 'the model is deleted before its sidecar is written');
});

test('the upload is confirmed by a second request before anything is deleted', () => {
  // A PUT that returns 200 through a proxy which stored nothing is exactly the
  // case this exists to catch, so the confirmation cannot be the upload's own
  // response.
  const body = bodyOf('async function printLibEnsureInBucket(', 3000);
  const putAt = body.indexOf('s3.client.put(');
  const headAfter = body.indexOf('s3.client.head(key)', putAt);
  assert.ok(putAt > -1 && headAfter > putAt, 'nothing re-checks the bucket after uploading');
  assert.match(body, /if \(!after\) return \{ ok: false/, 'a missing object after upload is not caught');
  assert.match(body, /after\.size !== local/, 'the stored size is not compared with the local one');
});

test('a size match alone is not enough to delete', () => {
  // The etag is what makes it a content check. Without it, a truncated-then-
  // padded upload and a colliding key both pass.
  const body = bodyOf('async function printLibEnsureInBucket(', 3000);
  assert.match(body, /PLT\.etagVerdict\(/, 'the etag is never checked');
  assert.match(body, /verdict === 'mismatch'/, 'a disagreeing bucket is not refused');
  // 'unusable' must not fall through to a delete — it has to pay for the
  // download and hash it instead.
  assert.match(body, /verdict === 'unusable'/, 'an unreadable etag is treated as proof');
  const unusableAt = body.indexOf("verdict === 'unusable'");
  assert.match(body.slice(unusableAt, unusableAt + 700), /s3\.client\.get\(key\)/,
    'an unreadable etag should force a real download to verify, not a delete on faith');
});

test('every read path fetches a tiered file back before touching it', () => {
  // Missed on any one of these, that feature breaks for tiered models only —
  // which looks like data loss to the shop and reproduces for nobody else.
  for (const handler of ['printlib-read-bytes', 'printlib-open-in-slicer', 'printlib-mesh']) {
    const at = mainJs.indexOf(`ipcMain.handle('hub:${handler}'`);
    assert.ok(at > -1, `${handler} went missing`);
    assert.match(mainJs.slice(at, at + 900), /await printLibRehydrate\(/,
      `${handler} would open a tiered model as a missing file`);
  }
});

test('a download is verified against the sidecar before it is trusted', () => {
  const body = bodyOf('async function printLibRehydrate(', 3000);
  assert.match(body, /PLT\.verifyRehydrate\(/, 'whatever comes back is written without checking');
  const verifyAt = body.indexOf('PLT.verifyRehydrate(');
  const writeAt = body.indexOf('writeFile(tmp', verifyAt);
  assert.ok(writeAt > verifyAt, 'the file is written before it is verified');
});

test('a rehydrate lands atomically, never as a half-written model', () => {
  // A partial file at the real path is indistinguishable from a whole one on the
  // next open, and parses as a corrupt mesh rather than as a failed download.
  const body = bodyOf('async function printLibRehydrate(', 3000);
  assert.match(body, /\.part-/, 'the download is written straight to its final path');
  assert.match(body, /fs\.promises\.rename\(tmp, p\)/, 'the temporary file is never renamed into place');
  const renameAt = body.indexOf('rename(tmp, p)');
  const sideUnlink = body.indexOf('unlink(sidePath)');
  assert.ok(sideUnlink > renameAt,
    'the sidecar is removed before the file is in place — a crash between them loses both');
});

test('two opens of the same tiered model do not race each other', () => {
  // Both would write the same path, and the loser truncates the winner's file.
  const body = bodyOf('async function printLibRehydrate(', 3000);
  assert.match(body, /printLibRehydrating\.(has|get)\(/, 'concurrent rehydrates are not coalesced');
});

test('the listing keeps working with the bucket unreachable', () => {
  // "In the cloud" and "gone" must never look the same on screen, and they will
  // if the listing has to ask the bucket what it holds.
  const at = mainJs.indexOf("ipcMain.handle('hub:printlib-list'");
  const body = mainJs.slice(at, at + 1200);
  assert.match(body, /printLibSidecarMap\(/, 'the listing does not fold in tiered files');
  assert.doesNotMatch(body, /await s3|s3\.client/, 'the listing asks the bucket, so it breaks offline');
});

test('deleting a model also removes its sidecar', () => {
  // Otherwise the library keeps listing a file the shop deleted, and offers to
  // download it.
  const at = mainJs.indexOf("ipcMain.handle('hub:printlib-delete'");
  const body = mainJs.slice(at, at + 1400);
  assert.match(body, /\[safe \+ PLT\.SIDECAR_EXT, safe\]/, 'a tiered file cannot be deleted at all');
});

test('a sweep refuses to run without a bucket, or while switched off', () => {
  const body = bodyOf("ipcMain.handle('hub:printlib-tier-run'", 1500);
  assert.match(body, /if \(!policy\.enabled\)/, 'a disabled policy still sweeps');
  assert.match(body, /if \(!s3\)/, 'it would delete local files with nowhere to put them');
});

test('two sweeps cannot run at once', () => {
  // Each would be deleting what the other is still verifying.
  assert.match(mainJs, /let printLibSweeping = false;/, 'no guard exists');
  const body = bodyOf("ipcMain.handle('hub:printlib-tier-run'", 600);
  assert.match(body, /if \(printLibSweeping\)/, 'the sweep does not check the guard');
});

test('there is a way back out', () => {
  // A feature that deletes local files and cannot be reversed is a trap.
  assert.match(mainJs, /ipcMain\.handle\('hub:printlib-tier-restore-all'/, 'nothing restores a tiered library');
  assert.match(preload, /printLibTierRestoreAll/, 'restore is not reachable from the renderer');
  assert.match(html, /id="btnPlibTierRestore"/, 'restore has no button');
});

test('the sweep is confirmed, with the numbers it turns on', () => {
  const at = settingsJs.indexOf('async function runPrintLibTier(');
  const body = settingsJs.slice(at, at + 2500);
  assert.match(body, /confirm\(/, 'models are removed from the disk with no confirmation');
  assert.match(body, /s\.count/, 'the confirmation does not say how many');
  assert.match(body, /s\.human/, 'the confirmation does not say how much space');
});

test('failures are named, not counted', () => {
  // "3 files failed" leaves the shop unable to tell whether that was three
  // thumbnails or three customer models.
  const at = settingsJs.indexOf('async function runPrintLibTier(');
  const body = settingsJs.slice(at, at + 3000);
  assert.match(body, /r\.failed\.slice\(0, 3\)\.map/, 'failures are reported as a bare count');
});

test('the tiering controls are wired to functions that exist and are exported', () => {
  for (const [id, fn] of [
    ['btnPlibTierSave', 'savePrintLibTier'],
    ['btnPlibTierRun', 'runPrintLibTier'],
    ['btnPlibTierRestore', 'restorePrintLibTier'],
    ['set_plibS3Provider', 'onPrintLibProviderChange'],
  ]) {
    assert.ok(html.includes(`id="${id}"`), `${id} is not in the page`);
    assert.ok(wire.includes(fn), `${id} is wired to nothing`);
    assert.match(settingsJs, new RegExp(`^\\s{4}${fn},`, 'm'), `${fn} is private to its IIFE, so the control does nothing`);
  }
});

test('the provider table has one home', () => {
  // Two copies is how the dropdown ends up offering a provider main cannot
  // resolve — the exact bug the presets were added to remove.
  assert.match(mainJs, /ipcMain\.handle\('hub:storage-resolve-endpoint'/, 'the renderer must build endpoints itself');
  assert.doesNotMatch(settingsJs, /r2\.cloudflarestorage\.com|backblazeb2\.com/,
    'the renderer has its own copy of the endpoint templates');
});

test('an incomplete preset is refused rather than saved as half a URL', () => {
  // A bucket configured with a literal "{account}" in the hostname fails as a
  // 403, which reads as a bad secret and sends the shop to re-copy a good key.
  const at = settingsJs.indexOf('async function savePrintLibS3(');
  const body = settingsJs.slice(at, at + 2200);
  assert.match(body, /if \(r && !r\.ok\)/, 'an unresolvable endpoint is saved anyway');
  const refuseAt = body.indexOf('if (r && !r.ok)');
  assert.match(body.slice(refuseAt, refuseAt + 600), /return;/, 'it warns but saves regardless');
});

test('the tiering section is translated everywhere', () => {
  // A key that only exists in en renders as its raw name for everyone else.
  const keys = [...html.matchAll(/data-i18n="(set\.plib_tier[^"]*)"/g)].map((m) => m[1]);
  assert.ok(keys.length >= 5, 'the tiering UI is not marked for translation at all');
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = read(`renderer/locales/${lang}.js`);
    for (const k of keys) assert.ok(src.includes(`"${k}"`), `${lang} is missing ${k}`);
  }
});
