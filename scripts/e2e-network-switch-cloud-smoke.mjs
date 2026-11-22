/**
 * E2E smoke — the shop's switch through Khayt Cloud on Settings › General ›
 * Internet use, against the frames Turki signed off on Nov 22 (Figma
 * 7Iqw0GcrLLRW7CLDEhTa1P: F1 117:1186, F2 117:1651, F3 117:2116, G 117:2546).
 * Sample data only (Sara Example).
 *
 *   F1  switch on, option off: "Your other computers have not been told"
 *   F2  switch on through Khayt Cloud: "were told through Khayt Cloud at …"
 *   F3  switch off: unchanged
 *       "Also tell my other computers through Khayt Cloud": off by default,
 *       greyed until Khayt Cloud is unlocked here, and owner-only to turn on
 *   G   the 7-day question; the 409 in its two variants ("Keep it on this
 *       computer only" ONLY when the person was turning the switch on); the
 *       clock that may be behind; an answer main refuses is said in words
 *
 * There is no Khayt Cloud in CI, so the G states are main's state() shapes
 * drawn through the page's own render; every button still goes to main, which
 * answers "locked" here and is said as such. Main's own rules are
 * test/network-switch.test.js.
 *
 * E2E_SHOTS=<dir> saves a screenshot of each state.
 * Run: npm run test:e2e:netswitchcloud   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.E2E_SHOTS || '';

function profile({ offline, via = null, lock = false, active = null }) {
  const dir = makeUserDataDir();
  const book = {
    settings: {
      firstRun: false, firstRunDone: true, bizName: 'Sample Print Shop', lang: 'en',
      network: { offline, keep: ['storage'], changedAt: new Date(Date.now() - 60000).toISOString(), changedBy: 'Sara Example', ...(via ? { via } : {}) },
      telemetry: { crashOptIn: false, usageOptIn: false },
      operatorLockEnabled: lock, activeOperatorId: active, securityEnabled: false, recoveryCodeHash: '',
    },
    operators: [
      { id: 'op-owner', name: 'Sara Example', roleKey: 'owner', active: true },
      { id: 'op-staff', name: 'Sam Sample', roleKey: 'operator', active: true },
    ],
    printLog: [], clients: [], inventory: [], machines: [],
  };
  fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify(book));
  return dir;
}

async function start(dir) {
  const { electronApp, window } = await launchApp(dir);
  await electronApp.evaluate(({ BrowserWindow }) => { const w = BrowserWindow.getAllWindows()[0]; w.setSize(1440, 1000); });
  await window.evaluate(() => { const w = document.querySelector('#setup-wizard'); if (w) w.style.display = 'none'; });
  await window.evaluate(async () => { openSettingsSection('internet'); await window.KhaytInternetUse.refresh(); });
  return { electronApp, window };
}
const text = (w) => w.evaluate(() => document.getElementById('internetUseBody').textContent.replace(/\s+/g, ' '));
/** Draw the page with main's state() replaced by `ns` (no Khayt Cloud in CI). */
const drawWith = (w, ns) => w.evaluate(async (ns) => {
  const ctx = await window.KhaytInternetUse.load();
  window.KhaytInternetUse.render(Object.assign({}, ctx, { ns }));
}, ns);
const shot = async (w, name) => {
  if (!shots) return;
  fs.mkdirSync(shots, { recursive: true });
  await w.locator('#internetUseBody').screenshot({ path: path.join(shots, name + '.png') });
};
const buttons = (w, card) => w.evaluate((card) => [...document.querySelectorAll(`[data-iu-g-card="${card}"] [data-iu-g]`)].map((b) => b.textContent.trim()), card);

const AT = '2026-11-22T14:05:00.000Z', MINE = '2026-11-22T14:02:00.000Z';
let a = null;
let failed = false;
try {
  // ── F1: on, the option off, Khayt Cloud not unlocked here ────────────────
  a = await start(profile({ offline: true }));
  let w = a.window;
  ok(await w.evaluate(() => !!document.querySelector('[data-iu-share-row]')), 'the row "Also tell my other computers through Khayt Cloud" is there');
  ok(await w.evaluate(() => document.getElementById('iuShareLabel').textContent.trim() === 'Also tell my other computers through Khayt Cloud'), 'its label, as in F1');
  ok(await w.evaluate(() => document.getElementById('iuShareSwitch').getAttribute('aria-checked') === 'false'), 'off by default');
  ok(await w.evaluate(() => document.getElementById('iuShareSwitch').disabled), 'greyed while Khayt Cloud is not unlocked here');
  const f1 = await text(w);
  ok(/Off: nothing is sent, and your other computers do not learn of the switch/.test(f1), 'F1 option line: "Off: nothing is sent…"');
  ok(/Unlock Khayt Cloud on this computer to change this/.test(f1), 'and why it is greyed');
  ok(/Turned on by Sara Example on .* This computer has stopped\. Your other computers have not been told: turn it on there too\./.test(f1), 'F1 switch line: "…This computer has stopped. Your other computers have not been told…"');
  ok(await w.evaluate(() => !document.querySelector('[data-iu-g-card]')), 'no G message without a question from Khayt Cloud');
  await shot(w, 'F1');

  // The row when Khayt Cloud is unlocked: on (F2 words), and owner-only to turn on.
  await drawWith(w, { unlocked: true, share: true, owner: true, pending: null, conflict: null, clockBehind: false });
  ok(await w.evaluate(() => document.getElementById('iuShareSwitch').getAttribute('aria-checked') === 'true' && !document.getElementById('iuShareSwitch').disabled), 'unlocked, the option on: on and changeable');
  ok(/sends that one setting, sealed, to Khayt Cloud/.test(await text(w)), 'F2 option line: "…sends that one setting, sealed, to Khayt Cloud…"');
  await drawWith(w, { unlocked: true, share: false, owner: false, pending: null, conflict: null, clockBehind: false });
  ok(await w.evaluate(() => document.getElementById('iuShareSwitch').disabled), 'not the cloud owner: cannot turn it on');
  ok(/Only the shop’s owner on Khayt Cloud can turn this on/.test(await text(w)), 'and says so');

  // ── G: the 7-day question ────────────────────────────────────────────────
  await drawWith(w, { unlocked: true, share: false, owner: true, conflict: null, clockBehind: false,
    pending: { offline: true, changedAt: '2026-11-10T09:00:00.000Z', changedBy: 'Sara Example' } });
  const ask = await text(w);
  ok(/Your shop turned off internet use on (10 Nov 2026|Nov 10, 2026) \(Sara Example, at another computer\)\. Apply it here\?/.test(ask), 'G: "Your shop turned off internet use on <date> (Sara Example, at another computer). Apply it here?"');
  ok(/The 7-day rule/.test(ask), 'with the 7-day rule');
  ok(JSON.stringify(await buttons(w, 'ask')) === JSON.stringify(['Apply it here', 'Not now']), 'buttons: Apply it here, Not now');
  await shot(w, 'G-ask');

  // ── G: the 409, turning ON here: both answers ─────────────────────────────
  await drawWith(w, { unlocked: true, share: true, owner: true, pending: null, clockBehind: false, conflict: { at: AT, mine: MINE, offline: true, held: true } });
  ok(await w.evaluate(() => /The switch was changed at another computer at .*, after your change here at .*\. Khayt Cloud keeps the newer one\./.test(document.querySelector('[data-iu-g-card="conflict-on"]').textContent)), 'G 409: "The switch was changed at another computer at …, after your change here at …"');
  ok(JSON.stringify(await buttons(w, 'conflict-on')) === JSON.stringify(['Use the newer setting', 'Keep it on this computer only']), 'turning it ON here: "Use the newer setting" and "Keep it on this computer only"');
  await shot(w, 'G-409-on');

  // ── G: the 409, turning OFF here: only the newer setting ──────────────────
  await drawWith(w, { unlocked: true, share: true, owner: true, pending: null, clockBehind: false, conflict: { at: AT, mine: MINE, offline: false, held: false } });
  ok(JSON.stringify(await buttons(w, 'conflict-off')) === JSON.stringify(['Use the newer setting']), 'turning it OFF here: only "Use the newer setting" (stricter-only, Turki Nov 22)');
  ok(/never looser/.test(await text(w)), 'and says why there is nothing to keep');
  await shot(w, 'G-409-off');
  // Main refuses "keep" after turning it off whatever the window sends.
  const looser = await w.evaluate(() => window.hubAPI.networkSwitchConflict('keep'));
  ok(looser && looser.ok === false, 'main answers a forged "keep" without a conflict or a session with a refusal');

  // ── G: the clock ─────────────────────────────────────────────────────────
  await drawWith(w, { unlocked: true, share: true, owner: true, pending: null, conflict: null, clockBehind: true });
  ok(/This computer’s clock may be behind: check its date and time\./.test(await text(w)), 'G: "…This computer’s clock may be behind: check its date and time."');
  await shot(w, 'G-clock');

  // A button goes to main; main says why it did not (Khayt Cloud locked here).
  await drawWith(w, { unlocked: true, share: true, owner: true, pending: null, clockBehind: false, conflict: { at: AT, mine: MINE, offline: true, held: true } });
  await w.click('[data-iu-g="keep"]');
  await w.waitForFunction(() => [...document.querySelectorAll('#toastContainer .toast')].some((t) => /Unlock Khayt Cloud on this computer/.test(t.textContent)), null, { timeout: 8000 });
  ok(true, 'the answer went to main, which said "locked": "Unlock Khayt Cloud on this computer to change this."');
  ok(await w.evaluate(() => !document.querySelector('[data-iu-g-card]')), 'and the page is drawn again from main\'s own state');

  // ── Arabic: the same states in the shop's language ───────────────────────
  await w.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); });
  await drawWith(w, { unlocked: true, share: false, owner: true, pending: null, clockBehind: false, conflict: { at: AT, mine: MINE, offline: true, held: true } });
  ok(JSON.stringify(await buttons(w, 'conflict-on')) === JSON.stringify(['استخدام الإعداد الأحدث', 'إبقاؤه على هذا الحاسوب فقط']), 'Arabic: both answers');
  ok(/إبلاغ حواسيبي الأخرى أيضًا عبر سحابة خيط/.test(await text(w)), 'Arabic: the option row');
  await shot(w, 'G-409-on-ar');
  await w.evaluate(() => { settings.lang = 'en'; i18n.set('en'); });
  await a.electronApp.close(); a = null;

  // ── F2: the switch came through Khayt Cloud ──────────────────────────────
  a = await start(profile({ offline: true, via: 'cloud' }));
  w = a.window;
  ok(/For the whole shop\. Turned on by Sara Example on .* This computer has stopped\. Your other computers were told through Khayt Cloud at .* and stop at their next check, within 15 minutes\./.test(await text(w)), 'F2 switch line: "…were told through Khayt Cloud at … within 15 minutes."');
  await shot(w, 'F2');
  await a.electronApp.close(); a = null;

  // ── F3: off ──────────────────────────────────────────────────────────────
  a = await start(profile({ offline: false }));
  w = a.window;
  ok(/For the whole shop: every computer and the phone follow it\. Off: Khayt makes the calls below as you have set them up\./.test(await text(w)), 'F3 switch line unchanged');
  ok(await w.evaluate(() => !!document.querySelector('[data-iu-share-row]')), 'the option row is there with the switch off too');
  await shot(w, 'F3');
  await a.electronApp.close(); a = null;

  // ── A non-owner under the staff lock: every control greyed ───────────────
  a = await start(profile({ offline: true, lock: true, active: 'op-staff' }));
  w = a.window;
  await drawWith(w, { unlocked: true, share: true, owner: true, pending: { offline: true, changedAt: '2026-11-10T09:00:00.000Z', changedBy: '' }, clockBehind: false, conflict: { at: AT, mine: MINE, offline: true, held: true } });
  ok(await w.evaluate(() => document.getElementById('iuShareSwitch').disabled && [...document.querySelectorAll('[data-iu-g]')].every((b) => b.disabled)), 'a non-owner: the option and every answer greyed');
  ok(/Your shop turned off internet use on (10 Nov 2026|Nov 10, 2026), at another computer\. Apply it here\?/.test(await text(w)), 'no name given: "…on <date>, at another computer."');
  const share = await w.evaluate(() => window.hubAPI.networkSwitchShare(true));
  ok(share && share.ok === false && share.why === 'not_permitted', 'and main refuses the option for a non-owner');

  console.log('\ne2e-network-switch-cloud: ok');
} catch (e) {
  failed = true;
  console.error('\ne2e-network-switch-cloud FAILED: ' + (e && e.message || e));
} finally {
  try { if (a) await a.electronApp.close(); } catch (_) { /* gone */ }
}
process.exit(failed ? 1 : 0);
