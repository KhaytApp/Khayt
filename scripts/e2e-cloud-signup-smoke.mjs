/**
 * E2E smoke — a shop can actually get from "Create account" to typing the code.
 *
 * Everything in this flow was individually correct and the flow did not work.
 * Twice.
 *
 *   First: sign-up ended on a success toast and a warning banner, so the code
 *   arrived and there was visibly nowhere to type it. Reported as "I got an
 *   email with a code but nowhere to enter it." A modal was added.
 *
 *   Then: that modal could never open, because two lines earlier the handler
 *   died on a ReferenceError — syncScopeToShop was private to app-state.js's
 *   IIFE. Nothing was logged where a shop could see it; the panel simply sat on
 *   "Connecting…". Reported as "trying to log onto the cloud and stuck at
 *   connecting". The fix for the FIRST bug shipped a whole release without ever
 *   having run.
 *
 * Source-level tests pin both — that the modal is called, that the function is
 * exported. Neither can see that the click reaches the modal, which is the only
 * thing the shop cares about. So this drives the real app against a stand-in
 * server and asserts the two dialogs appear in order.
 *
 * The server is local because the real one refuses example.com to its mail
 * provider and returns emailFailed, which correctly SKIPS the code modal — so
 * the live server cannot exercise the path a shop with a working address takes.
 * Loopback http is allowed by validateCloudBaseUrl by design.
 *
 * Run: npm run test:e2e:cloudsignup
 */
import { _electron as electron } from 'playwright-core';
import http from 'http';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const json = (o) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
    if (req.url === '/v1/health') return json({ ok: true, service: 'khayt-cloud', version: 1 });
    // emailFailed:false is the whole point — it is the branch the live server
    // cannot produce for a test address, and the only one that opens the modal.
    if (req.url === '/v1/signup') {
      return json({ accountId: 'acct_smoke', shopId: 'shop_smoke', token: 'tok_smoke',
        emailConfigured: true, emailFailed: false });
    }
    return json({ ok: true, rev: 1 });
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}`;

const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-signup-'));
let app;
let failed = false;
try {
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_USER_DATA: userData },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('pageerror', (e) => errors.push('[pageerror] ' + String(e).slice(0, 300)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('[console] ' + m.text().slice(0, 300)); });

  await page.waitForSelector('.khayt-app', { timeout: 60_000 });
  await page.evaluate(() => {
    document.querySelector('#setup-wizard')?.remove();
    if (typeof settings !== 'undefined' && settings) { settings.firstRun = false; settings.mode = 'professional'; }
  });
  // Before anything else: a handler that dies must SAY SO. This is the property
  // whose absence let both bugs above run in the field — the renderer already
  // forwarded unhandled rejections to Sentry, which is off in a normal build, so
  // in a shop's hands the error went nowhere and the UI just stopped.
  await page.waitForFunction(
    () => window.__khaytErrorHandlersInstalled === true && typeof window.toast === 'function',
    { timeout: 30_000 });
  await page.evaluate(() => { Promise.resolve().then(() => { window.__no_such_object__.x(); }); });
  // Read the live region's textContent, not body.innerText: the toast container
  // is off-flow in some layouts and innerText omits it, which would make this
  // check depend on the mode the app happens to boot in.
  const told = await page.waitForFunction(
    () => /stopped partway/.test(document.querySelector('#toastContainer')?.textContent || ''),
    { timeout: 15_000 },
  ).then(() => true).catch(() => false);
  ok(told, 'a handler that dies mid-flight tells the shop instead of freezing');
  errors.length = 0;  // that rejection was ours

  await page.evaluate(() => window.KhaytShell?.switchTab?.('settings-tab'));
  await page.waitForTimeout(600);
  await page.evaluate(() => document.querySelector('.settings-nav-item[data-settings-section="cloud"]')?.click());
  await page.waitForTimeout(400);
  await page.evaluate(() => window.KhaytSettings?.renderCloudSettings?.());
  // Present, not visible: only the active settings section is displayed, and
  // the section switch above does not always paint this one. The flow under
  // test is the handler, not the CSS, so wait for the button to exist.
  await page.waitForFunction(() => !!document.querySelector('#btnCloudSignup'), { timeout: 30_000 });

  await page.evaluate((u) => {
    const set = (id, v) => { const e = document.querySelector(id); e.value = v; e.dispatchEvent(new Event('input', { bubbles: true })); };
    set('#cloudUrl', u);
    set('#cloudEmail', 'shop@example.com');
    set('#cloudAcctPass', 'a-real-enough-password');
    set('#cloudPass', 'sync-passphrase-123');
  }, url);
  await page.evaluate(() => document.querySelector('#btnCloudSignup').click());

  // 1. The recovery key, which is shown once and has to be acknowledged before
  //    anything else — losing it loses the data.
  await page.waitForFunction(
    () => /recovery/i.test(document.querySelector('.modal')?.textContent || ''),
    { timeout: 30_000 },
  ).catch(() => {
    const shown = 'the recovery-key modal never opened — the handler died before it';
    throw new Error('ASSERT FAILED: ' + shown);
  });
  ok(true, 'the recovery-key modal opens');

  // The panel must not still be mid-flight behind it. "Connecting…" here is the
  // exact symptom of a handler that threw between login and the modal.
  const stillConnecting = await page.evaluate(
    () => /connecting/i.test(document.querySelector('#cloudResult')?.textContent || ''));
  ok(!stillConnecting, 'the panel is not stuck on "Connecting…"');

  await page.evaluate(() => document.querySelector('.modal [data-act="save"]')?.click());
  await page.waitForTimeout(1000);

  // 2. The code dialog, at the moment the shop is holding the email.
  const modal = await page.evaluate(() => {
    const el = document.querySelector('.modal');
    if (!el) return null;
    return {
      title: el.querySelector('#modalTitle')?.textContent || '',
      hasInput: !!el.querySelector('input'),
      offersResend: /resend|again/i.test(el.textContent || ''),
      namesTheAddress: /shop@example\.com/.test(el.textContent || ''),
    };
  });
  ok(modal, 'the verification-code modal opens after the recovery key');
  ok(modal.hasInput, `it has somewhere to type the code ("${modal.title}")`);
  ok(modal.namesTheAddress, 'it names the address the code went to');
  ok(modal.offersResend, 'it offers a resend for a code that never arrives');

  ok(errors.length === 0, `no renderer errors${errors.length ? ':\n    ' + errors.join('\n    ') : ''}`);
  console.log('\n✅ cloud sign-up reaches the code entry.');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + (e && e.message ? e.message : e));
} finally {
  if (app) await app.close().catch(() => {});
  server.close();
  fs.rmSync(userData, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
