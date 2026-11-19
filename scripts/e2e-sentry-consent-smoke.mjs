/**
 * E2E — crash reporting sends NOTHING without consent, and never sessions.
 *
 * Sentry was initialised on every packaged launch, consent checked only in
 * beforeSend; its release-health SESSION envelopes bypass beforeSend, so a
 * desktop that never opted in still reached sentry.io on every launch (Mac
 * outbound audit, Nov 19). Here the app is pointed at a LOCAL "Sentry"
 * (SENTRY_DSN, which also switches Sentry on in an unpackaged run) and every
 * request it receives is counted:
 *   1. consent off: launch, an error reported, quit → ZERO requests.
 *   2. consent on (set, then relaunched): the error arrives, and no envelope
 *      carries a session item.
 *
 * Run: npm run test:e2e:sentry   (CI wraps it in xvfb-run)
 */
import http from 'node:http';
import zlib from 'node:zlib';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { _electron as electron } from 'playwright-core';
import { makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const seen = [];
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    let body = Buffer.concat(chunks);
    try { if (/gzip/.test(req.headers['content-encoding'] || '')) body = zlib.gunzipSync(body); } catch (_) { /* keep raw */ }
    seen.push({ url: req.url, body: body.toString('utf8') });
    res.writeHead(200, { 'content-type': 'application/json' }); res.end('{}');
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const DSN = `http://e2epublickey@127.0.0.1:${server.address().port}/1`;

async function launch(userData) {
  const electronApp = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`], cwd: root, timeout: 120_000,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', SENTRY_DSN: DSN },
  });
  const window = await electronApp.firstWindow();
  await window.waitForSelector('.khayt-app', { timeout: 60_000 });
  // The same boot wait as scripts/e2e/helpers.mjs launchApp: the store is loaded.
  await window.waitForFunction(
    () => typeof window.hubAPI?.loadStore === 'function' && typeof window.hubAPI?.saveStore === 'function'
      && (document.querySelector('#dashboardContent')?.innerHTML?.length || 0) > 100,
    { timeout: 60_000 });
  await dismissWizard(window);
  return { electronApp, window };
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const settles = async (until, ms = 15000) => { const end = Date.now() + ms; while (Date.now() < end) { if (until()) return true; await wait(100); } return false; };
const itemTypes = (body) => body.split('\n').map((l) => { try { return JSON.parse(l).type; } catch (_) { return undefined; } }).filter(Boolean);

let failed = false;
const userData = makeUserDataDir();
try {
  // ── 1. Consent off (the default): nothing at all.
  let { electronApp, window } = await launch(userData);
  const def = await window.evaluate(() => (settings.telemetry || {}).crashOptIn);
  ok(def === false || def === undefined, 'crash reports are off by default');
  await window.evaluate(() => window.hubAPI.reportError({ message: 'e2e error, consent off', stack: 'at e2e' }));
  await wait(3000);
  await electronApp.close();
  await wait(2000);
  ok(seen.length === 0, `consent off: launch, an error and quit sent NOTHING (${seen.length} requests)`);

  // ── 2. Opt in, relaunch: the error is sent, a session never is.
  ({ electronApp, window } = await launch(userData));
  await window.evaluate(async () => {
    settings.telemetry = { crashOptIn: true, usageOptIn: false, installId: 'a1b2c3d4e5f6a7b8', consentAt: new Date().toISOString() };
    try { return await flushSave(); } catch (e) { return 'threw: ' + (e && e.message); }
  });
  // On disk before quitting: the next launch reads its consent from the file.
  const storeFile = path.join(userData, 'khayt-store.json');
  ok(await settles(() => fs.readFileSync(storeFile, 'utf8').includes('"crashOptIn":true')), 'the opt-in is saved to the store on disk');
  await electronApp.close();
  ok(seen.length === 0, 'opting in sends nothing until the next launch');
  ({ electronApp, window } = await launch(userData));
  await window.evaluate(() => window.hubAPI.reportError({ message: 'e2e error, consent on', stack: 'at e2e' }));
  ok(await settles(() => seen.some((s) => s.body.includes('e2e error, consent on'))), 'consent on (next launch): the error reaches Sentry');
  await electronApp.close();
  await wait(2000);
  const types = seen.flatMap((s) => itemTypes(s.body));
  ok(!types.includes('session') && !types.includes('sessions'), `no session envelope, even with consent (items: ${[...new Set(types)].join(', ')})`);
} catch (e) {
  failed = true;
  console.error(e && e.stack || e);
} finally {
  server.close();
}
if (failed) { console.error('FAILED'); process.exit(1); }
console.log('sentry consent smoke passed');
