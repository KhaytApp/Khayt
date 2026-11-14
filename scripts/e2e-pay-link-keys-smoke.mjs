/**
 * E2E: Settings › Online Store › Pay links, v2 keys (Figma 94:543 / 94:778 /
 * 94:1013), with real clicks.
 *
 *   1. Switched off (the default): the v1 card is unchanged, no v2 rows.
 *   2. With main answering `enabled` (its hub:qlk-* handlers replaced by a
 *      scripted fake in main; never the real Khayt Cloud):
 *        - no key: "Set up this computer" sets one up;
 *        - waiting: the request row and Cancel request;
 *        - current, another computer asking: Approve… (with the confirm) clears it;
 *        - Revoke another key: confirm, then the emailed-code row, then revoked.
 *      The v1 secret rows are hidden and the intro changes.
 *
 * Run: npm run test:e2e:paylinkkeys
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const KID_ME = 'MEkidMEkidMEkidMEkidMEkidMEkidMEkidMEkid0001';
const KID_MAC = 'MACkidMACkidMACkidMACkidMACkidMACkidMACkid02';
const KID_NEW = 'NEWkidNEWkidNEWkidNEWkidNEWkidNEWkidNEWkid3Lm2Q';

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
const openCard = async () => {
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="general"]');
  await window.click('.settings-nav-item[data-settings-section="store"]');
  await window.waitForSelector('#quotePayLinkSection #qpl_storeUrl', { state: 'visible', timeout: 10_000 });
};
const confirmOk = async () => {
  await window.waitForSelector('.modal [data-act="ok"]', { state: 'visible', timeout: 5_000 });
  await window.click('.modal [data-act="ok"]');
};
const shot = async (name) => { if (process.env.E2E_SHOTS) await window.locator('#quotePayLinkSection').screenshot({ path: `${process.env.E2E_SHOTS}/${name}.png` }); };
const v2Text = () => window.evaluate(() => document.getElementById('qpl_v2')?.innerText || '');

try {
  await dismissWizard(window);
  await window.evaluate(() => { settings.mode = 'professional'; settings.cloud = { ...(settings.cloud || {}), role: 'owner' }; KhaytShell.applyMode(); });

  // ── 1. Off ───────────────────────────────────────────────────────────────
  await openCard();
  await window.waitForTimeout(300);
  ok(await window.isVisible('#quotePayLinkSection [data-qpl-set="replace"]'), 'off: the v1 secret row is there');
  ok(await window.evaluate(() => document.getElementById('qpl_v2').hidden), 'off: no v2 keys area');

  // ── 2. On, against a scripted fake in main ──────────────────────────────
  await electronApp.evaluate(({ ipcMain }, ids) => {
    const st = { phase: 'none', pending: [{ kid: ids.NEW, short: 'NEWk…Lm2Q', device: 'Workshop PC', requested: '2026-11-14T10:42:00Z' }], revoked: [] };
    globalThis.__qlk = st;
    const key = (kid, mine, created) => ({ kid, short: kid.slice(0, 4) + '…' + kid.slice(-4), status: 'current', created, device: mine ? '' : 'Mac Studio', mine });
    const status = () => {
      const base = { ok: true, enabled: true, cloud: true };
      const mac = st.revoked.includes(ids.MAC) ? [] : [key(ids.MAC, false, '2026-11-01T08:00:00Z')];
      if (st.phase === 'none') return { ...base, state: 'none', mine: null, keys: mac, pending: [] };
      if (st.phase === 'pending') return { ...base, state: 'pending', mine: { kid: ids.ME, short: 'MEki…0001', requestedAt: '2026-11-14T10:42:00Z' }, keys: mac, pending: [] };
      return { ...base, state: 'current', mine: { kid: ids.ME, short: 'MEki…0001' }, keys: [key(ids.ME, true, '2026-11-14T08:00:00Z'), ...mac], pending: st.pending };
    };
    const set = (name, fn) => { ipcMain.removeHandler(name); ipcMain.handle(name, (_e, a) => fn(a || {})); };
    set('hub:qlk-status', () => status());
    set('hub:qlk-setup', () => { st.phase = st.wantPending ? 'pending' : 'current'; return { ok: true, state: st.phase }; });
    set('hub:qlk-cancel', () => { st.phase = 'none'; return { ok: true }; });
    set('hub:qlk-approve', ({ kid }) => { st.approved = kid; st.pending = []; return { ok: true }; });
    set('hub:qlk-decline', () => { st.pending = []; return { ok: true }; });
    set('hub:qlk-rotate', () => ({ ok: true }));
    set('hub:qlk-revoke', ({ kid, code }) => { if (!code) return { ok: true, codeSent: true }; st.codeUsed = code; st.revoked.push(kid); return { ok: true }; });
  }, { ME: KID_ME, MAC: KID_MAC, NEW: KID_NEW });

  // No key yet.
  await openCard();
  await window.waitForSelector('#qpl_v2 [data-qpl-v2="setup"]', { state: 'visible', timeout: 5_000 });
  ok(!(await window.isVisible('#quotePayLinkSection [data-qpl-set="replace"]')), 'on: the v1 secret row is hidden');
  ok(/own key/.test(await window.evaluate(() => document.getElementById('qpl_intro').textContent)), 'on: the intro says each computer signs with its own key');

  // Waiting for approval (94:778).
  await electronApp.evaluate(() => { globalThis.__qlk.wantPending = true; });
  await window.click('#qpl_v2 [data-qpl-v2="setup"]');
  await window.waitForSelector('#qpl_v2 [data-qpl-v2="cancel"]', { state: 'visible', timeout: 5_000 });
  await shot('v2-waiting');
  ok(/Waiting for approval/.test(await v2Text()), 'set up on a shop that has keys: waiting for approval, with Cancel request');
  ok(/0001/.test(await v2Text()), 'the waiting hint names the end of this computer\'s key');
  await window.click('#qpl_v2 [data-qpl-v2="cancel"]');
  await window.waitForSelector('#qpl_v2 [data-qpl-v2="setup"]', { state: 'visible', timeout: 5_000 });
  ok(true, 'Cancel request goes back to no key');

  // This computer signs; another asks (94:1013 + 94:543).
  await electronApp.evaluate(() => { globalThis.__qlk.wantPending = false; });
  await window.click('#qpl_v2 [data-qpl-v2="setup"]');
  await window.waitForSelector('#qpl_v2 [data-qpl-v2="approve"]', { state: 'visible', timeout: 5_000 });
  await shot('v2-current-asking');
  const signing = await v2Text();
  ok(/This computer · current/.test(signing) && /Mac Studio/.test(signing), 'current: this computer and Mac Studio are listed');
  ok(/Workshop PC/.test(signing) && /Lm2Q/.test(signing), 'the asking computer is shown with the end of its key');
  ok(await window.isVisible('#qpl_v2 [data-qpl-v2="rotate"]'), 'Rotate… is offered on this computer\'s key');
  await window.click('#qpl_v2 [data-qpl-v2="approve"]');
  await confirmOk();
  await window.waitForFunction(() => !document.querySelector('#qpl_v2 [data-qpl-v2="approve"]'), null, { timeout: 5_000 });
  ok(await electronApp.evaluate(() => globalThis.__qlk.approved) === KID_NEW, 'Approve… (after the confirm) approves that computer\'s key');

  // Revoke Mac Studio's key: confirm, then the emailed code.
  await window.click(`#qpl_v2 [data-qpl-v2="revoke"][data-kid="${KID_MAC}"]`);
  await confirmOk();
  await window.waitForSelector('#qpl_v2Code', { state: 'visible', timeout: 5_000 });
  ok(true, 'after the confirm, the emailed-code field appears');
  await window.fill('#qpl_v2Code', 'AB12CD34');
  await window.click('#qpl_v2 [data-qpl-v2="revoke-confirm"]');
  await window.waitForFunction(() => !document.getElementById('qpl_v2Code') && !/Mac Studio/.test(document.getElementById('qpl_v2').innerText), null, { timeout: 5_000 });
  ok(await electronApp.evaluate(() => globalThis.__qlk.codeUsed) === 'AB12CD34', 'the typed code is what revokes it, and the key leaves the list');

  console.log('e2e-pay-link-keys: ok');
} catch (err) {
  failed = true;
  console.error('e2e-pay-link-keys FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
