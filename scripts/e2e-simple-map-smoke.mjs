/**
 * E2E smoke — the desktop follows SIMPLE_MAP (lib/feature-tiers.js, S4).
 *
 * In Simple:
 *   - each wired 'pro' surface is hidden: schedule, kiosk, campaigns, parts to
 *     buy, the supplier reorder list, the order editor's payment plan and
 *     milestones, the machine editor's upkeep and value, a job's change order;
 *   - Expenses opens as its short list (S4 card 4), not as the panel;
 *   - a Professional pane (Team, AI) reached anyway shows
 *     "Part of Professional" with a switch that works and lands on it; a
 *     view opened in place (kiosk) offers the switch instead of opening;
 *   - Notifications & Messages opens with the WhatsApp templates only;
 *   - Connections opens;
 *   - the location picker shows with two locations, not with one (both modes).
 * In Professional every one of them is reachable.
 *
 * Run: npm run test:e2e:simplemap
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  const setMode = (mode) => window.evaluate((m) => { settings.mode = m; applyMode(); }, mode);
  // Is the element (or what it sits in) hidden by a rule? Closed menus are not
  // counted: each element is asked about itself and its own wrappers.
  const shown = (sel) => window.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) return 'missing';
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      // Not the closed menu, tab or pane it sits in — only what hides it.
      if (n.tagName === 'DETAILS' || n.classList.contains('ovf-menu') || n.classList.contains('row-actions-menu') || n.classList.contains('tab-content') || n.classList.contains('settings-panel')) continue;
      if (getComputedStyle(n).display === 'none') return false;
    }
    return true;
  }, sel);

  // Sample book: one open order, one low spool with a supplier.
  await window.evaluate(() => {
    printLog.push({ id: 'ORD-sm1', project: 'Bracket', status: 'pending', price: 100, clientId: '', parts: [{ name: 'a', printWeight: 10 }, { name: 'b', printWeight: 10 }], date: localDateStr() });
    suppliers.push({ id: 'SUP-1', name: 'Filament Co' });
    inventory.push({ id: 'INV-low', material: 'PETG', color: '#222222', weight: 20, cost: 80, reorderPoint: 200, supplierId: 'SUP-1' });
    saveAll();
  });

  const STATIC_PRO = ['#btnScheduleView', '#btnSuggestSchedule', '#chkAutoSchedule', '#btnKioskView', '#btnCampaign', '#btnPartsToBuy', '#supplierReorderList'];
  const dynamicChecks = async () => {
    const out = {};
    await window.evaluate(() => { switchTab('logs-tab'); renderLogs(); });
    out.changeOrder = await shown('[data-act="change-order"][data-id="ORD-sm1"]');
    await window.evaluate(() => { switchTab('inventory-tab'); });
    out.draftPo = await shown('[data-act="reorder-alert-item"][data-id="INV-low"]');
    await window.evaluate(() => openOrderEditor('ORD-sm1'));
    await window.waitForSelector('#oeInstalmentsBlock', { state: 'attached' });
    out.instalments = await shown('#oeInstalmentsBlock');
    out.milestones = await shown('#oeOpenMilestones');
    await window.evaluate(() => document.querySelectorAll('#modalMount > *').forEach((n) => n.remove()));
    await window.evaluate(() => openMachineEditor(null));
    await window.waitForSelector('#machServiceInterval', { state: 'attached' });
    out.service = await shown('#machServiceInterval');
    out.depreciation = await shown('#machDepPrice');
    await window.evaluate(() => document.querySelectorAll('#modalMount > *').forEach((n) => n.remove()));
    return out;
  };

  const badge = () => window.evaluate(() => {
    const b = document.querySelector('.khayt-brand .sm-mode-badge');
    return b && getComputedStyle(b).display !== 'none' ? b.textContent : null;
  });
  await setMode('professional');
  ok(await badge() === null, 'Professional: no mode badge in the sidebar head');

  // ── Simple ──
  await setMode('simple');
  ok(await badge() === 'Simple', 'Simple: a "Simple" badge beside the name in the sidebar head');
  for (const sel of STATIC_PRO) ok(await shown(sel) === false, `Simple: ${sel} is hidden`);
  const dyn = await dynamicChecks();
  for (const [k, v] of Object.entries(dyn)) ok(v === false, `Simple: ${k} is hidden`);

  // Expenses is 'reduced' since S4 card 4: Simple opens its short list, not
  // the panel (scripts/e2e-simple-screens-smoke.mjs checks the list itself).
  const expSimple = await window.evaluate(() => {
    switchTab('expenses-tab');
    const tab = document.getElementById('expenses-tab');
    return { active: tab.classList.contains('active'), gated: tab.classList.contains('sm-gated') };
  });
  ok(expSimple.active && !expSimple.gated, `Simple: Expenses opens, not as the panel (${JSON.stringify(expSimple)})`);
  ok(await shown('#expSimple') === true, 'Simple: Expenses is the short list');

  // Professional panes reached anyway.
  const paneState = () => window.evaluate(() => ({
    nav: document.querySelector('.settings-nav-item.active')?.dataset.settingsSection || null,
    panel: document.querySelector('.settings-panel.active')?.id || null,
    text: document.querySelector('.settings-panel.active')?.innerText || '',
  }));
  for (const pane of ['team', 'ai']) {
    await window.evaluate((p) => openSettingsSection(p), pane);
    const s = await paneState();
    ok(s.panel === 'settings-panel-gated' && /is part of Professional/.test(s.text), `Simple: the "${pane}" pane shows "Part of Professional" (${s.panel})`);
  }
  await window.click('#settings-panel-gated [data-act="sm-switch-pro"]');
  await window.waitForTimeout(300);
  const afterPaneSwitch = await paneState();
  ok(await window.evaluate(() => settings.mode) === 'professional' && afterPaneSwitch.panel === 'settings-panel-ai' && afterPaneSwitch.nav === 'ai', `the pane's switch moves to Professional and opens AI (${afterPaneSwitch.panel})`);
  await setMode('simple');
  ok((await paneState()).panel === 'settings-panel-gated', 'switching to Simple while on AI shows the panel again');

  // Messages: the pane opens, with the WhatsApp templates only.
  await window.evaluate(() => openSettingsSection('notify'));
  const notify = await paneState();
  ok(notify.panel === 'settings-panel-notify' && notify.nav === 'notify', `Simple: Notifications & Messages opens (${notify.panel})`);
  ok(await shown('#waTemplatesCard') === true, 'Simple: the WhatsApp templates are there');
  for (const id of ['telegramSettingsContainer', 'ntfySettingsContainer', 'emailDigestSection', 'emailNotificationsSection', 'smsNotificationsSection']) {
    ok(await shown('#' + id) === false, `Simple: #${id} (SMS providers, Telegram, email relay…) is hidden`);
  }
  await window.evaluate(() => openSettingsSection('connections'));
  ok((await paneState()).panel === 'settings-panel-connections', 'Simple: Connections opens');

  // A view that opens in place offers the switch instead.
  await window.evaluate(() => { switchTab('queue-tab'); document.getElementById('btnKioskView').click(); });
  await window.waitForTimeout(200);
  const kiosk = await window.evaluate(() => ({
    view: getComputedStyle(document.getElementById('kioskView')).display,
    modal: document.querySelector('.confirm-modal-overlay')?.innerText || '',
  }));
  ok(kiosk.view === 'none' && /part of Professional/i.test(kiosk.modal), `Simple: Kiosk offers the switch instead of opening (${kiosk.view})`);
  await window.click('.confirm-modal-overlay [data-act="cancel"]');

  // Location picker: shown only with 2+ locations, in either mode.
  const picker = (n) => window.evaluate((count) => {
    locations = Array.from({ length: count }, (_, i) => ({ id: 'LOC-' + i, name: 'Site ' + i }));
    renderLocationFilter();
    return getComputedStyle(document.getElementById('locationFilter')).display !== 'none';
  }, n);
  ok(await picker(1) === false, 'Simple: one location — no picker');
  ok(await picker(2) === true, 'Simple: two locations — the picker');

  // ── Professional ──
  await setMode('professional');
  ok(await picker(1) === false, 'Professional: one location — no picker');
  ok(await picker(2) === true, 'Professional: two locations — the picker');
  await window.evaluate(() => { locations = []; renderLocationFilter(); });
  for (const sel of STATIC_PRO) ok(await shown(sel) === true, `Professional: ${sel} is there`);
  const dynPro = await dynamicChecks();
  for (const [k, v] of Object.entries(dynPro)) ok(v === true, `Professional: ${k} is there`);
  for (const pane of ['team', 'ai', 'notify']) {
    await window.evaluate((p) => openSettingsSection(p), pane);
    const s = await paneState();
    ok(s.panel === 'settings-panel-' + pane && s.nav === pane, `Professional: "${pane}" opens as itself`);
  }
  ok(await shown('#smsNotificationsSection') === true, 'Professional: the SMS / WhatsApp providers are there');
  const proTab = await window.evaluate(() => { switchTab('expenses-tab'); const t = document.getElementById('expenses-tab'); return t.classList.contains('active') && !t.classList.contains('sm-gated'); });
  ok(proTab, 'Professional: Expenses opens as itself');
  await window.evaluate(() => { switchTab('queue-tab'); document.getElementById('btnKioskView').click(); });
  ok(await window.evaluate(() => getComputedStyle(document.getElementById('kioskView')).display !== 'none'), 'Professional: Kiosk opens');

  console.log('e2e-simple-map: ok');
} catch (err) {
  failed = true;
  console.error('e2e-simple-map FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
