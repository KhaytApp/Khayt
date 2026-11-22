/**
 * E2E smoke — Settings › General › Internet use (P8 PR 5), against the frames
 * Turki signed off (Figma 7Iqw0GcrLLRW7CLDEhTa1P page 111:1041). Sample data
 * only (Sara Example).
 *
 *   A  the shop's switch on: every row from describe(), Blocked / Kept /
 *      Off (its own switch) / Not set up / Always, Keep ticks, consequences
 *   B  the switch off: Allowed, no Keep column
 *   C  updates not checked for 32 days: the red row and the banner, and
 *      "Keep updates" clears it
 *   D  a person-started call refused: the shop's words, "Open Internet use"
 *   +  a non-owner's change to settings.network is put back and said in its
 *      own words (err.refused_network), and this computer's own switch
 *
 * E2E_SHOTS=<dir> saves a screenshot of each state for the PR's comparison.
 * Run: npm run test:e2e:internetuse   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.E2E_SHOTS || '';
const DAY = 24 * 60 * 60 * 1000;

function profile({ offline, keep = ['storage'], lock = false, active = null, lastChecked = null }) {
  const dir = makeUserDataDir();
  const book = {
    settings: {
      firstRun: false, firstRunDone: true, bizName: 'Sample Print Shop', lang: 'en',
      network: offline === undefined ? undefined : { offline, keep, changedAt: '2026-11-21T14:02:00', changedBy: 'Sara Example' },
      telemetry: { crashOptIn: false, usageOptIn: false },
      emailConfig: { provider: 'sendgrid', apiKey: '', fromEmail: 'shop@example.com', fromName: '', domain: '', triggers: [] },
      bnpl: { tabby: { enabled: true, apiKey: '', merchantCode: '', currency: 'SAR' }, tamara: { enabled: false }, stripe: { enabled: false } },
      ai: { enabled: true, model: 'claude-opus-5', apiKey: '' },
      operatorLockEnabled: lock, activeOperatorId: active,
      // What a book the app saved already holds (the window adds these
      // defaults, and under the lock main would put them back too).
      securityEnabled: false, recoveryCodeHash: '',
    },
    operators: [
      { id: 'op-owner', name: 'Sara Example', roleKey: 'owner', active: true },
      { id: 'op-staff', name: 'Sam Sample', roleKey: 'operator', active: true },
    ],
    printLog: [], clients: [], inventory: [], machines: [],
  };
  fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify(book));
  if (lastChecked) fs.writeFileSync(path.join(dir, 'update-check.json'), JSON.stringify({ lastCheckedAt: lastChecked }));
  return dir;
}

async function start(dir) {
  const { electronApp, window } = await launchApp(dir);
  await electronApp.evaluate(({ BrowserWindow }) => { const w = BrowserWindow.getAllWindows()[0]; w.setSize(1440, 1000); });
  await window.evaluate(() => { const w = document.querySelector('#setup-wizard'); if (w) w.style.display = 'none'; });
  return { electronApp, window };
}
const openPage = (window) => window.evaluate(async () => { openSettingsSection('internet'); await window.KhaytInternetUse.refresh(); });
const rowState = (window, p) => window.evaluate((p) => document.querySelector(`[data-iu-row="${p}"] .iu-state`)?.textContent.trim(), p);
const shot = async (window, name, sel = '#mainContent') => {
  if (!shots) return;
  await window.waitForTimeout(700);   // past the panel's fade-in
  if (sel !== '#mainContent') { await window.locator(sel).last().screenshot({ path: path.join(shots, name + '.png') }); return; }
  // The page is taller than the window: the top, then the rest.
  await window.evaluate(() => { document.getElementById('settings-panel-internet').scrollTop = 0; document.getElementById('mainContent').scrollTop = 0; });
  await window.screenshot({ path: path.join(shots, name + '-1.png') });
  await window.evaluate(() => { const p = document.getElementById('settings-panel-internet'); p.scrollTop = p.scrollHeight; const m = document.getElementById('mainContent'); m.scrollTop = m.scrollHeight; });
  await window.waitForTimeout(300);
  await window.screenshot({ path: path.join(shots, name + '-2.png') });
};

let failed = false;
let a;
try {
  // ── A: the shop's switch on ──────────────────────────────────────────────
  a = await start(profile({ offline: true }));
  let w = a.window;
  await openPage(w);
  ok(await w.evaluate(() => document.getElementById('settings-panel-internet').classList.contains('active')), 'General › Internet use opens');
  ok(await w.evaluate(() => document.querySelector('.settings-nav-item.active')?.dataset.settingsSection === 'general'), 'General stays lit in the nav');
  ok(await w.evaluate(() => document.getElementById('iuShopSwitch').getAttribute('aria-checked') === 'true'), 'the shop switch reads on');
  const order = await w.evaluate(() => [...document.querySelectorAll('[data-iu-row]')].map((r) => r.dataset.iuRow));
  ok(JSON.stringify(order) === JSON.stringify(window_order()), `rows in frame A's order (${order.length})`);
  function window_order() { return ['updates', 'install-count', 'crash-reports', 'usage-stats', 'cloud', 'storage', 'messaging', 'webhooks', 'payments', 'storefront', 'ai', 'tax-authority', 'exchange-rates', 'makerrun', 'catalogues', 'tunnel', 'lan']; }
  ok((await rowState(w, 'updates')) === 'Blocked', 'Updates: Blocked');
  ok((await rowState(w, 'crash-reports')) === 'Off (its own switch)', 'Crash reports: Off (its own switch)');
  ok((await rowState(w, 'webhooks')) === 'Not set up', 'Webhooks: Not set up');
  ok((await rowState(w, 'lan')) === 'Always', 'the LAN row: Always, never a Keep tick');
  ok(await w.evaluate(() => !document.querySelector('[data-iu-row="lan"] [data-iu-keep]')), 'no Keep on the LAN row');
  ok(await w.evaluate(() => /No security fixes will arrive/.test(document.querySelector('[data-iu-row="updates"] .iu-cons')?.textContent || '')), 'the Updates consequence line');
  ok(await w.evaluate(() => /Customers get no messages/.test(document.querySelector('[data-iu-row="messaging"] .iu-cons')?.textContent || '')), 'the Messages consequence line');
  ok(await w.evaluate(() => /Turned on by Sara Example/.test(document.getElementById('internetUseBody').textContent)), '"Turned on by Sara Example on … at …"');

  // ── D: a person-started call the switch refuses ──────────────────────────
  await w.evaluate(() => window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' })));
  const r = await w.evaluate(() => window.hubAPI.fetchExchangeRates('SAR'));
  ok(r && r.blocked && r.blocked.purpose === 'exchange-rates', 'the refused reply is unchanged for the caller');
  await w.waitForFunction(() => [...document.querySelectorAll('#toastContainer .toast')].some((t) => /This needs exchange rates/.test(t.textContent)), null, { timeout: 5000 });
  ok(true, 'said: "Khayt is set to make no internet calls. This needs exchange rates."');
  ok(await w.evaluate(() => [...document.querySelectorAll('#toastContainer .toast')].some((t) => /Open Internet use/.test(t.textContent))), 'with "Open Internet use"');
  await shot(w, 'D-refusal-toast', '#toastContainer .toast');
  await w.evaluate(() => window.KhaytInternetUse.refresh());
  ok(await w.evaluate(() => /Blocked 1 time, last at/.test(document.querySelector('[data-iu-row="exchange-rates"] .iu-desc')?.textContent || '')), 'counted on its row: "Blocked 1 time, last at …"');
  // A refusal from an automatic call is never toasted, even right after a
  // click (review of #2633: a save's cloud push landed inside the 8 s window).
  await w.evaluate(() => { document.getElementById('toastContainer').innerHTML = ''; window.dispatchEvent(new KeyboardEvent('keydown', { key: 'a' })); });
  // The refusal arrives exactly as the preload reports a refused cloud push
  // (this profile has no Cloud session, so the push itself answers "locked").
  await w.evaluate(() => window.dispatchEvent(new CustomEvent('khayt:outbound-blocked', { detail: JSON.stringify({ purpose: 'cloud', reason: 'offline', method: 'cloudPush' }) })));
  await w.waitForTimeout(600);
  ok(await w.evaluate(() => ![...document.querySelectorAll('#toastContainer .toast')].some((t) => /Khayt Cloud/.test(t.textContent))), 'a refused cloud push right after a key press is not toasted');
  await w.evaluate(() => window.dispatchEvent(new CustomEvent('khayt:outbound-blocked', { detail: JSON.stringify({ purpose: 'cloud', reason: 'offline', method: 'cloudLogin' }) })));
  await w.waitForFunction(() => [...document.querySelectorAll('#toastContainer .toast')].some((t) => /This needs Khayt Cloud/.test(t.textContent)), null, { timeout: 3000 });
  ok(true, 'the same refusal from a person-started sign-in is said');
  ok((await w.evaluate(() => window.KhaytInternetUse.sayBlocked({ purpose: 'cloud', reason: 'offline' }, 'cloudPush'))) === false, 'cloudPush is not a person-started call');
  // An automatic call (no person a moment before) is counted, never toasted.
  await w.waitForTimeout(8500);
  ok((await w.evaluate(() => window.KhaytInternetUse.sayBlocked({ purpose: 'cloud', reason: 'offline' }))) === false, 'a refusal with no person behind it is not toasted');
  await openPage(w);
  await shot(w, 'A-switch-on');
  if (shots) {
    // The same page in Arabic (right to left), for the comparison only.
    await w.evaluate(async () => { settings.lang = 'ar'; i18n.set('ar'); await window.KhaytInternetUse.refresh(); });
    await shot(w, 'A-switch-on-ar');
    await w.evaluate(async () => { settings.lang = 'en'; i18n.set('en'); await window.KhaytInternetUse.refresh(); });
  }

  // Keep a purpose: saved in the book, and the row reads Kept.
  await w.evaluate(async () => { const box = document.querySelector('[data-iu-keep="exchange-rates"]'); box.checked = true; box.dispatchEvent(new Event('change')); });
  await w.waitForFunction(() => document.querySelector('[data-iu-row="exchange-rates"] .iu-state')?.textContent.trim() === 'Kept', null, { timeout: 5000 });
  ok(await w.evaluate(() => settings.network.keep.includes('exchange-rates')), 'Keep exchange rates: saved, and the row reads Kept');
  const kept = await w.evaluate(() => window.hubAPI.fetchExchangeRates('SAR'));
  ok(!(kept && kept.blocked), 'a kept purpose is no longer refused by main');

  // This computer's own switch.
  await w.click('#iuHereSwitch');
  await w.waitForFunction(() => document.getElementById('iuHereSwitch').getAttribute('aria-checked') === 'true', null, { timeout: 5000 });
  ok(true, '"Also on this computer only" turns on');
  const here = await w.evaluate(() => window.hubAPI.outboundDescribe());
  ok(here.local.offline === true && here.rows.find((x) => x.purpose === 'exchange-rates').reason === 'offline-here', 'and main reads offline-here, over the kept purpose');
  ok((await w.evaluate(() => window.KhaytInternetUse.refusalText({ purpose: 'cloud', reason: 'offline-here' }))) === 'This computer is set to make no internet calls. This needs Khayt Cloud.', 'offline-here in its own words');
  ok((await w.evaluate(() => window.KhaytInternetUse.refusalText({ purpose: 'messaging', reason: 'settings-unknown' }))) === 'Khayt is starting. Try again in a moment.', 'settings-unknown in its own words');
  await w.click('#iuHereSwitch');
  await w.waitForFunction(() => document.getElementById('iuHereSwitch').getAttribute('aria-checked') === 'false', null, { timeout: 5000 });

  // ── B: the shop's switch off, by the switch itself ────────────────────────
  await w.click('#iuShopSwitch');
  await w.waitForFunction(() => document.getElementById('iuShopSwitch').getAttribute('aria-checked') === 'false', null, { timeout: 5000 });
  ok(await w.evaluate(() => settings.network.offline === false && !!settings.network.changedAt), 'turning it off saves offline:false with when');
  ok((await rowState(w, 'updates')) === 'Allowed', 'Updates: Allowed');
  ok(await w.evaluate(() => !document.querySelector('[data-iu-keep]')), 'no Keep column while the switch is off');
  ok(await w.evaluate(() => !document.querySelector('.iu-cons')), 'no consequence lines while nothing is blocked');
  await shot(w, 'B-switch-off');
  await a.electronApp.close(); a = null;

  // ── C: updates blocked, last checked 32 days ago ─────────────────────────
  a = await start(profile({ offline: true, lastChecked: new Date(Date.now() - 32 * DAY).toISOString() }));
  w = a.window;
  await w.evaluate(() => window.KhaytInternetUse.refresh());
  await w.waitForFunction(() => document.getElementById('updatesOffBanner')?.style.display !== 'none', null, { timeout: 5000 });
  ok(await w.evaluate(() => /not checked for updates for 32 days/.test(document.getElementById('updatesOffBanner').textContent)), 'the banner: 32 days, on every screen');
  await openPage(w);
  ok(await w.evaluate(() => document.querySelector('[data-iu-row="updates"]').classList.contains('iu-stale')), 'the Updates row is red');
  ok(await w.evaluate(() => /32 days ago/.test(document.querySelector('[data-iu-row="updates"] .iu-cons').textContent)), '"Last checked: …, 32 days ago."');
  await shot(w, 'C-updates-30-days');
  await w.click('#updatesOffBanner [data-iu-banner="keep"]');
  await w.waitForFunction(() => document.getElementById('updatesOffBanner').style.display === 'none', null, { timeout: 5000 });
  ok(await w.evaluate(() => settings.network.keep.includes('updates')), '"Keep updates" keeps them, and the banner goes');
  await a.electronApp.close(); a = null;

  // ── A non-owner under the staff lock: put back, in its own words ─────────
  a = await start(profile({ offline: true, lock: true, active: 'op-staff' }));
  w = a.window;
  await openPage(w);
  ok(await w.evaluate(() => document.getElementById('iuShopSwitch').disabled), 'the switch is greyed for a non-owner');
  await w.evaluate(async () => { settings.network = Object.assign({}, settings.network, { offline: false }); saveAll(); await flushSave(); });
  await w.waitForFunction(() => [...document.querySelectorAll('#toastContainer .toast')].some((t) => /Internet use/.test(t.textContent)), null, { timeout: 8000 });
  ok(await w.evaluate(() => [...document.querySelectorAll('#toastContainer .toast')].some((t) => /needs the owner: Internet use/.test(t.textContent) && !/the shop lock/.test(t.textContent))), 'refused: "…needs the owner: Internet use (“Make no internet calls”)…", not "the shop lock"');
  const desc = await w.evaluate(() => window.hubAPI.outboundDescribe());
  ok(desc.rows.find((x) => x.purpose === 'updates').reason === 'offline', 'and main still reads the shop as offline');
  const local = await w.evaluate(() => window.hubAPI.outboundSetLocal({ offline: true }));
  ok(local && local.ok === false && local.error === 'not_permitted', "and this computer's own switch is the owner's too");

  console.log('\ne2e-internet-use: ok');
} catch (e) {
  failed = true;
  console.error('\ne2e-internet-use FAILED: ' + (e && e.message || e));
} finally {
  try { if (a) await a.electronApp.close(); } catch (_) { /* gone */ }
}
process.exit(failed ? 1 : 0);
