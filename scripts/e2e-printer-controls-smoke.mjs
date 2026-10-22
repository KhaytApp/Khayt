/**
 * E2E smoke — pause, resume, cancel and "drop one object" on the machine card.
 *
 * The controls show only while a job is running or paused, only the verbs the
 * printer's protocol can take (lib/printer-commands.js), and Cancel asks first:
 * dismissing the question sends nothing, confirming it sends the command. The
 * printer here is an unreachable LAN address, so a command that reaches the
 * printer path comes back as "did not take it" — which is how the test knows it
 * was sent. The Mac's card is the model.
 *
 * Run: npm run test:e2e:printerctl
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const acts = (window, id) => window.evaluate((id) => [...document.querySelectorAll(`[data-machine-ctl="${id}"] [data-act]`)].map((b) => b.dataset.act), id);

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(() => {
    machines.push(
      { id: 'm-k', name: 'U1', printerApi: { type: 'moonraker', host: '10.255.255.1', port: 7125 } },
      { id: 'm-b', name: 'P1S', printerApi: { type: 'bambu', host: '10.255.255.2', serial: 'X', accessCode: 'y' } },
      { id: 'm-r', name: 'Rep', printerApi: { type: 'repetier', host: '10.255.255.3', port: 3344, printerSlug: 'rep' } },
    );
    const now = Date.now();
    machineStatusCache['m-k'] = { state: 'printing', progress: 40, lastUpdated: now };
    machineStatusCache['m-b'] = { state: 'printing', progress: 10, lastUpdated: now };
    machineStatusCache['m-r'] = { state: 'printing', progress: 70, lastUpdated: now };
  });
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="printers"]');
  await window.evaluate(() => renderMachines());
  await window.waitForSelector('[data-machine-ctl="m-k"]');

  ok(JSON.stringify(await acts(window, 'm-k')) === JSON.stringify(['printer-pause', 'printer-cancel', 'printer-drop']), 'a Klipper printer that is printing offers Pause, Cancel and Drop one object');
  ok((await acts(window, 'm-b')).length === 0, 'a Bambu printer offers no job control (its protocol cannot)');
  ok(JSON.stringify(await acts(window, 'm-r')) === JSON.stringify(['printer-cancel']), 'Repetier offers Cancel but not Pause, which it cannot do');

  await window.evaluate(() => { machineStatusCache['m-k'].state = 'paused'; updateMachinesLiveStatus(); });
  ok(JSON.stringify(await acts(window, 'm-k')) === JSON.stringify(['printer-resume', 'printer-cancel', 'printer-drop']), 'paused, it offers Resume instead of Pause');

  await window.evaluate(() => { machineStatusCache['m-k'].state = 'standby'; updateMachinesLiveStatus(); });
  ok((await acts(window, 'm-k')).length === 0, 'an idle printer shows no controls');
  await window.evaluate(() => { machineStatusCache['m-k'].state = 'printing'; machineStatusCache['m-k'].lastUpdated = Date.now() - 10 * 60 * 1000; updateMachinesLiveStatus(); });
  ok((await acts(window, 'm-k')).length === 0, 'nor does one whose reading is stale');
  await window.evaluate(() => { machineStatusCache['m-k'].lastUpdated = Date.now(); updateMachinesLiveStatus(); });

  // Every toast, recorded: they fade on their own, so reading the page races.
  await window.evaluate(() => { window.__toasts = []; const orig = window.toast; window.toast = (...a) => { window.__toasts.push(String(a[0])); return orig(...a); }; });
  const sent = (n) => window.waitForFunction((n) => window.__toasts.filter((x) => /did not take it|Sent to the printer/.test(x)).length > n, n, { timeout: 30000 }).then(() => true, () => false);
  const count = () => window.evaluate(() => window.__toasts.filter((x) => /did not take it|Sent to the printer/.test(x)).length);

  // Cancel asks; dismissing sends nothing.
  const toasts = () => window.evaluate(() => [...document.querySelectorAll('.toast, [class*="toast"]')].map((e) => e.textContent).join(' | '));
  await window.click('[data-machine-ctl="m-k"] [data-act="printer-cancel"]');
  await window.waitForSelector('.modal');
  const ask = await window.evaluate(() => document.querySelector('.modal').innerText);
  ok(/Cancel the print on U1\?/.test(ask) && /scrap/.test(ask), 'Cancel asks first, and says the plate is scrap');
  await window.click('.modal [data-act="cancel"]');
  await window.waitForTimeout(1500);
  ok((await count()) === 0, 'dismissing the question sends nothing');

  // Confirming sends it (the unreachable printer answers with an error).
  await window.click('[data-machine-ctl="m-k"] [data-act="printer-cancel"]');
  await window.waitForSelector('.modal');
  await window.click('.modal [data-act="save"]');
  ok(await sent(0), 'confirming sends the cancel to the printer');

  // Pause goes straight through.
  const before = await count();
  await window.click('[data-machine-ctl="m-k"] [data-act="printer-pause"]');
  ok(!(await window.$('.modal')), 'Pause does not ask');
  ok(await sent(before), 'and is sent at once');

  // Arabic labels
  await window.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); renderMachines(); });
  const ar = await window.evaluate(() => document.querySelector('[data-machine-ctl="m-k"]').innerText);
  ok(/إيقاف مؤقت/.test(ar) && /إلغاء الطباعة/.test(ar) && !/mach\./.test(ar), 'the controls are translated');

  console.log('e2e-printer-controls: ok (shown while running/paused, only verbs the protocol has, Cancel asks, Pause does not, en + ar)');
} catch (err) {
  failed = true;
  console.error('e2e-printer-controls FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
