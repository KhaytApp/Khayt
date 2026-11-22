#!/usr/bin/env node
/**
 * A backup must accept any store the app is willing to save.
 *
 * `hub:write-backup` refused anything over 20 MB while `hub:save-store` accepts
 * 50 MB. A shop in between went on saving normally and silently stopped being
 * backed up — and the same gate sat on the iCloud copy, on restore points, and
 * on the pre-update snapshot, so every net switched off at once, at exactly the
 * size where a shop has the most to lose.
 *
 * The unit test drives the renderer's reporting with a stub. This drives the
 * real IPC in a real app: a 30 MB payload used to come back refused.
 */
import fs from 'fs';
import path from 'path';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;
let failed = 0;
const say = (ok, what) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`); };

try {
  let window;
  ({ electronApp, window } = await launchApp(userData));
  await dismissWizard(window);

  // ~30 MB of JSON: over the old 20 MB backup gate, under the 50 MB store ceiling.
  const r = await window.evaluate(async () => {
    const big = { schemaVersion: 1, note: 'x'.repeat(30 * 1000 * 1000) };
    const json = JSON.stringify(big);
    const res = await window.hubAPI.writeBackup(json);
    return { bytes: json.length, res };
  });

  console.log(`payload ${(r.bytes / 1e6).toFixed(1)} MB → ${JSON.stringify(r.res).slice(0, 120)}`);
  say(r.bytes > 20e6 && r.bytes < 50e6, 'the payload sits between the two old ceilings');
  say(r.res && r.res.ok !== false, 'a 30 MB store was accepted for backup');

  // And it is really on disk, not merely reported.
  const day = new Date().toISOString().split('T')[0];
  const dir = path.join(userData, 'backups');
  const onDisk = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.startsWith(day)) : [];
  const size = onDisk.length ? fs.statSync(path.join(dir, onDisk[0])).size : 0;
  say(onDisk.length > 0, `a backup file was written (${onDisk.join(',') || 'none'})`);
  say(size > 20e6, `the file holds the whole store (${(size / 1e6).toFixed(1)} MB)`);

  console.log(failed ? `\n${failed} check(s) failed` : '\nbackup size ok — the net covers every store that can be saved');
} finally {
  if (electronApp) await electronApp.close();
}
process.exit(failed ? 1 : 0);
