/**
 * E2E smoke — the cloud storage panel actually renders and is actually wired.
 *
 * The unit tests prove the endpoint builder and the eviction rules; the wiring
 * tests prove the source says the right things. Neither can see whether the
 * provider dropdown is EMPTY on screen, which is what happens if the IPC handler
 * is missing, the preload bridge is not exposed, or renderPrintLibLocation
 * throws before it gets that far. Each of those ships a settings page that looks
 * fine in review and offers the shop no providers at all.
 *
 * So this drives the real app: open Settings, read the dropdown, pick a
 * provider, type an account id, and assert the endpoint appears — the round trip
 * that has to work for any of this to be usable.
 *
 * Run: npm run test:e2e:cloudstorage
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-cloud-'));
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
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 300)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('[console] ' + m.text().slice(0, 300)); });

  await page.waitForSelector('.khayt-app', { timeout: 60_000 });

  // Past the first-run wizard, which otherwise covers the app.
  await page.evaluate(() => {
    const wiz = document.querySelector('#setup-wizard');
    if (wiz) wiz.remove();
    if (typeof settings !== 'undefined' && settings) { settings.firstRun = false; settings.mode = 'professional'; }
  });
  await page.waitForTimeout(500);
  // The print library lives in the "data" settings panel, and only the ACTIVE
  // panel is displayed — reaching the tab alone leaves it hidden. Driven through
  // the real nav item rather than by setting classes, so this exercises the same
  // path a shop does.
  await page.evaluate(() => window.KhaytShell?.switchTab?.('settings-tab'));
  await page.waitForTimeout(600);
  await page.evaluate(() => document.querySelector('.settings-nav-item[data-settings-section="data"]')?.click());
  await page.waitForSelector('#set_plibS3Provider', { state: 'visible', timeout: 30_000 });
  // The panel paints on demand; the section switch does not necessarily reach it.
  await page.evaluate(() => window.KhaytSettings?.renderPrintLibLocation?.());

  // The dropdown is populated over IPC, so an empty one means the chain from
  // main → preload → renderer is broken somewhere.
  await page.waitForFunction(
    () => (document.querySelector('#set_plibS3Provider')?.options?.length || 0) > 5,
    { timeout: 30_000 },
  );
  const providers = await page.$$eval('#set_plibS3Provider option', (os_) => os_.map((o) => o.value));
  ok(providers.length >= 10, `provider list populated (${providers.length} providers)`);
  for (const want of ['r2', 'b2', 'aws', 'gcs', 'minio', 'custom']) {
    ok(providers.includes(want), `${want} is offered`);
  }

  // Picking a provider must rebuild the fields below it. R2 asks for one thing.
  await page.selectOption('#set_plibS3Provider', 'r2');
  await page.waitForFunction(
    () => document.querySelectorAll('#plibS3Vars input[data-var]').length === 1,
    { timeout: 10_000 },
  );
  const varKey = await page.$eval('#plibS3Vars input[data-var]', (el) => el.dataset.var);
  ok(varKey === 'account', 'R2 asks for the account id');

  const note = await page.$eval('#plibS3ProviderNote', (el) => el.textContent || '');
  // Downloads are the thing the choice actually turns on for a print library,
  // so the note has to say something about them before the shop commits.
  ok(/download/i.test(note), `the note covers downloads: "${note}"`);
  ok(/\$/.test(note), 'the note carries a cost hint');
  ok(/checked \d{4}-\d{2}-\d{2}/.test(note), 'the cost hint carries the date it was checked');

  // The signup link is the only control on this page a shop without an account
  // can use, so a hidden or empty one leaves them exactly where they were.
  const signup = await page.$eval('#plibS3Signup', (el) => ({
    hidden: el.style.display === 'none',
    text: el.textContent || '',
    url: el.dataset.url || '',
  }));
  ok(!signup.hidden, 'R2 shows a signup link');
  ok(/cloudflare/i.test(signup.url), `the link points at the provider: ${signup.url}`);
  ok(/Cloudflare R2/.test(signup.text), `the link names the provider: "${signup.text}"`);
  // No referral is configured, so nothing may claim one.
  const refNote = await page.$eval('#plibS3SignupRef', (el) => el.style.display);
  ok(refNote === 'none', 'no referral disclosure when no referral is configured');

  // 'Other' has nothing to sign up for; the link must go rather than sit there
  // pointing at whichever provider happened to be selected last.
  await page.selectOption('#set_plibS3Provider', 'custom');
  await page.waitForFunction(
    () => document.querySelector('#plibS3Signup')?.style.display === 'none',
    { timeout: 10_000 },
  );
  ok(true, '"Other" shows no signup link');
  await page.selectOption('#set_plibS3Provider', 'r2');
  await page.waitForFunction(
    () => document.querySelectorAll('#plibS3Vars input[data-var]').length === 1,
    { timeout: 10_000 },
  );

  // The round trip that matters: type the one thing you know, get an endpoint.
  await page.fill('#set_plibVar_account', 'abc123');
  await page.waitForFunction(
    () => (document.querySelector('#set_plibS3Endpoint')?.value || '').includes('abc123'),
    { timeout: 10_000 },
  );
  const endpoint = await page.$eval('#set_plibS3Endpoint', (el) => el.value);
  ok(endpoint === 'https://abc123.r2.cloudflarestorage.com', `endpoint built: ${endpoint}`);

  // Switching to a provider with no template must leave the box typeable, or a
  // shop on IDrive e2 can never enter their per-account endpoint.
  await page.selectOption('#set_plibS3Provider', 'idrive');
  await page.waitForFunction(
    () => document.querySelector('#set_plibS3Endpoint')?.readOnly === false,
    { timeout: 10_000 },
  );
  ok(true, 'a per-account provider leaves the endpoint editable');

  // The tiering controls exist and the status line answers rather than staying
  // blank — a blank status is what a broken scan handler looks like.
  ok(await page.$('#set_plibTierOn') !== null, 'the tiering switch is on the page');
  ok(await page.$('#btnPlibTierRun') !== null, 'the sweep button is on the page');
  ok(await page.$('#btnPlibTierRestore') !== null, 'the way back out is on the page');
  await page.waitForFunction(
    () => (document.querySelector('#plibTierStatus')?.textContent || '').length > 0,
    { timeout: 30_000 },
  );
  const tierStatus = await page.$eval('#plibTierStatus', (el) => el.textContent);
  // With no bucket configured it must say so, not sit silent or claim readiness.
  ok(/object storage|bucket/i.test(tierStatus), `unconfigured tiering explains itself: "${tierStatus}"`);

  ok(await page.$('#set_plibGDClientId') !== null, 'the Drive fields are on the page');
  const gdStatus = await page.$eval('#plibGDStatus', (el) => el.textContent || '');
  ok(/no google account/i.test(gdStatus), `Drive reports honestly when unconnected: "${gdStatus}"`);

  // Nothing above may have thrown. A settings page that renders while logging a
  // TypeError is a page that is one interaction from breaking.
  ok(errors.length === 0, `no page errors (${errors.length})${errors.length ? ': ' + errors.join(' | ') : ''}`);

  // A library the Mac keeps in the Khayt Vault (Mac #2041): only the Mac can
  // move it, so the bucket and Drive switches are off here, with the reason,
  // and a save cannot turn one on.
  const vault = await page.evaluate(async () => {
    settings.printLibrary = Object.assign({}, settings.printLibrary, {
      vault: { enabled: true }, s3: { ...(settings.printLibrary || {}).s3, enabled: false },
      gdrive: { ...(settings.printLibrary || {}).gdrive, enabled: false } });
    await window.KhaytSettings.renderPrintLibLocation();
    const s3 = document.getElementById('set_plibS3On');
    const gd = document.getElementById('set_plibGDriveOn');
    const note = document.getElementById('plibVaultNote');
    const shown = { s3Off: s3.disabled, gdOff: gd ? gd.disabled : true,
      note: getComputedStyle(note).display !== 'none' ? note.innerText : '' };
    s3.disabled = false; s3.checked = true;           // as if forced on
    await window.KhaytSettings.savePrintLibS3();
    shown.saved = settings.printLibrary.s3.enabled;
    settings.printLibrary.vault = { enabled: false };
    await window.KhaytSettings.renderPrintLibLocation();
    shown.after = { s3Off: document.getElementById('set_plibS3On').disabled,
      note: getComputedStyle(note).display };
    return shown;
  });
  ok(vault.s3Off && vault.gdOff, 'with the library in the Khayt Vault, the bucket and Drive switches are off');
  ok(/Khayt Vault/.test(vault.note) && /Mac/.test(vault.note), `and the panel says why (${vault.note})`);
  ok(vault.saved === false, 'a save cannot switch the bucket on beside the vault');
  ok(!vault.after.s3Off && vault.after.note === 'none', 'with the vault off, the switches come back');

  const shot = path.join(root, 'build', 'cloud-storage-settings.png');
  fs.mkdirSync(path.dirname(shot), { recursive: true });
  await page.locator('#set_plibS3Provider').scrollIntoViewIfNeeded();
  await page.screenshot({ path: shot });
  console.log(`  ✓ screenshot: ${shot}`);

  console.log('\n✅ Cloud-storage smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + (e && e.message ? e.message : e));
} finally {
  try { if (app) await app.close(); } catch (_) { /* already gone */ }
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) { /* leave it */ }
  process.exit(failed ? 1 : 0);
}
