#!/usr/bin/env node
/**
 * Recovery must hand back the NEWEST copy, and say what it handed back.
 *
 * Two faults, in the one path a shop only ever reaches on its worst day.
 *
 * 1. A write killed between `writeFile` and the atomic swap orphans its temp file
 *    permanently — nothing has ever cleaned one up, and every later save renames a
 *    DIFFERENT temp into place. Recovery preferred any `.tmp` over `.prev`, so one
 *    interrupted write in July outranked yesterday's good save.
 *
 * 2. Whatever came back, the shop saw a green tick reading "Recovered your data".
 *    A `.prev` recovery means the LAST SAVE IS GONE. That is real loss, and a tick
 *    is the wrong thing to show over it.
 *
 * A unit test cannot vouch for the second one: the message is assembled in the
 * renderer from a field main.js has to actually send. This runs the whole path in
 * a real app — seed a crash on disk, restart, read the toast.
 */
import fs from 'fs';
import path from 'path';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let failed = 0;
const say = (ok, what) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); };

/** Boot once so the app writes a real (encrypted) store, then read its bytes back. */
async function realStoreBytes(clientName) {
  const { electronApp, window } = await launchApp(userData);
  try {
    await dismissWizard(window);
    await window.evaluate(async (name) => {
      clients.length = 0;
      clients.push({ id: 'C-1', name, createdAt: Date.now() });
      await saveAll();
    }, clientName);
    // Give the queued atomic write time to land.
    await window.waitForTimeout(1500);
  } finally { await electronApp.close(); }
  const fp = path.join(userData, 'khayt-store.json');
  return { fp, bytes: fs.readFileSync(fp) };
}

try {
  // A good save from yesterday, in the app's own on-disk format.
  const { fp, bytes: yesterday } = await realStoreBytes('YESTERDAY — the real work');
  // And an older store, standing in for an interrupted write from two months ago.
  fs.rmSync(userData, { recursive: true, force: true });
  const { bytes: july } = await realStoreBytes('JULY — an interrupted write');

  // Now build the crash: a stale orphaned temp, a fresh .prev, an unreadable primary.
  fs.writeFileSync(`${fp}.tmp.999.1`, july);
  const old = Date.now() / 1000 - 60 * 24 * 3600;
  fs.utimesSync(`${fp}.tmp.999.1`, old, old);
  fs.writeFileSync(`${fp}.prev`, yesterday);
  fs.writeFileSync(fp, '{ truncated');

  const { electronApp, window } = await launchApp(userData);
  try {
    const seen = await window.evaluate(async () => {
      const name = (typeof clients !== 'undefined' && clients[0]) ? clients[0].name : null;
      // The toast is scheduled 1.5s after load.
      await new Promise((r) => setTimeout(r, 3000));
      const toasts = [...document.querySelectorAll('.toast, #toastHost > *')].map((n) => ({
        text: (n.textContent || '').trim(),
        cls: n.className,
      }));
      return { name, toasts };
    });

    console.log(`recovered client : ${seen.name}`);
    console.log(`toasts           : ${JSON.stringify(seen.toasts)}`);

    say(seen.name === 'YESTERDAY — the real work',
      `the newest copy was restored (got "${seen.name}")`);

    const all = seen.toasts.map((x) => x.text).join(' | ');
    say(/last save was lost|previous copy/i.test(all),
      'the shop is told the last save was lost');
    say(!/^✓ Recovered your data/.test(all.trim()),
      'a .prev recovery is not dressed up as a plain success');
    say(seen.toasts.some((x) => /error|warn/i.test(x.cls)),
      'the message is not styled as a success');
  } finally { await electronApp.close(); }

  console.log(failed ? `\n${failed} check(s) failed` : '\nrecovery ok — newest copy, and the truth about it');
} catch (e) {
  failed++;
  console.error('\nFAIL', e && e.message);
}
process.exit(failed ? 1 : 0);
