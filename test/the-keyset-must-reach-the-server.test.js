'use strict';
/**
 * Four keyset uploads whose result nobody read.
 *
 * The keyset is what makes the encrypted store READABLE. Without it on the
 * server, a second device logs in, gets no keyset, and cannot open a store that
 * is sitting right there.
 *
 * Every one of the four call sites carefully checked the result of every OTHER
 * call in its handler — orgEnrolShop, orgPut, orgUnlock, cloudLogin, cloudUnlock
 * — and then threw away the `{ok:false,error}` from the one that persists the
 * result:
 *
 *     settings.cloud.keyset = enrol.keyset;
 *     await window.hubAPI.cloudPutKeyset({ ... });   // result discarded
 *     saveAll();
 *
 * The worst is the login path. An account with no keyset has one created from
 * the passphrase, and the recovery key is shown as though it were saved. If the
 * upload failed, that shop's store existed on ONE machine, behind a recovery key
 * the owner had just been told to write down — and nothing said so.
 *
 * Same shape as the daily backup that stopped at 20 MB: a result ignored, with a
 * reassuring UI on top.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const settings = code('renderer/settings.js');

test('every raw keyset upload has its answer read', () => {
  // Five call sites, and exactly one of them was already right: the SIGN-UP
  // path checked `up.ok` and returned. That is why an "unassigned await" sweep
  // did not flag it, and why this asserts the property rather than the shape.
  const helperAt = settings.indexOf('async function putCloudKeyset(');
  assert.ok(helperAt > 0, 'the checked helper is gone');
  const offenders = [];
  for (const m of settings.matchAll(/hubAPI\.cloudPutKeyset\(/g)) {
    if (m.index > helperAt && m.index < helperAt + 700) continue;      // the helper's own call
    const after = settings.slice(m.index, m.index + 400);
    if (!/\.ok\b/.test(after.slice(0, 260))) {
      offenders.push(settings.slice(m.index - 60, m.index + 80).replace(/\s+/g, ' ').trim());
    }
  }
  assert.deepEqual(offenders, [],
    'a keyset upload result is discarded — the shop is told nothing when the server refuses it');
});

test('every keyset write goes through the checked helper', () => {
  const uses = [...settings.matchAll(/putCloudKeyset\(/g)];
  // 1 definition + 4 converted call sites. The fifth (sign-up) already checked
  // its own result inline and keeps its own message, so it is not counted here.
  assert.equal(uses.length, 5, `expected 4 call sites plus the definition, found ${uses.length - 1} call sites`);
});

test('the helper reports a failure instead of returning quietly', () => {
  const at = settings.indexOf('async function putCloudKeyset(');
  const body = settings.slice(at, at + 1200);
  assert.match(body, /if \(r && r\.ok\) return true;/, 'the helper no longer distinguishes success');
  assert.match(body, /toast\(/, 'a failed keyset upload says nothing to the shop');
  assert.match(body, /cloud\.keyset_put_failed/, 'the failure has no message');
  assert.match(body, /catch \(e\)/, 'a thrown upload escapes the helper and the handler dies mid-way');
});

test('the recovery key is shown only once the server has the keyset', () => {
  // This is the data-loss one. Showing it first tells the owner their shop is
  // recoverable when it exists on one machine.
  // The HANDLER, not the button markup — the id appears in both, and anchoring
  // on the first match reads a block that never mentions a keyset at all.
  const at = settings.indexOf("#btnCloudLogin')?.addEventListener");
  assert.ok(at > 0, 'the cloud login handler is gone');
  const body = settings.slice(at, at + 2500);
  assert.match(body, /const saved = await putCloudKeyset\(/, 'the upload result is discarded again');
  assert.match(body, /if \(saved\) showRecoveryKeyModal\(recoveryKey\)/,
    'the recovery key is shown whether or not the server has the keyset');
  assert.match(body, /cloud\.keyset_retry/, 'a failed first keyset leaves the owner with no instruction');
  // The old shape must not come back.
  assert.ok(!/await window\.hubAPI\.cloudPutKeyset\([^)]*\);\s*showRecoveryKeyModal/.test(body));
});

test('both new strings exist in every locale', () => {
  const dir = path.join(ROOT, 'renderer', 'locales');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  assert.equal(files.length, 9);
  for (const f of files) {
    const src = read(path.join('renderer', 'locales', f));
    for (const k of ['cloud.keyset_put_failed', 'cloud.keyset_retry']) {
      assert.ok(src.includes(`"${k}"`), `${f} is missing ${k}`);
    }
  }
});

test('no other awaited cloud write throws its answer away', () => {
  // The sweep that found these four, kept so the next one fails here. A bare
  // `await hubAPI.cloudX(...)` statement on a path that changes what the server
  // holds is the shape being guarded.
  const WRITES = /^\s*await (?:window\.)?hubAPI\??\.(cloudPutKeyset|orgPut|cloudPush|cloudCreateKeyset|orgEnrolShop|orgRemoveShop)\(/gm;
  const offenders = [];
  for (const m of settings.matchAll(WRITES)) {
    const line = settings.slice(m.index, settings.indexOf('\n', m.index));
    if (!/=\s*await|return await/.test(line)) offenders.push(line.trim().slice(0, 90));
  }
  assert.deepEqual(offenders, [],
    'an awaited cloud write discards its result — the shop is told nothing when the server refuses');
});
