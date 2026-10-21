/**
 * E2E smoke — the anonymous active-install count, from a real app.
 *
 * The sender is pointed at a loopback server (KHAYT_ACTIVE_COUNT_E2E, honoured
 * for 127.0.0.1 only). It must POST exactly the six fields the privacy page
 * names, once a UTC day; a 503 counts nothing and is tried again; the Settings
 * switch turns it off without forgetting the dates.
 *
 * Run: npm run test:e2e:activecount
 */
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const FIELDS = ['channel', 'firstEver', 'firstThisMonth', 'firstThisWeek', 'platform', 'version'];

const posts = [];
let reply = 200;
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    posts.push({ url: req.url, method: req.method, headers: req.headers, body: JSON.parse(body || 'null') });
    res.writeHead(reply, { 'content-type': 'application/json' });
    res.end(JSON.stringify(reply === 200 ? { ok: true, counted: true } : { ok: false }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
process.env.KHAYT_ACTIVE_COUNT_E2E = `http://127.0.0.1:${server.address().port}/v1/active`;
const waitFor = async (fn, ms = 10000) => { const end = Date.now() + ms; while (Date.now() < end) { if (fn()) return true; await new Promise((r) => setTimeout(r, 100)); } return false; };

let failed = false;
let app;
try {
  // ---- A cloud that is down: nothing counted, nothing remembered ----
  reply = 503;
  const dirDown = makeUserDataDir();
  app = await launchApp(dirDown);
  ok(await waitFor(() => posts.length === 1), 'it sends on launch');
  const fileDown = path.join(await app.electronApp.evaluate(({ app: a }) => a.getPath('userData')), 'active-count.json');
  await new Promise((r) => setTimeout(r, 500));
  const down = fs.existsSync(fileDown) ? JSON.parse(fs.readFileSync(fileDown, 'utf8')) : {};
  ok(!down.lastCounted && !down.doneDay, 'a 503 is not counted, so it is tried again');
  await app.electronApp.close();
  posts.length = 0;

  // ---- Counted ----
  reply = 200;
  app = await launchApp(makeUserDataDir());
  const { electronApp, window } = app;
  ok(await waitFor(() => posts.length === 1), 'it sends on launch');
  const p = posts[0];
  ok(p.method === 'POST' && p.url === '/v1/active', 'POST /v1/active');
  ok(JSON.stringify(Object.keys(p.body).sort()) === JSON.stringify(FIELDS), `exactly the six fields (${Object.keys(p.body).join(', ')})`);
  const version = await electronApp.evaluate(({ app: a }) => a.getVersion());
  ok(p.body.version === version && ['win', 'mac', 'linux'].includes(p.body.platform) && ['stable', 'beta', 'alpha'].includes(p.body.channel), `platform, channel and version of this build (${p.body.platform} ${p.body.channel} ${p.body.version})`);
  ok(p.body.firstEver === true && p.body.firstThisWeek === true && p.body.firstThisMonth === true, 'a new install is first ever, this week and this month');
  ok(!/install|shop|khayt-/i.test(Object.keys(p.headers).join(' ')), 'no id in the headers either');

  const file = path.join(await electronApp.evaluate(({ app: a }) => a.getPath('userData')), 'active-count.json');
  const today = new Date().toISOString().slice(0, 10);
  await waitFor(() => fs.existsSync(file));
  const st = JSON.parse(fs.readFileSync(file, 'utf8'));
  ok(st.lastCounted === today && st.doneDay === today && st.off === false, 'the counted day is kept on this computer');

  // ---- The switch ----
  await dismissWizard(window);
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="payments"]');
  await window.evaluate(() => renderTelemetrySettings());
  await window.waitForSelector('#tel_active');
  ok(await window.evaluate(() => document.getElementById('tel_active').checked), 'Settings shows the count on by default');
  ok(await window.evaluate(() => /Apart from an anonymous once-a-day install count/.test(document.getElementById('telHint').textContent)), 'and no longer says nothing is sent by default');
  await window.uncheck('#tel_active');
  await waitFor(() => JSON.parse(fs.readFileSync(file, 'utf8')).off === true, 3000);
  const offState = JSON.parse(fs.readFileSync(file, 'utf8'));
  ok(offState.off === true && offState.lastCounted === today, 'off is saved, and the dates are kept');
  await window.check('#tel_active');
  await new Promise((r) => setTimeout(r, 800));
  ok(posts.length === 1, 'back on the same day sends nothing more (once a UTC day)');
  ok(!(await window.evaluate(() => JSON.stringify(settings))).includes('lastCounted'), 'none of it is in the shop\'s book');

  console.log('e2e-active-count: ok (six fields, once a day, 503 retried, switch keeps the dates, not in the book)');
} catch (err) {
  failed = true;
  console.error('e2e-active-count FAILED:', err && err.message);
} finally {
  try { await app?.electronApp.close(); } catch (_) {}
  server.close();
  process.exit(failed ? 1 : 0);
}
