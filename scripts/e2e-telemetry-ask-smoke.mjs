/**
 * E2E smoke — the one-time ask about crash reports, in a real window.
 *
 * The card sits at the top of the content, never in front of it. "Not Now"
 * puts it away for good on this computer and turns nothing on; "Share Crash
 * Reports" turns crash reports on (and usage counts only if ticked). A manager,
 * who may not change Settings, is not asked. Scripted windows never see it
 * unless they ask (window.__khaytAskTelemetry), so screenshots stay clean.
 *
 * Run: npm run test:e2e:telemetry-ask   (TELEMETRY_ASK_SHOTS=<dir> saves screenshots)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.TELEMETRY_ASK_SHOTS || '';
const card = (window) => window.evaluate(() => {
  const el = document.getElementById('telemetryAsk');
  return el ? { text: el.innerText, first: el.parentElement.firstElementChild === el, parent: el.parentElement.id } : null;
});
const consent = (window) => window.evaluate(() => ({ ...(settings.telemetry || {}) }));

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await window.evaluate(() => { window.__khaytAskTelemetry = true; renderTelemetryAsk(); });
  ok(await window.evaluate(() => shouldShowSetupWizard()) && !(await card(window)), 'not while the first-run setup is up');
  await window.evaluate(() => { delete window.__khaytAskTelemetry; });

  await dismissWizard(window);
  await window.evaluate(() => renderTelemetryAsk());
  ok(!(await card(window)), 'a scripted window is not asked');

  await window.evaluate(() => { window.__khaytAskTelemetry = true; renderTelemetryAsk(); });
  let c = await card(window);
  ok(c && c.parent === 'mainContent' && c.first, 'the card sits at the top of the content');
  ok(/Help make Khayt better\?/.test(c.text) && /Share Crash Reports/.test(c.text) && /Not Now/.test(c.text), 'it asks, with both answers');
  ok(/Crash Reports & Usage/.test(c.text), 'and says where to change it later');
  const covered = await window.evaluate(() => getComputedStyle(document.getElementById('telemetryAsk')).position);
  ok(covered === 'static', `it is in the flow, not over anything (${covered})`);
  ok((await consent(window)).crashOptIn !== true, 'nothing is on while it asks');
  if (shots) await window.screenshot({ path: shots + '/telemetry-ask-en.png' });

  // A manager can read Settings but not change them, so is not asked.
  await window.evaluate(() => {
    operators.push({ id: 'e2e-mgr', name: 'Manager', roleKey: 'manager' });
    settings.operatorLockEnabled = true;
    settings.activeOperatorId = 'e2e-mgr';
    applyOperatorPermissions();
  });
  ok(!(await card(window)), 'a manager is not asked');
  await window.evaluate(() => {
    settings.operatorLockEnabled = false;
    settings.activeOperatorId = null;
    operators.splice(operators.findIndex((o) => o.id === 'e2e-mgr'), 1);
    applyOperatorPermissions();
  });
  ok(!!(await card(window)), 'the owner is asked again once the lock is off');

  // Not Now: put away for good, nothing turned on.
  await window.click('#telemetryAsk [data-tel-ask="not-now"]');
  ok(!(await card(window)), '"Not Now" puts it away');
  await window.evaluate(() => renderTelemetryAsk());
  ok(!(await card(window)), 'and it does not come back');
  ok(await window.evaluate(() => localStorage.getItem('khayt_telemetry_asked') === '1'), 'this computer remembers it was asked');
  const off = await consent(window);
  ok(!off.crashOptIn && !off.usageOptIn && !off.installId, '"Not Now" turns nothing on');

  // Share: crash reports on, usage only because it was ticked.
  await window.evaluate(() => { localStorage.removeItem('khayt_telemetry_asked'); renderTelemetryAsk(); });
  await window.click('#telemetryAsk [data-tel-ask="share"]');
  await window.waitForFunction(() => !document.getElementById('telemetryAsk'));
  let on = await consent(window);
  ok(on.crashOptIn === true && on.usageOptIn === false, 'Share turns crash reports on, and usage counts stay off unticked');
  ok(/^[0-9a-f]{16}$/.test(on.installId) && !!on.consentAt, 'with an install id and the consent time');
  ok(await window.evaluate(() => document.getElementById('tel_crash')?.checked === true), 'Settings shows the switch on');

  await window.evaluate(async () => { await setTelemetryConsent(false, false); localStorage.removeItem('khayt_telemetry_asked'); renderTelemetryAsk(); });
  await window.check('#telemetryAskUsage');
  await window.click('#telemetryAsk [data-tel-ask="share"]');
  await window.waitForFunction(() => !document.getElementById('telemetryAsk'));
  on = await consent(window);
  ok(on.crashOptIn === true && on.usageOptIn === true, 'ticking usage counts shares them too');
  await window.evaluate(() => { localStorage.removeItem('khayt_telemetry_asked'); renderTelemetryAsk(); });
  ok(!(await card(window)), 'a computer already sharing is not asked');

  // ---- Arabic ----
  await window.evaluate(async () => {
    await setTelemetryConsent(false, false);
    localStorage.removeItem('khayt_telemetry_asked');
    settings.lang = 'ar'; i18n.set('ar');
  });
  c = await card(window);
  ok(!!c, 'the card follows a language change');
  ok(await window.evaluate(() => document.documentElement.dir) === 'rtl', 'Arabic lays out right to left');
  ok(!/tel\.ask/.test(c.text), 'no raw locale key in Arabic');
  ok(/هل تساعدنا في تحسين خيط؟/.test(c.text) && /ليس الآن/.test(c.text) && /تقارير الأعطال والاستخدام/.test(c.text), 'the card is translated');
  if (shots) await window.screenshot({ path: shots + '/telemetry-ask-ar.png' });

  console.log('e2e-telemetry-ask: ok (asked once at the top; Not Now = off for good; Share = crash on, usage if ticked; manager not asked; en + ar)');
} catch (err) {
  failed = true;
  console.error('e2e-telemetry-ask FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
