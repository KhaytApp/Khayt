/**
 * E2E smoke — Simple mode never shows an empty Settings pane (Windows/Linux).
 *
 * Team, Notifications and AI are Professional panes: their nav buttons carry
 * .pro-only. Opening one in Simple (a deep link, search, a button elsewhere,
 * or switching to Simple while on it) used to show an empty page with no pane
 * selected. Here:
 *   - each Pro pane opened in Simple lands on General, with General selected;
 *   - switching Pro → Simple while on Notifications lands on General;
 *   - in Professional the same panes open as themselves;
 *   - the Working Hours card is hidden whole in Simple, not left empty;
 *   - the mode comparison lists Loyalty tiers under Simple.
 *
 * Run: npm run test:e2e:simplepanes
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  const state = () => window.evaluate(() => ({
    nav: document.querySelector('.settings-nav-item.active')?.dataset.settingsSection || null,
    panel: document.querySelector('.settings-panel.active')?.id || null,
  }));

  await window.evaluate(() => { settings.mode = 'simple'; applyMode(); });
  for (const pane of ['team', 'notify', 'ai']) {
    await window.evaluate((p) => openSettingsSection(p), pane);
    const s = await state();
    ok(s.nav === 'general' && s.panel === 'settings-panel-general', `Simple: opening "${pane}" lands on General (${JSON.stringify(s)})`);
  }

  const hours = await window.evaluate(() => {
    openSettingsSection('shop');
    const card = document.getElementById('workingHoursGrid')?.closest('.settings-card');
    return card ? getComputedStyle(card).display : 'missing';
  });
  ok(hours === 'none', `Simple: the Working Hours card is hidden whole (${hours})`);

  const cmp = await window.evaluate(() => { openSettingsSection('general'); applyMode(); return document.getElementById('modeTierCompare').innerText; });
  const simpleCol = cmp.split(/Professional/)[0];
  ok(/Loyalty tiers/.test(simpleCol), 'the mode comparison lists Loyalty tiers under Simple');

  await window.evaluate(() => { settings.mode = 'professional'; applyMode(); });
  for (const pane of ['team', 'notify', 'ai']) {
    await window.evaluate((p) => openSettingsSection(p), pane);
    const s = await state();
    ok(s.nav === pane && s.panel === 'settings-panel-' + pane, `Professional: "${pane}" opens as itself`);
  }

  await window.evaluate(() => openSettingsSection('notify'));
  await window.evaluate(() => { settings.mode = 'simple'; applyMode(); });
  const after = await state();
  ok(after.nav === 'general' && after.panel === 'settings-panel-general', `switching to Simple while on Notifications lands on General (${JSON.stringify(after)})`);

  console.log('e2e-simple-panes: ok');
} catch (err) {
  failed = true;
  console.error('e2e-simple-panes FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
