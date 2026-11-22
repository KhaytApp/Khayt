/**
 * E2E smoke — under the staff lock, what Khayt shares is the owner's to change
 * (Turki, Nov 22): the anonymous install count (hub:active-count-set) and the
 * crash-report and usage-statistics opt-ins (settings.telemetry, held by the
 * save guard). A manager is refused in both places, in words, and nothing
 * changes on disk; the owner, and anyone with the lock off, can.
 *
 * Run: npm run test:e2e:privacy-owner   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

function bookAs({ lock, who }) {
  const dir = makeUserDataDir();
  fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify({
    settings: { firstRun: false, firstRunDone: true, bizName: 'Privacy Shop', operatorLockEnabled: lock, activeOperatorId: who,
      telemetry: { crashOptIn: false, usageOptIn: false, installId: '', consentAt: '' } },
    operators: [
      { id: 'op-owner', name: 'Owner', roleKey: 'owner', active: true },
      { id: 'op-mgr', name: 'Manager', roleKey: 'manager', active: true },
    ],
    printLog: [], clients: [], inventory: [], machines: [],
  }));
  return dir;
}
const onDisk = (dir) => JSON.parse(fs.readFileSync(path.join(dir, 'khayt-store.json'), 'utf8'));

async function run(dir, fn) {
  const { electronApp, window } = await launchApp(dir);
  try {
    await window.waitForFunction(() => typeof settings !== 'undefined' && settings && settings.bizName === 'Privacy Shop', { timeout: 15000 });
    // A start may open the PIN pad (#2608); it is not what this tests.
    await window.evaluate(() => document.getElementById('pinPadOverlay')?.remove());
    return await fn(window);
  } finally { await electronApp.close(); }
}

let failed = false;
try {
  // 1. Lock on, a manager signed in: refused, said, nothing changed.
  const mgr = bookAs({ lock: true, who: 'op-mgr' });
  await run(mgr, async (w) => {
    const r = await w.evaluate(() => window.hubAPI.activeCountSet(false));
    ok(r && r.ok === false && r.error === 'not_permitted', 'the install-count switch is refused for a manager (main)');
    const refusedByWindow = await w.evaluate(async () => (await setTelemetryConsent(true, true)) === false);
    ok(refusedByWindow, 'the opt-ins are refused in the window, before any save');
    const toastText = await w.evaluate(() => [...document.querySelectorAll('.toast, [class*="toast"]')].map((n) => n.textContent).join(' | '));
    ok(/needs the owner/.test(toastText) && /crash reports and usage statistics/.test(toastText), 'and said in its own words');
    // Past the window: a save that carries the opt-ins anyway is put back by main.
    await w.evaluate(async () => {
      settings.telemetry = { crashOptIn: true, usageOptIn: true, installId: 'abcdef0123456789', consentAt: new Date().toISOString() };
      saveAll();
      if (typeof flushSave === 'function') await flushSave();
    });
    await w.waitForTimeout(500);
    // A restore point the manager makes carries no opt-ins the owner would
    // restore later (security review LOW-2).
    const rp = await w.evaluate(() => window.hubAPI.createRestorePoint({ json: JSON.stringify({ ...buildExportPayload({ redactSecrets: false }), settings: { ...settings, telemetry: { crashOptIn: true, usageOptIn: true, installId: 'abcdef0123456789', consentAt: '2026-11-22T00:00:00Z' } } }), label: 'friendly' }));
    ok(rp && rp.ok, 'a manager can still make a restore point');
    globalThis.__rpName = rp.filename;
  });
  const t1 = onDisk(mgr).settings.telemetry || {};
  ok(t1.crashOptIn !== true && t1.usageOptIn !== true && !t1.installId, 'a forced save is put back: nothing turned on on disk');
  const ac1 = (() => { try { return JSON.parse(fs.readFileSync(path.join(mgr, 'active-count.json'), 'utf8')); } catch (_) { return {}; } })();
  ok(ac1.off !== true, 'and the install count is not switched off');
  const rpDir = fs.readdirSync(mgr).find((d) => /restore/i.test(d));
  const rpFile = rpDir && path.join(mgr, rpDir, globalThis.__rpName);
  const rpBook = rpFile && fs.existsSync(rpFile) ? JSON.parse(fs.readFileSync(rpFile, 'utf8')) : null;
  ok(rpBook && (rpBook.settings.telemetry || {}).crashOptIn !== true, 'and the restore point holds the opt-ins as on disk, not as the manager sent them');

  // 2. Lock on, the owner signed in: both change.
  const own = bookAs({ lock: true, who: 'op-owner' });
  await run(own, async (w) => {
    const r = await w.evaluate(() => window.hubAPI.activeCountSet(false));
    ok(r && r.ok === true && r.on === false, 'the owner switches the install count off');
    ok(await w.evaluate(async () => (await setTelemetryConsent(true, false)) === true), 'the owner turns crash reports on');
    await w.evaluate(async () => { if (typeof flushSave === 'function') await flushSave(); });
  });
  ok((onDisk(own).settings.telemetry || {}).crashOptIn === true, 'and it is saved');

  // 3. Lock off: anyone, as today.
  const off = bookAs({ lock: false, who: null });
  await run(off, async (w) => {
    const r = await w.evaluate(() => window.hubAPI.activeCountSet(false));
    ok(r && r.ok === true, 'lock off: the install count switches');
    ok(await w.evaluate(async () => (await setTelemetryConsent(false, true)) === true), 'lock off: the opt-ins change');
  });

  // 4. A fresh install, before anything is saved: no lock, so the switch works
  // (security review LOW-1: main's copy of the book was still empty).
  const fresh = makeUserDataDir();
  {
    const { electronApp, window } = await launchApp(fresh);
    try {
      const r = await window.evaluate(() => window.hubAPI.activeCountSet(false));
      ok(r && r.ok === true, 'a fresh install switches the install count before its first save');
    } finally { await electronApp.close(); }
  }

  console.log('\ne2e-privacy-owner-only: ok');
} catch (e) {
  failed = true;
  console.error('\ne2e-privacy-owner-only FAILED: ' + (e && e.message || e));
}
process.exit(failed ? 1 : 0);
