/**
 * E2E smoke — the staff lock is on and nobody is signed in: the app asks who
 * it is as it starts (pre-cut review MED2, after #2592 made that window a
 * viewer). Under the lock nobody stays signed in across a restart (#2608
 * security review): a book saved with the owner signed in opens on the PIN
 * pad too, and is saved signed out. With the lock off nothing changes.
 *
 * Run: npm run test:e2e:lockpin   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';
import { createRequire } from 'node:module';
const require_ = createRequire(import.meta.url);

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

/** A book written before launch, as a shop that locked up and quit would leave it. */
function bookWith({ lock, activeOperatorId, ownerPinHash }) {
  const dir = makeUserDataDir();
  const book = {
    settings: { firstRun: false, firstRunDone: true, operatorLockEnabled: lock, activeOperatorId, bizName: 'Lock Shop' },
    operators: [
      { id: 'op-owner', name: 'Owner', roleKey: 'owner', active: true, ...(ownerPinHash ? { pinHash: ownerPinHash } : {}) },
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

/** Start, pick the owner on the pad, type `pin`, press Confirm; what the pad says after. */
async function tryOwnerPin(dir, pin) {
  const { electronApp, window } = await launchApp(dir);
  try {
    await window.waitForTimeout(800);
    const opened = await window.evaluate(() => !!document.getElementById('pinPadOverlay'));
    if (!opened) return { opened };
    await window.evaluate(() => { const sel = document.getElementById('pinOpSelect'); sel.value = 'op-owner'; sel.dispatchEvent(new Event('change')); });
    for (const k of pin) await window.click(`#pinPadOverlay [data-k="${k}"]`);
    await window.click('#btnConfirmPin');
    await window.waitForTimeout(800);
    const after = await window.evaluate(() => ({
      stillOpen: !!document.getElementById('pinPadOverlay'),
      error: (document.getElementById('pinError') || {}).textContent || '',
      line: typeof t === 'function' ? t('op.pin_legacy') : '',
      signedIn: (typeof settings !== 'undefined' && settings && settings.activeOperatorId) || null,
    }));
    return { opened, ...after };
  } finally {
    await electronApp.close();
  }
}

let failed = false;
try {
  ok(await padShown(bookWith({ lock: true, activeOperatorId: null })), 'lock on, nobody signed in: the PIN pad opens at start');
  ok(await padShown(bookWith({ lock: true, activeOperatorId: 'op-gone' })), 'lock on, signed in as someone no longer on the team: the PIN pad opens');
  const owner = bookWith({ lock: true, activeOperatorId: 'op-owner' });
  ok(await padShown(owner), 'lock on, the owner signed in when the app closed: the PIN pad opens anyway');
  const saved = JSON.parse(fs.readFileSync(path.join(owner, 'khayt-store.json'), 'utf8'));
  ok(saved.settings && saved.settings.activeOperatorId === null, 'and the book is saved with nobody signed in');
  ok(!(await padShown(bookWith({ lock: false, activeOperatorId: null }))), 'lock off: no PIN pad');
  const off = bookWith({ lock: false, activeOperatorId: 'op-staff' });
  ok(!(await padShown(off)), 'lock off with someone recorded: no PIN pad');
  ok(JSON.parse(fs.readFileSync(path.join(off, 'khayt-store.json'), 'utf8')).settings.activeOperatorId === 'op-staff', 'and nothing is changed');
  // Turki, Nov 22: a PIN the pad cannot check (not a hash, not the first
  // releases' btoa) is signed out at start like everyone, cannot unlock, and
  // the pad says to ask the owner for a new one.
  const junk = bookWith({ lock: true, activeOperatorId: 'op-owner', ownerPinHash: 'junk!' });
  const j = await tryOwnerPin(junk, '1234');
  ok(j.opened, 'an unreadable PIN, signed in when the app closed: the PIN pad opens at start');
  ok(j.stillOpen && !j.signedIn, 'any PIN typed for them does not unlock');
  ok(j.line && j.error === j.line, `the pad says: ${j.error}`);
  const jb = JSON.parse(fs.readFileSync(path.join(junk, 'khayt-store.json'), 'utf8'));
  ok(jb.settings.activeOperatorId === null && jb.operators[0].pinHash === 'junk!', 'nobody signed in, and the stored PIN left for the owner to replace');

  // A first-release btoa PIN that DOES decode is hashed at load (#2609) and
  // unlocks with the same digits. Only once #2609 is in: before it, that
  // PIN reads as unreadable and the line above is what the pad says.
  const PinHash = require_('../lib/pin-hash.js');
  const old = bookWith({ lock: true, activeOperatorId: 'op-owner', ownerPinHash: Buffer.from('1234').toString('base64') });
  const o = await tryOwnerPin(old, '1234');
  ok(o.opened, 'a first-release PIN, signed in when the app closed: the PIN pad opens at start');
  if (typeof PinHash.decodeLegacyBtoaPin === 'function') {
    ok(!o.stillOpen && o.signedIn === 'op-owner', 'with #2609: hashed at load, and the same digits unlock');
  } else {
    ok(o.stillOpen && o.error === o.line, 'without #2609 (this branch alone): read as unreadable, the same line');
    console.log('  ℹ #2609 not in this build: the decodable-PIN unlock is checked once it is');
  }

  console.log('\ne2e-lock-pin-at-boot: ok');
} catch (e) {
  failed = true;
  console.error('\ne2e-lock-pin-at-boot FAILED: ' + (e && e.message || e));
}
process.exit(failed ? 1 : 0);
