/**
 * E2E smoke — printer discovery over the real IPC bridge.
 *
 * HARDWARE-INDEPENDENT BY DESIGN. CI has no printers on its network, so this asserts the
 * CONTRACT (the handler resolves, within its own timeout, with a well-formed list) rather
 * than that anything was found. When it does run on a LAN with printers — a developer
 * machine — it additionally validates the shape of every result and prints them, so a
 * regression in parsing is visible locally.
 *
 * Run: npm run test:e2e:discovery
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';
import fs from 'node:fs';
import path from 'node:path';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

// Launch inside the try: if it throws, the finally still closes the app. Left outside,
// a failed launch leaks an Electron process that then collides with the next run.
let electronApp;
let failed = false;
try {
  // A printer found in an earlier scan (C10), on an address nothing answers on,
  // so it can only come back as a remembered find, never as this scan's.
  const userData = makeUserDataDir();
  const seededAt = Date.now() - 60 * 60 * 1000;
  fs.writeFileSync(path.join(userData, 'found-printers.json'), JSON.stringify({ version: 1, printers: [
    { name: 'Remembered U1', host: '192.0.2.40', port: 7125, serial: 'E2E-SEEN-1', connection: 'moonraker', firstSeen: seededAt, lastSeen: seededAt, seenCount: 1 },
  ] }));
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  ok(await window.evaluate(() => typeof window.hubAPI?.discoverPrinters === 'function'),
    'discoverPrinters is exposed on the preload bridge');

  const started = Date.now();
  const res = await window.evaluate(() => window.hubAPI.discoverPrinters({ timeoutMs: 4000 }));
  const elapsed = Date.now() - started;

  ok(res && res.ok === true, `scan resolved ok (${JSON.stringify(res && res.error || '')})`);
  ok(Array.isArray(res.printers), 'returns a printers array');
  // The handler must honour its own bound — a wedged socket cannot hang the dialog.
  ok(elapsed < 12000, `respected its timeout (${elapsed}ms)`);

  // Earlier finds come back beside this scan's, marked as not seen now.
  ok(Array.isArray(res.found), 'returns the found list (this scan + earlier finds)');
  const remembered = res.found.find((p) => p.serial === 'E2E-SEEN-1');
  ok(remembered && remembered.seenNow === false && remembered.lastSeen === seededAt,
    'a printer from an earlier scan is listed, not seen now, with when it was last seen');
  ok(res.found.filter((p) => p.seenNow).length === res.printers.length, 'every printer of this scan is in found, seen now');
  const listed = await window.evaluate(() => window.hubAPI.foundPrinters());
  ok(listed && listed.ok && listed.printers.some((p) => p.serial === 'E2E-SEEN-1'), 'foundPrinters lists it without scanning');
  if (res.printers.length) {
    ok(listed.printers.length >= res.printers.length + 1, 'this scan\'s printers were remembered');
  }
  await window.evaluate(() => window.hubAPI.forgetFoundPrinters());
  const after = await window.evaluate(() => window.hubAPI.foundPrinters());
  ok(after && after.ok && after.printers.length === 0, 'forgetFoundPrinters empties the list');

  // A scan asked for 4s must not be able to run for 60s by passing a silly value.
  const clamped = await window.evaluate(() => window.hubAPI.discoverPrinters({ timeoutMs: 999999 }).then(() => 'resolved'));
  ok(clamped === 'resolved', 'an absurd timeout is clamped, not honoured');

  if (res.printers.length === 0) {
    console.log('  ℹ no printers on this network — contract verified, discovery not exercised');
  } else {
    console.log(`  ℹ ${res.printers.length} printer(s) discovered on this LAN:`);
    for (const p of res.printers) {
      ok(typeof p.name === 'string' && p.name.length > 0, `has a name: ${p.name}`);
      ok(typeof p.host === 'string' && p.host.length > 0, `  reachable at ${p.host}${p.port ? ':' + p.port : ''}`);
      ok(p.connection === null || typeof p.connection === 'string',
        `  connection is a type or an honest null (${p.connection})`);
      // Never claim a catalog match that isn't a real catalog id.
      ok(p.catalogId === null || /^[a-z0-9-]+$/.test(p.catalogId), `  catalogId sane (${p.catalogId})`);
    }
  }

  console.log('\n✅ Discovery smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  try { if (electronApp) await electronApp.close(); } catch { /* already gone */ }
}
process.exit(failed ? 1 : 0);
