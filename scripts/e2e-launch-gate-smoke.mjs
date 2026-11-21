/**
 * E2E smoke — the "Before you update" items on the FIRST LAUNCH of a new
 * version (lib/main/launch-gate.js), for installs the update dialog never
 * sees: the Microsoft Store and installers run by hand.
 *
 * Against the gates THIS build carries (lib/release-gates.json, generated
 * from CHANGELOG.md): a computer last run on an older version is held until
 * the shop ticks and continues; the next start asks nothing; a fresh
 * install and one already accepted in the update dialog are not asked.
 *
 * Run: npm run test:e2e:launchgate   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const require_ = createRequire(import.meta.url);
const version = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8')).version;
const gates = require_(path.join(ROOT, 'lib/release-gates.json')).gates;
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

function profile({ book = true, seen = null } = {}) {
  const dir = makeUserDataDir();
  if (book) {
    fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify({
      settings: { firstRun: false, firstRunDone: true, bizName: 'Gate Shop' },
      printLog: [], clients: [], inventory: [], machines: [], operators: [],
    }));
  }
  // makeUserDataDir seeds "this version seen"; each case here says its own.
  const file = path.join(dir, 'last-run-version.json');
  if (seen) fs.writeFileSync(file, JSON.stringify(seen)); else fs.rmSync(file, { force: true });
  return dir;
}
const seenFile = (dir) => { try { return JSON.parse(fs.readFileSync(path.join(dir, 'last-run-version.json'), 'utf8')); } catch (_) { return null; } };

async function start(dir) {
  const { electronApp, window } = await launchApp(dir);
  await window.waitForTimeout(1000);
  return { electronApp, window, shown: await window.evaluate(() => !!document.getElementById('launchGateOverlay')) };
}

let failed = false;
try {
  // What a shop coming from before this file existed must read: every gate
  // after the floor, up to this build. A build with no gate of its own still
  // has these (reviews of #2610: the first draft skipped here, "nothing to
  // hold (ok)", while the app showed nothing at all).
  const { FLOOR } = require_(path.join(ROOT, 'lib/main/launch-gate.js'));
  const parts = (v) => String(v).split('-')[0].split('.').map(Number);
  const newer = (a, b) => { const x = parts(a), y = parts(b); for (let i = 0; i < 3; i++) { if (x[i] !== y[i]) return x[i] > y[i]; } return false; };
  const since = Object.keys(gates).filter((v) => newer(v, FLOOR) && !newer(v, version));
  const want = [...new Set(since.flatMap((v) => gates[v]))];
  if (!want.length) {
    if (Object.keys(gates).some((v) => newer(v, FLOOR))) throw new Error(`gates after ${FLOOR} exist but none applies to ${version}`);
    console.log(`e2e-launch-gate: no "Before you update" items after ${FLOOR}; nothing to hold (ok)`);
    process.exit(0);
  }

  // 1. Last run on an older version: held until read.
  const dir = profile({ seen: { lastRun: '0.0.1' } });
  let a = await start(dir);
  try {
    ok(a.shown, `last run on 0.0.1: the items up to ${version} are shown at start`);
    const items = await a.window.evaluate(() => [...document.querySelectorAll('#launchGateOverlay .update-consent-list li')].map((li) => li.textContent));
    ok(want.every((w) => items.includes(w)), `every item since ${FLOOR} is on screen (${want.length})`);
    ok(await a.window.evaluate(() => {
      const gate = document.getElementById('launchGateOverlay');
      const rest = [...document.body.children].filter((c) => !c.contains(gate) && c.tagName !== 'SCRIPT');
      return rest.length > 0 && rest.every((c) => c.inert);
    }), 'everything behind it is inert while it is open');
    // Something that opens after it (the update dialog, the PIN pad) is held back too (re-review).
    ok(await a.window.evaluate(async () => {
      const late = document.createElement('div');
      late.id = 'e2eLateModal';
      late.innerHTML = '<button>late</button>';
      (document.getElementById('modalMount') || document.body).appendChild(late);
      await new Promise((r) => setTimeout(r, 50));
      return late.inert === true;
    }), 'a dialog opened after it is inert too');
    ok(await a.window.evaluate(() => document.getElementById('launchGateContinue').disabled), 'Continue is held until the box is ticked');
    await a.window.keyboard.press('Escape');
    ok(await a.window.evaluate(() => !!document.getElementById('launchGateOverlay')), 'Escape does not dismiss it');
    await a.window.click('#launchGateAccept');
    ok(await a.window.evaluate(() => !document.getElementById('launchGateContinue').disabled), 'ticking releases Continue');
    await a.window.click('#launchGateContinue');
    await a.window.waitForFunction(() => !document.getElementById('launchGateOverlay'), { timeout: 5000 });
    ok(true, 'Continue closes it');
    ok(await a.window.evaluate(() => ![...document.body.children].some((c) => c.inert)), 'and gives the app back');
    ok(await a.window.evaluate(() => document.getElementById('e2eLateModal').inert === false), 'including what opened after it');
  } finally { await a.electronApp.close(); }
  ok((seenFile(dir) || {}).lastRun === version, `this computer is remembered as on ${version}`);

  // 1b. No file at all, a book present (an update from before the file
  // existed, a Store or manual install): counted from the floor, so held.
  const old = profile({ seen: null });
  a = await start(old);
  try {
    ok(a.shown, `no record and a book: the items since ${FLOOR} are shown`);
    const items = await a.window.evaluate(() => [...document.querySelectorAll('#launchGateOverlay .update-consent-list li')].map((li) => li.textContent));
    ok(want.every((w) => items.includes(w)), `all ${want.length} of them`);
  } finally { await a.electronApp.close(); }

  // 2. The next start asks nothing.
  a = await start(dir);
  try { ok(!a.shown, 'the next start asks nothing'); } finally { await a.electronApp.close(); }

  // 3. A fresh install, and one already accepted in the update dialog.
  const fresh = profile({ book: false });
  a = await start(fresh);
  try { ok(!a.shown, 'a fresh install is not warned'); } finally { await a.electronApp.close(); }
  ok((seenFile(fresh) || {}).lastRun === version, 'and is remembered as on this version');
  a = await start(profile({ seen: { lastRun: '0.0.1', acceptedFor: version } }));
  try { ok(!a.shown, 'accepted in the update dialog before the download: not asked again'); } finally { await a.electronApp.close(); }

  console.log(`\ne2e-launch-gate: ok (${want.length} item(s) from ${version} held at first launch)`);
} catch (e) {
  failed = true;
  console.error('\ne2e-launch-gate FAILED: ' + (e && e.message || e));
}
process.exit(failed ? 1 : 0);
