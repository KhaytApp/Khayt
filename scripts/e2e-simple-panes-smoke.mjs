/**
 * E2E smoke — Simple mode never shows an empty Settings pane (Windows/Linux).
 *
 * Team and AI are Professional panes (Notifications was, until the S4 map): their nav buttons carry
 * .pro-only. Opening one in Simple (a deep link, search, a button elsewhere,
 * or switching to Simple while on it) used to show an empty page with no pane
 * selected. Here:
 *   - each Pro pane opened in Simple shows the "Part of Professional" panel
 *     (S4 card 2), never an empty page;
 *   - Notifications is 'reduced' in the S4 map, so Simple opens it as itself;
 *   - switching Pro → Simple while on AI shows that panel too;
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
    gateText: (document.getElementById('settings-panel-gated')?.innerText || '').trim(),
  }));

  await window.evaluate(() => { settings.mode = 'simple'; applyMode(); });
  for (const pane of ['team', 'ai']) {
    await window.evaluate((p) => openSettingsSection(p), pane);
    const s = await state();
    ok(s.panel === 'settings-panel-gated' && /Professional/.test(s.gateText), `Simple: opening "${pane}" shows the "Part of Professional" panel (${JSON.stringify({ nav: s.nav, panel: s.panel })})`);
  }

  // Messages is 'reduced' in the S4 map: Simple opens the pane itself.
  await window.evaluate(() => openSettingsSection('notify'));
  const msg = await state();
  ok(msg.nav === 'notify' && msg.panel === 'settings-panel-notify', `Simple: Notifications opens as itself (S4: reduced) (${JSON.stringify({ nav: msg.nav, panel: msg.panel })})`);

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

  await window.evaluate(() => openSettingsSection('ai'));
  await window.evaluate(() => { settings.mode = 'simple'; applyMode(); });
  const after = await state();
  ok(after.panel === 'settings-panel-gated' && /Professional/.test(after.gateText), `switching to Simple while on AI shows the "Part of Professional" panel (${JSON.stringify({ nav: after.nav, panel: after.panel })})`);

  console.log('e2e-simple-panes: ok');
} catch (err) {
  failed = true;
  console.error('e2e-simple-panes FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
