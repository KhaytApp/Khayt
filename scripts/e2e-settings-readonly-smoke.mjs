/**
 * E2E smoke — Settings are read-only for a role that may only read them.
 *
 * With the operator lock on and a manager active (lib/rbac.js settings: R),
 * every Settings panel shows its values but no control can be changed, Save
 * refuses, and the operator switch still works so the owner can take over.
 * With the lock off, everything is live again. The Mac does the same.
 *
 * Run: npm run test:e2e:settingsro   (SETTINGS_RO_SHOTS=<dir> saves screenshots)
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.SETTINGS_RO_SHOTS || '';
const PANELS = ['biz', 'prefs', 'stock', 'invoice', 'payments', 'printers', 'online', 'data'];
const ALLOW = '.settings-nav-item, #btnSwitchOperator, #btnLockNow, #btnViewTelemetry';

async function liveControls(window, section) {
  await window.click(`.settings-nav-item[data-settings-section="${section}"]`);
  await window.waitForTimeout(250);
  return window.evaluate(({ section, ALLOW }) => {
    const panel = document.getElementById('settings-panel-' + section);
    if (!panel) return { missing: true, live: [] };
    const live = [...panel.querySelectorAll('input, select, textarea, button')]
      .filter((el) => !el.disabled && !el.matches(ALLOW) && el.offsetParent !== null)
      .map((el) => el.id || el.name || el.dataset.act || el.textContent.trim().slice(0, 20));
    return { missing: false, live };
  }, { section, ALLOW });
}

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await switchTab(window, 'settings-tab');
  const ownerLive = await liveControls(window, 'biz');
  ok(ownerLive.live.length > 0, `with the lock off, Settings are live (${ownerLive.live.length} controls)`);

  const before = await window.evaluate(() => settings.bizName || settings.businessName || '');
  await window.evaluate(() => {
    operators.push({ id: 'e2e-mgr', name: 'Manager', roleKey: 'manager' });
    settings.operatorLockEnabled = true;
    settings.activeOperatorId = 'e2e-mgr';
    applyOperatorPermissions();
  });
  ok(await window.evaluate(() => /Only the owner can change Settings/.test(document.getElementById('settingsReadOnlyNote')?.textContent || '')), 'a manager is told only the owner can change Settings');
  for (const s of PANELS) {
    const r = await liveControls(window, s);
    if (r.missing) continue;
    ok(r.live.length === 0, `${s}: nothing can be changed (${r.live.join(', ') || 'none live'})`);
  }
  if (shots) await window.screenshot({ path: shots + '/settings-readonly-en.png' });

  // A panel drawn after the gate is closed too.
  await window.evaluate(() => { renderLanApiSettings(); renderTelemetrySettings(); });
  await window.waitForTimeout(300);
  ok((await liveControls(window, 'online')).live.length === 0, 'a panel redrawn later is closed as well');

  // Save refuses even if called directly.
  await window.evaluate(() => {
    const el = document.querySelector('#settings-panel-biz input[type="text"]');
    if (el) { el.disabled = false; el.value = 'Changed By Manager'; }
    saveSettingsFromPanel();
  });
  const after = await window.evaluate(() => settings.bizName || settings.businessName || '');
  ok(after === before, 'Save refuses for a manager');

  ok(await window.evaluate(() => {
    const b = document.getElementById('btnSwitchOperator');
    return !b || !b.disabled;
  }), 'the operator switch still works, so the owner can take over');

  // Arabic
  await window.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); });
  await window.waitForTimeout(300);
  ok(await window.evaluate(() => /المالك وحده/.test(document.getElementById('settingsReadOnlyNote')?.textContent || '')), 'the note follows a language change');
  if (shots) await window.screenshot({ path: shots + '/settings-readonly-ar.png' });
  await window.evaluate(() => { settings.lang = 'en'; i18n.set('en'); });

  // Back to the owner.
  await window.evaluate(() => {
    settings.operatorLockEnabled = false;
    settings.activeOperatorId = null;
    applyOperatorPermissions();
  });
  ok(!(await window.evaluate(() => document.getElementById('settingsReadOnlyNote'))), 'the note goes when the lock is off');
  ok((await liveControls(window, 'biz')).live.length === ownerLive.live.length, 'and every control is live again');

  console.log('e2e-settings-readonly: ok (manager: every panel closed, redraws closed, Save refused, operator switch open; owner: all live)');
} catch (err) {
  failed = true;
  console.error('e2e-settings-readonly FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
