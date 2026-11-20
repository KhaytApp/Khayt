/**
 * E2E smoke — the staff lock is on and nobody is signed in: the app asks who
 * it is as it starts (pre-cut review MED2, after #2592 made that window a
 * viewer). A book with someone signed in, or with the lock off, starts with
 * no PIN pad.
 *
 * Run: npm run test:e2e:lockpin   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

/** A book written before launch, as a shop that locked up and quit would leave it. */
function bookWith({ lock, activeOperatorId }) {
  const dir = makeUserDataDir();
  const book = {
    settings: { firstRun: false, firstRunDone: true, operatorLockEnabled: lock, activeOperatorId, bizName: 'Lock Shop' },
    operators: [
      { id: 'op-owner', name: 'Owner', roleKey: 'owner', active: true },
      { id: 'op-staff', name: 'Staff', roleKey: 'operator', active: true },
    ],
    printLog: [], clients: [], inventory: [], machines: [],
  };
  fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify(book));
  return dir;
}

async function padShown(dir) {
  const { electronApp, window } = await launchApp(dir);
  try {
    await window.waitForTimeout(800);
    return await window.evaluate(() => !!document.getElementById('pinPadOverlay'));
  } finally {
    await electronApp.close();
  }
}

let failed = false;
try {
  ok(await padShown(bookWith({ lock: true, activeOperatorId: null })), 'lock on, nobody signed in: the PIN pad opens at start');
  ok(await padShown(bookWith({ lock: true, activeOperatorId: 'op-gone' })), 'lock on, signed in as someone no longer on the team: the PIN pad opens');
  ok(!(await padShown(bookWith({ lock: true, activeOperatorId: 'op-staff' }))), 'lock on, someone signed in: no PIN pad');
  ok(!(await padShown(bookWith({ lock: false, activeOperatorId: null }))), 'lock off: no PIN pad');
  console.log('\ne2e-lock-pin-at-boot: ok');
} catch (e) {
  failed = true;
  console.error('\ne2e-lock-pin-at-boot FAILED: ' + (e && e.message || e));
}
process.exit(failed ? 1 : 0);
