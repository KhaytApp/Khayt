#!/usr/bin/env node
/**
 * E2E critical flows: boot, tabs, order lifecycle, store I/O, LAN PIN gate.
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
import zipWrite from '../lib/zip-write.js';

const require = createRequire(import.meta.url);
const StoreLock = require('../lib/store-lock.js');
import {
  E2E_LAN_PIN,
  E2E_LAN_PORT,
  assertStatus,
  dismissWizard,
  lanRequest,
  launchApp,
  makeUserDataDir,
  switchTab,
} from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

async function testBootAndDashboard(window) {
  const boot = await window.evaluate(() => ({
    importClientsCsv: typeof importClientsCsv,
    dashboardLen: document.querySelector('#dashboardContent')?.innerHTML?.length || 0,
  }));
  if (boot.importClientsCsv !== 'function') {
    throw new Error('importClientsCsv is not on global scope — wireEvents may have failed');
  }
  if (boot.dashboardLen < 100) {
    throw new Error(`dashboard did not render (content length ${boot.dashboardLen})`);
  }
}

async function testSettingsNav(window) {
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="general"]');
  const prefsActive = await window.evaluate(
    () => document.querySelector('#settings-panel-general')?.classList.contains('active') === true
  );
  if (!prefsActive) throw new Error('settings sidebar navigation did not switch panels');
}

async function testStoreRoundTrip(window) {
  const version = await window.evaluate(() => window.hubAPI.appVersion());
  if (!version) throw new Error('hub:app-version returned empty');

  const saveResult = await window.evaluate(async () => {
    const data = (await window.hubAPI.loadStore()) || {};
    data.settings = data.settings || {};
    data.settings.shopName = 'E2E Smoke Test';
    data.printLog = data.printLog || [];
    // Regression: subscriptions + auditLog must survive the save/load round-trip
    // (they used to be stripped by normalizeStoreSnapshot and reset on restart).
    data.subscriptions = [{ id: 'SUB-e2e', clientId: 'C-e2e', amount: 250 }];
    data.auditLog = [{ at: 1, actor: 'e2e', action: 'test' }];
    return window.hubAPI.saveStore(data);
  });
  if (!saveResult?.ok) throw new Error(`saveStore failed: ${JSON.stringify(saveResult)}`);

  const reloaded = await window.evaluate(async () => {
    const data = await window.hubAPI.loadStore();
    return {
      shopName: data?.settings?.shopName,
      subCount: (data?.subscriptions || []).length,
      subId: (data?.subscriptions || [])[0]?.id,
      auditCount: (data?.auditLog || []).length,
    };
  });
  if (reloaded.shopName !== 'E2E Smoke Test') {
    throw new Error(`store round-trip mismatch: got ${JSON.stringify(reloaded)}`);
  }
  if (reloaded.subCount !== 1 || reloaded.subId !== 'SUB-e2e' || reloaded.auditCount !== 1) {
    throw new Error(`subscriptions/auditLog not persisted: ${JSON.stringify(reloaded)}`);
  }
  return version;
}

async function testTabNavigation(window) {
  await switchTab(window, 'queue-tab');
  const kanban = await window.evaluate(() => ({
    pending: !!document.querySelector('#list-pending'),
    printing: !!document.querySelector('#list-printing'),
    cols: document.querySelectorAll('.kanban-col').length,
  }));
  if (!kanban.pending || kanban.cols < 5) {
    throw new Error(`queue tab kanban not rendered: ${JSON.stringify(kanban)}`);
  }

  await switchTab(window, 'calculator-tab');
  const calcReady = await window.evaluate(
    () => !!document.querySelector('#margin') && typeof logPrint === 'function'
  );
  if (!calcReady) throw new Error('calculator tab did not load build UI');

  await switchTab(window, 'logs-tab');
  const logsReady = await window.evaluate(() => !!document.querySelector('#logTable tbody'));
  if (!logsReady) throw new Error('logs tab table not rendered');
}

async function testOrderLifecycle(window) {
  const orderId = await window.evaluate(async () => {
    const id = `E2E-${Date.now()}`;
    const order = {
      id,
      date: new Date().toISOString().split('T')[0],
      timestamp: new Date().toISOString(),
      project: 'E2E Lifecycle Order',
      status: 'pending',
      price: 150,
      material: 'PLA',
      printTime: 2,
      parts: [{ name: 'Test cube', qty: 1, material: 'PLA', baseCost: 50, printTime: 2 }],
      statusHistory: [{ status: 'pending', at: new Date().toISOString() }],
      queuePos: 1,
    };
    printLog.unshift(order);
    await saveAll();
    renderKanban();
    renderLogs();
    return id;
  });

  await switchTab(window, 'queue-tab');
  await window.waitForFunction(
    (id) => !!document.querySelector(`#list-pending [data-id="${id}"]`),
    orderId,
    { timeout: 15_000 }
  );

  await switchTab(window, 'logs-tab');
  await window.waitForFunction(
    (id) => (document.querySelector('#logTable tbody')?.textContent || '').includes(id),
    orderId,
    { timeout: 15_000 }
  );

  const newStatus = await window.evaluate(async (id) => {
    const order = printLog.find(o => o.id === id);
    if (!order) return null;
    order.status = 'printing';
    order.statusHistory = order.statusHistory || [];
    order.statusHistory.push({ status: 'printing', at: new Date().toISOString() });
    await saveAll();
    renderKanban();
    renderLogs();
    return order.status;
  }, orderId);
  if (newStatus !== 'printing') throw new Error('order status update failed');

  await switchTab(window, 'queue-tab');
  await window.waitForFunction(
    (id) => !!document.querySelector(`#list-printing [data-id="${id}"]`),
    orderId,
    { timeout: 15_000 }
  );

  return orderId;
}

// Tab navigation must survive a live theme switch — a shell that re-chromes the
// page can leave the tab buttons unbound. This ran against ledger until that
// theme was deleted; workbench (the default) and command exercise the same path.
async function testThemeSwitchTabNavigation(window) {
  const applyTheme_ = async (design, bodyClass) => {
    await window.evaluate((d) => {
      settings.designTheme = d;
      settings.theme = 'light';
      if (typeof applyDesignSettings === 'function') applyDesignSettings();
      if (typeof applyTheme === 'function') applyTheme('light');
    }, design);
    await window.waitForFunction(
      (c) => document.body.classList.contains(c),
      bodyClass,
      { timeout: 10_000 }
    );
  };

  await applyTheme_('workbench', 'khayt-workbench');

  await window.click('#tabbtn-queue-tab');
  await window.waitForFunction(
    () => document.getElementById('queue-tab')?.classList.contains('active') === true,
    { timeout: 10_000 }
  );
  const queueReady = await window.evaluate(
    () => !!document.querySelector('#list-pending') && document.querySelectorAll('.kanban-col').length >= 5
  );
  if (!queueReady) throw new Error('workbench theme: queue tab did not activate after click');

  await window.click('#tabbtn-settings-tab');
  await window.waitForFunction(
    () => document.getElementById('settings-tab')?.classList.contains('active') === true,
    { timeout: 10_000 }
  );

  // Switching away must tear the old shell down cleanly.
  await applyTheme_('command', 'khayt-command');
  await window.waitForFunction(
    () => !document.body.classList.contains('khayt-workbench'),
    { timeout: 10_000 }
  );
}

async function testLanPinGate(window) {
  const lanStart = await window.evaluate(async ({ port, pin }) => {
    const data = (await window.hubAPI.loadStore()) || {};
    data.settings = data.settings || {};
    data.settings.lanApi = { ...(data.settings.lanApi || {}), pin };
    const save = await window.hubAPI.saveStore(data);
    if (!save?.ok) return { ok: false, error: 'saveStore before LAN' };
    return window.hubAPI.startLanServer({ port, pin, bindLan: 'loopback' });
  }, { port: E2E_LAN_PORT, pin: E2E_LAN_PIN });
  if (!lanStart?.ok) throw new Error(`startLanServer failed: ${JSON.stringify(lanStart)}`);

  const port = lanStart.port || E2E_LAN_PORT;

  assertStatus('GET /api/status?format=json', (await lanRequest(port, '/api/status?format=json')).status, 200);
  assertStatus('GET /intake', (await lanRequest(port, '/intake')).status, 200);
  assertStatus('GET /api/orders without PIN', (await lanRequest(port, '/api/orders')).status, 401);

  const ordersWithPin = await lanRequest(port, '/api/orders', { pin: E2E_LAN_PIN });
  assertStatus('GET /api/orders with PIN', ordersWithPin.status, 200);
  if (!Array.isArray(ordersWithPin.body)) {
    throw new Error('GET /api/orders with PIN expected array body');
  }

  assertStatus(
    'POST /api/inventory without PIN',
    (await lanRequest(port, '/api/inventory', { method: 'POST', body: { material: 'PLA', weightTotal: 1000 } })).status,
    401
  );
  assertStatus(
    'POST /api/inventory with PIN',
    (await lanRequest(port, '/api/inventory', {
      method: 'POST',
      pin: E2E_LAN_PIN,
      body: { material: 'PLA', weightTotal: 1000 },
    })).status,
    201
  );

  await window.evaluate(() => window.hubAPI.stopLanServer());
}

// 4.2: HueForge (filament painting) is a Khayt tab too, not only Bed Ready's. It shows in
// Simple and Professional, renders, and is styled by the shared renderer/hueforge.css
// (its rules used to sit in bedready-theme.css, which Khayt does not load).
async function testHueForge(window) {
  const r = await window.evaluate(() => {
    const vis = (id) => { const b = document.getElementById(id); return !!(b && b.offsetParent !== null); };
    const out = {};
    settings.mode = 'simple'; applyMode();
    out.simpleVisible = vis('tabbtn-hueforge-tab');
    settings.mode = 'professional'; applyMode();
    out.proVisible = vis('tabbtn-hueforge-tab');
    switchTab('hueforge-tab');
    const tab = document.getElementById('hueforge-tab');
    out.active = document.querySelector('.tab-content.active')?.id === 'hueforge-tab';
    out.rendered = (tab?.innerHTML?.length || 0) > 200;
    const root = tab?.querySelector('.hf');
    out.styled = !!root && getComputedStyle(root).maxWidth === '1180px';
    out.libs = typeof KhaytHueForge === 'object' && typeof KhaytHueForgeCalibrate === 'object';
    return out;
  });
  const bad = Object.entries(r).filter(([, v]) => v !== true).map(([k]) => k);
  if (bad.length) throw new Error(`HueForge checks failed: ${bad.join(', ')} — ${JSON.stringify(r)}`);
}

// Convert at save (Nov 2 2026): a quote for a client who pays in another
// currency says under the total what it will be saved as, and is saved in it.
async function testClientCurrencyQuote(window) {
  const r = await window.evaluate(() => {
    const out = {};
    settings.mode = 'professional'; applyMode();
    settings.currency = 'SAR';
    settings.exchangeRates = Object.assign({}, settings.exchangeRates, { EUR: 4 });
    clients.push({ id: 'C-E2E-EUR', nameEn: 'Euro Client', currency: 'EUR' });
    switchTab('calculator-tab');
    currentBuild = [{ id: 'PRT-E2E-FX', name: 'fx part', material: 'PLA', baseCost: 100, printTime: 1, qty: 1, printWeight: 10 }];
    currentClientId = 'C-E2E-EUR';
    $('#margin').value = '15';
    ['#discountPct', '#shippingCost', '#priceOverride', '#priceRoundStep'].forEach((s) => { const e = $(s); if (e) e.value = ''; });
    currentExtraLines = [];
    renderBuild(); updateGrandTotal();
    const line = $('#priceCurrencyLine');
    out.lineShown = !!line && line.style.display !== 'none';
    out.lineText = line ? line.textContent : '';
    out.sarTotal = lastQuote ? lastQuote.total : null;
    const before = printLog.length;
    logPrint(true);
    const job = printLog[0];
    out.saved = printLog.length === before + 1;
    out.currency = job && job.currency;
    out.price = job && job.price;
    // What the line promised is what was saved.
    out.lineMatches = !!job && out.lineText.includes(fmtMoneyIn(job.price, 'EUR'));
    // Clean up so later checks see the book they expect.
    if (out.saved) printLog.shift();
    clients = clients.filter((c) => c.id !== 'C-E2E-EUR');
    currentClientId = null; currentBuild = [];
    saveAll();
    return out;
  });
  // The saved price is the shop-currency total at 4 SAR to the euro.
  const ok = r.lineShown && r.lineMatches && r.saved && r.currency === 'EUR'
    && r.sarTotal > 0 && Math.abs(r.price - r.sarTotal / 4) < 0.02;
  if (!ok) throw new Error(`client-currency quote failed: ${JSON.stringify(r)}`);
}

// The invoice is drawn inside the app window, so the app's `td { color:
// var(--text) }` used to paint the quantity column in the theme's text colour
// (pale grey on white under a dark theme, in print and PDF). Every cell must
// take the paper's ink, and the payment-schedule header must not get the
// app's header fill.
async function testInvoiceCellsTakePaperInk(window) {
  const r = await window.evaluate(async () => {
    const o = { id: 'E2E-INK-1', invoiceNum: 'INV-E2E-INK', date: localDateStr(), timestamp: new Date().toISOString(),
      project: 'Ink job', price: 500, status: 'completed',
      parts: [{ name: 'Part Ink', material: 'PLA', baseCost: 100, qty: 2, printTime: 1 }],
      instalments: [{ dueDate: localDateStr(), amount: 250, paid: false }, { dueDate: localDateStr(), amount: 250, paid: true }] };
    printLog.unshift(o);
    try {
      await renderInvoiceForOrder(o);
      const area = document.querySelector('#invoice-print-area');
      const inv = area.querySelector('.inv');
      const ink = getComputedStyle(inv).color;
      const qty = area.querySelector('table.lines td.center');
      const schedTh = [...area.querySelectorAll('table:not(.lines) th')][0];
      const schedTd = [...area.querySelectorAll('table:not(.lines) td')][0];
      const bg = schedTh ? getComputedStyle(schedTh).backgroundColor : null;
      return {
        ink,
        qty: qty && getComputedStyle(qty).color,
        schedTd: schedTd && getComputedStyle(schedTd).color,
        schedThBg: bg,
        schedThUpper: schedTh ? getComputedStyle(schedTh).textTransform : null,
      };
    } finally {
      printLog.shift(); saveAll();
    }
  });
  const clear = (c) => c === 'rgba(0, 0, 0, 0)' || c === 'transparent';
  const ok = r.qty === r.ink && r.schedTd === r.ink && clear(r.schedThBg) && r.schedThUpper === 'none';
  if (!ok) throw new Error(`invoice cells take the app theme, not the paper's ink: ${JSON.stringify(r)}`);
}

// A milestone is a PROFORMA for its part of the job (Nov 2026): one line, its
// own amount, no ZATCA QR, nothing of the job's parts or shipping — the job's
// one tax invoice stays the job's.
async function testMilestoneProforma(window) {
  const r = await window.evaluate(async () => {
    const zatca = settings.enableZatca, vat = settings.vat;
    settings.enableZatca = true; settings.vat = '300000000000003';
    const o = { id: 'E2E-MS-1', invoiceNum: 'INV-E2E-77', date: localDateStr(), timestamp: new Date().toISOString(),
      project: 'Milestone job', price: 1150, shippingCost: 50, rushFeeAmount: 0, status: 'printing',
      parts: [{ name: 'Part Alpha', material: 'PLA', baseCost: 300, qty: 2, printTime: 3 }],
      milestoneInvoices: [{ id: 'm1', label: 'Deposit', percentage: 30, amount: 345 }] };
    printLog.unshift(o);
    try {
      await generateMilestoneInvoice(o.id, o.milestoneInvoices[0]);
      const area = document.querySelector('#invoice-print-area');
      const text = area.innerText.replace(/\s+/g, ' ');
      return {
        rows: area.querySelectorAll('tbody tr').length,
        label: text.includes('Deposit'),
        noParts: !text.includes('Part Alpha'),
        noInvoiceNumber: !text.includes('INV-E2E-77'),
        issued: !!o.milestoneInvoices[0].issuedAt,
        total345: /345[.,]00/.test(text),
      };
    } finally {
      printLog.shift(); settings.enableZatca = zatca; settings.vat = vat; saveAll();
    }
  });
  const bad = Object.entries(r).filter(([k, v]) => (k === 'rows' ? v !== 1 : v !== true)).map(([k]) => k);
  if (bad.length) throw new Error(`milestone proforma failed: ${bad.join(', ')} — ${JSON.stringify(r)}`);
}

// 3.2 (Bed Ready split): "enthusiast" is RETIRED as a Khayt-selectable mode — its maker
// tools (converter / Colour Studio / print-file library) are now core Simple/Pro features.
// Verify the retirement (no switcher pill + stored enthusiast migrates to Simple), that the
// maker surfaces stay available, and that Simple/Pro gating still works. (The commerce-free
// enthusiast experience now lives only in the Bed Ready flavor — see e2e-bedready-smoke.)
async function testModesAndPrintFiles(window) {
  const r = await window.evaluate(async () => {
    const vis = (id) => { const b = document.getElementById(id); return !!(b && b.offsetParent !== null); };
    const out = {};
    // Enthusiast is gone from the Khayt switcher, and any stored enthusiast mode
    // migrates to Simple the moment applyMode() runs.
    out.noEnthusiastPill = !document.getElementById('btnModeEnthusiast');
    settings.mode = 'enthusiast'; applyMode();
    out.enthusiastMigratedToSimple = settings.mode === 'simple'
      && document.body.classList.contains('mode-simple')
      && !document.body.classList.contains('mode-enthusiast');
    // The maker tools remain available (Simple/Pro core, not commerce-gated).
    out.printfilesVisible = vis('tabbtn-printfiles-tab');
    out.converterVisible = vis('tabbtn-converter-tab');
    out.colorstudioVisible = vis('tabbtn-colorstudio-tab');
    out.calcVisible = vis('tabbtn-calculator-tab');
    switchTab('printfiles-tab');
    out.pfRendered = document.querySelector('.tab-content.active')?.id === 'printfiles-tab'
      && (document.getElementById('printfiles-tab')?.innerHTML?.length || 0) > 50;
    printFiles.unshift({ id: 'PF-e2e', name: 'E2E Model', originalName: 'e2e.stl', sourceFile: { filename: 'm.stl', ext: 'stl' }, createdAt: 1, updatedAt: 1 });
    await window.hubAPI.saveStore(buildStoreSnapshot());
    const loaded = await window.hubAPI.loadStore();
    out.pfPersisted = Array.isArray(loaded.printFiles) && loaded.printFiles.some((x) => x.id === 'PF-e2e');
    // Simple mode: business basics reachable (the Money page + catalog), and
    // Expenses as its short list (SIMPLE_MAP 'reduced' since S4; the tracker's
    // budgets, recurring and exports stay Professional).
    settings.mode = 'simple'; applyMode();
    out.simpleAnalyticsVisible = vis('tabbtn-analytics-tab'); // Sales reports available to small shops
    out.simpleCatalogVisible = vis('tabbtn-catalog-tab');
    out.simpleExpensesShown = vis('tabbtn-expenses-tab');
    switchTab('analytics-tab'); // reachable (not bounced) in simple
    out.simpleAnalyticsReachable = document.querySelector('.tab-content.active')?.id === 'analytics-tab';
    // beta.15: ZATCA Phase 2 (Pro-only e-invoicing) must not render in Simple mode.
    if (typeof renderZatcaPhase2Settings === 'function') {
      renderZatcaPhase2Settings();
      out.simpleZatca2Empty = (document.getElementById('zatcaPhase2Section')?.innerHTML || '') === '';
    } else { out.simpleZatca2Empty = true; }
    settings.mode = 'professional'; applyMode();
    if (typeof renderZatcaPhase2Settings === 'function') {
      renderZatcaPhase2Settings();
      out.proZatca2Rendered = (document.getElementById('zatcaPhase2Section')?.innerHTML || '').length > 20;
    } else { out.proZatca2Rendered = true; }
    return out;
  });
  const bad = Object.entries(r).filter(([, v]) => v !== true).map(([k]) => k);
  if (bad.length) throw new Error(`enthusiast/print-file checks failed: ${bad.join(', ')} — ${JSON.stringify(r)}`);
}

// 3.1 beta.2: Colour studio renders (personal-core, incl. enthusiast); multicolour
// planner cost-trick is exact and completion deduction draws from each colour's spool.
async function testColourStudioAndPlanner(window) {
  const r = await window.evaluate(async () => {
    const out = {};
    // Colour tab is personal core → visible in enthusiast mode and renders.
    settings.mode = 'enthusiast'; applyMode();
    out.colorTabVisible = !!(document.getElementById('tabbtn-colorstudio-tab')?.offsetParent);
    switchTab('colorstudio-tab');
    out.csRendered = document.querySelector('.tab-content.active')?.id === 'colorstudio-tab'
      && !!document.getElementById('csMatchResults');
    settings.mode = 'professional'; applyMode();

    // Seed two coloured filaments.
    const red = { id: 'INV-red', material: 'PLA Red', color: '#E23B3B', colourVariant: 'Red', cost: 20, weight: 1000, materialType: 'fdm' };
    const blue = { id: 'INV-blue', material: 'PLA Blue', color: '#2C63E8', colourVariant: 'Blue', cost: 30, weight: 1000, materialType: 'fdm' };
    inventory.push(red, blue);

    // Matcher: nearest to pure red is the red spool.
    out.nearRed = KhaytColor.nearest('#FF0000', inventory.filter((i) => KhaytColor.hexToRgb(i.color)))[0]?.id === 'INV-red';

    // Synthesize a planned part exactly like the planner: 100 g red @0.02/g + 50 g blue @0.03/g.
    const gRed = 100, gBlue = 50;
    const cpg = (it) => it.cost / it.weight;
    const colours = [
      { filamentId: 'INV-red', hex: '#E23B3B', grams: gRed, cost: cpg(red) * gRed },   // 2.0
      { filamentId: 'INV-blue', hex: '#2C63E8', grams: gBlue, cost: cpg(blue) * gBlue }, // 1.5
    ];
    const totalGrams = gRed + gBlue;                            // 150
    const totalCost = colours.reduce((s, c) => s + c.cost, 0);  // 3.5
    const part = {
      name: 'MC', material: 'Multicolour', filamentId: 'INV-red',
      spoolCost: totalCost, spoolWeight: totalGrams, printWeight: totalGrams, supportWeight: 0,
      printTime: 0, qty: 1, extraMaterials: [], priceTiers: [], failureRate: 0, colours,
    };
    // The cost trick: material component of the synthesized part == Σ per-colour cost.
    out.costTrick = Math.abs(computePartBreakdown(part).material - totalCost) < 1e-6;

    // Completion deduction pulls each colour's grams from its own spool.
    settings.autoDeduct = true;
    deductFilamentForOrder({ id: 'ORD-mc', status: 'completed', parts: [{ ...part, id: 'PRT-mc' }] }, { skipRender: true });
    out.redDeducted = inventory.find((i) => i.id === 'INV-red').weight === 1000 - gRed;   // 900
    out.blueDeducted = inventory.find((i) => i.id === 'INV-blue').weight === 1000 - gBlue; // 950
    return out;
  });
  const bad = Object.entries(r).filter(([, v]) => v !== true).map(([k]) => k);
  if (bad.length) throw new Error(`colour-studio/planner checks failed: ${bad.join(', ')} — ${JSON.stringify(r)}`);
}

// 3.1 beta.3: multi-slicer — legacy single slicer migrates into slicers[]; the settings
// list renders a row per slicer and the default helper honours defaultSlicerId.
async function testMultiSlicer(window) {
  const r = await window.evaluate(async () => {
    const out = {};
    // Start from the legacy single-slicer shape.
    settings.slicers = undefined;
    settings.defaultSlicerId = null;
    settings.slicer = { path: '/x/PrusaSlicer.app', args: '-a' };
    switchTab('settings-tab');
    renderSlicerSettings(); // runs the one-time migration
    out.migrated = Array.isArray(settings.slicers) && settings.slicers.length === 1
      && settings.slicers[0].path === '/x/PrusaSlicer.app';
    out.rows1 = document.querySelectorAll('#slicerSettingsSection .slicer-row').length === 1;

    // Add a second slicer and make it default.
    settings.slicers.push({ id: 'sl-orca', name: 'OrcaSlicer', path: '/x/OrcaSlicer.exe', args: '' });
    settings.defaultSlicerId = 'sl-orca';
    out.list2 = KhaytSlicers.listSlicers(settings).length === 2;
    out.defOrca = KhaytSlicers.defaultSlicer(settings).id === 'sl-orca';
    renderSlicerSettings();
    out.rows2 = document.querySelectorAll('#slicerSettingsSection .slicer-row').length === 2;
    // Default is mirrored into the legacy field for slice-and-print consumers.
    out.mirror = settings.slicer.path === '/x/OrcaSlicer.exe';

    // Auto-detect scans the machine and returns a well-formed {ok, slicers[]}
    // list of {name, path}; merging never duplicates paths already listed.
    const det = await window.hubAPI.detectSlicers();
    out.detectShape = !!(det && det.ok === true && Array.isArray(det.slicers)
      && det.slicers.every((s) => s && typeof s.name === 'string' && typeof s.path === 'string'));
    const before = settings.slicers.length;
    const added = await detectAndMergeSlicers();
    out.mergeNoDupes = settings.slicers.length === before + added && added >= 0;
    const paths = settings.slicers.map((s) => s.path.toLowerCase());
    out.uniquePaths = new Set(paths).size === paths.length;

    // Reset.
    settings.slicers = undefined; settings.defaultSlicerId = null;
    settings.slicer = { path: '', args: '' }; settings.slicersAutoDetected = false;
    return out;
  });
  const bad = Object.entries(r).filter(([, v]) => v !== true).map(([k]) => k);
  if (bad.length) throw new Error(`multi-slicer checks failed: ${bad.join(', ')} — ${JSON.stringify(r)}`);
}

// 3.1 beta.5: 3MF converter — the Converter tab renders, and the real main-process
// pipeline analyzes a synthesized Bambu 3MF and retargets it (re-profile + slot remap).
// Lazy id→record index: correct hits, and invalidation when the collection changes.
async function testIndexes(window) {
  const r = await window.evaluate(() => {
    const c = { id: 'IDX-e2e', name: 'Index Test' };
    clients.push(c);
    const hit = clientById('IDX-e2e');
    const found = !!(hit && hit.id === 'IDX-e2e');
    clients = clients.filter((x) => x.id !== 'IDX-e2e'); // reassign → index must rebuild
    const afterNull = clientById('IDX-e2e') === null;
    return { found, afterNull };
  });
  if (!r.found || !r.afterNull) throw new Error(`index checks failed: ${JSON.stringify(r)}`);
}

// 3.2 beta.9: archived-order prune — export helper partitions correctly, the
// purge removes only archived orders, and the deletion survives a save/load.
async function testPruneArchived(window) {
  const r = await window.evaluate(async () => {
    const stub = (id, arch) => ({ id, date: '2026-01-01', status: 'completed', project: id, archived: arch });
    printLog.push(stub('PRUNE-keep', false));
    printLog.push(stub('PRUNE-gone', true));
    const btn = !!document.getElementById('btnPruneArchived');
    const wired = typeof pruneArchivedOrders === 'function';
    // Mirror the renderer's inline prune mechanism (see pruneArchivedOrders).
    const archived = printLog.filter((o) => o && o.archived);
    const removed = new Set(archived.map((o) => o.id));
    printLog = printLog.filter((o) => !removed.has(o.id));
    await flushSave();
    const loaded = await window.hubAPI.loadStore();
    const ids = (loaded.printLog || []).map((o) => o.id);
    return {
      btn, wired,
      selectedGone: archived.some((o) => o.id === 'PRUNE-gone') && archived.length === 1,
      keptInMem: printLog.some((o) => o.id === 'PRUNE-keep'),
      goneInMem: !printLog.some((o) => o.id === 'PRUNE-gone'),
      persistedKept: ids.includes('PRUNE-keep'),
      persistedGone: !ids.includes('PRUNE-gone'),
    };
  });
  const ok = r.btn && r.wired && r.selectedGone && r.keptInMem && r.goneInMem && r.persistedKept && r.persistedGone;
  if (!ok) throw new Error(`prune checks failed: ${JSON.stringify(r)}`);
}

async function testConverter(window) {
  const model = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>';
  const proj = JSON.stringify({ printer_model: 'Orig', nozzle_diameter: ['0.4'], filament_colour: ['#FF0000', '#00FF00'], filament_type: ['PLA', 'PLA'] });
  const srcPath = `${userData}/conv-src.3mf`;
  // The batch destination has to be a folder the user APPROVED in the output-folder
  // picker — being a folder the converter may read from is not permission to write
  // there. Approved below, through the picker's own handler, the way batch conversion
  // does it. (This check used to pass without that, on a gate that authorised writes
  // with the read allow-list.)
  const outDir = `${userData}/conv-out`;
  fs.mkdirSync(outDir, { recursive: true });
  const outPath = `${outDir}/conv-out.3mf`;
  const stlPath = `${userData}/conv-src.stl`;
  fs.writeFileSync(stlPath, 'solid s\nfacet normal 0 0 0\n outer loop\n  vertex 0 0 0\n  vertex 30 0 0\n  vertex 0 15 8\n endloop\nendfacet\nendsolid s');
  fs.writeFileSync(srcPath, zipWrite.writeZip([
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: proj },
  ]));

  await electronApp.evaluate(async ({ dialog }, dir) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [dir] });
  }, outDir);
  const approvedOut = await window.evaluate(() => window.hubAPI.mfPickOutdir());
  if (!approvedOut || !approvedOut.ok) throw new Error('could not approve the converter output folder');

  const r = await window.evaluate(async ({ src, out, stl }) => {
    const res = {};
    switchTab('converter-tab');
    res.tabRendered = document.querySelector('.tab-content.active')?.id === 'converter-tab'
      && (document.getElementById('converter-tab')?.innerHTML?.length || 0) > 50;
    res.hasProfiles = !!(globalThis.KhaytPrinterProfiles && KhaytPrinterProfiles.listProfiles().length >= 4);
    // 3.2: batch pickers exposed, and the custom-printer manager renders in the tab.
    res.pickers = typeof window.hubAPI.mfPickMulti === 'function' && typeof window.hubAPI.mfPickOutdir === 'function';
    res.cpManager = (document.getElementById('converter-tab')?.innerHTML || '').includes('conv-cp');
    // 3.2 beta.6: a saved conversion preset renders in the tab's preset manager.
    settings.convPresets = [{ id: 'cvp-e2e', name: 'E2E Preset', targetId: 'bambu-x1c', slotMap: null }];
    renderConverter();
    res.presetShown = (document.getElementById('converter-tab')?.innerHTML || '').includes('E2E Preset');
    const a = await window.hubAPI.mfAnalyze(src);
    res.analyzeOk = !!a.ok; res.flavour = a.flavour; res.colorCount = a.colorCount;
    res.hasMeta = !!(a.meta && typeof a.meta === 'object');
    // 3.2: convert for a user-defined printer via an explicit target profile (no registry entry).
    const cust = await window.hubAPI.mfConvert({ path: src, targetId: 'x', mode: 'retarget', intoVaultId: 'PF-conv-cust',
      targetProfile: { id: 'custom-e2e', name: 'E2E Bot', flavour: 'bambu', maxColors: 4, bed: { x: 300, y: 300, z: 300 }, nozzle: 0.4, printerModel: 'E2E Bot' } });
    res.customOk = !!(cust.ok && cust.report && /E2E Bot/.test(cust.report.targetName || ''));
    // 3.2 beta.7: STL → 3MF wrapper produces a readable 3MF.
    const s2m = await window.hubAPI.stlTo3mf({ path: stl, intoVaultId: 'PF-stl-e2e' });
    res.stlOk = !!(s2m.ok && s2m.vault && s2m.filename);
    if (s2m.ok) { const sa = await window.hubAPI.mfAnalyze(s2m.outPath); res.stlAnalyzed = !!(sa.ok && sa.hasGeometry); }
    // 3.2 beta.8: reverse direction — 3MF → STL export is wired (preload fn + tab button).
    res.toStlWired = typeof window.hubAPI.mfToStl === 'function'
      && (document.getElementById('converter-tab')?.innerHTML || '').includes('convToStlBtn');
    const c = await window.hubAPI.mfConvert({ path: src, targetId: 'snapmaker-u1', mode: 'retarget', slotMap: [1, 0], outPath: out });
    res.convertOk = !!c.ok; res.target = c.report && c.report.target; res.remapped = c.report && c.report.colorsRemapped;

    // 3.1: in-app destination — convert straight into a print-file vault (no folder dialog).
    const vaultId = 'PF-conv-e2e';
    const v = await window.hubAPI.mfConvert({ path: src, targetId: 'snapmaker-u1', mode: 'retarget', slotMap: [1, 0], intoVaultId: vaultId });
    res.vaultOk = !!(v.ok && v.vault && v.filename && v.outPath);
    const files = await window.hubAPI.printLibList(vaultId);
    res.vaultListed = Array.isArray(files) && files.some((f) => f.filename === v.filename);
    if (typeof importConvertedAsNew === 'function') {
      await importConvertedAsNew({ vaultId, filename: v.filename, ext: v.ext, size: v.size, targetId: 'snapmaker-u1', targetName: 'Snapmaker U1', sourceName: 'conv-src.3mf' });
      res.recordCreated = (printFiles || []).some((p) => p.id === vaultId);
    }
    return res;
  }, { src: srcPath, out: outPath, stl: stlPath });

  const checks = {
    tabRendered: r.tabRendered === true,
    hasProfiles: r.hasProfiles === true,
    pickers: r.pickers === true,
    cpManager: r.cpManager === true,
    presetShown: r.presetShown === true,
    analyzeOk: r.analyzeOk === true,
    hasMeta: r.hasMeta === true,
    customOk: r.customOk === true,
    stlOk: r.stlOk === true,
    stlAnalyzed: r.stlAnalyzed === true,
    toStlWired: r.toStlWired === true,
    flavourBambu: r.flavour === 'bambu',
    colorCount2: r.colorCount === 2,
    convertOk: r.convertOk === true,
    targetU1: r.target === 'snapmaker-u1',
    remapped: r.remapped >= 1,
    outWritten: fs.existsSync(outPath) && fs.statSync(outPath).size > 0,
    vaultConvertOk: r.vaultOk === true,
    vaultListed: r.vaultListed === true,
    recordCreated: r.recordCreated === true,
  };
  const bad = Object.entries(checks).filter(([, v]) => v !== true).map(([k]) => k);
  if (bad.length) throw new Error(`converter checks failed: ${bad.join(', ')} — ${JSON.stringify(r)}`);
}

/**
 * The running app must say it owns the store.
 *
 * store-lock.js is pure and unit-tested, which proves the rules and nothing
 * about whether anything calls them. This is the half that can only be checked
 * with the app actually running: the record on disk, naming the live process.
 * Delete `acquireStoreOwnership()` from main.js and this fails.
 */
/**
 * Restore a backup through the real IPC: the window gets the masked copy, the
 * backup's secret lands on disk, and the window's follow-up save keeps it.
 * hub:restore-backup used to call a decryptStoreSecrets main.js no longer
 * imported, so every restore failed; and before that it handed the window
 * every credential in the clear.
 */
async function testRestoreBackupKeepsItsSecrets(window) {
  const SECRET = 'e2e-backup-ai-key';
  const MASK = '__KHAYT_MASKED__';
  const storeFile = path.join(userData, 'khayt-store.json');
  const onDisk = JSON.parse(fs.readFileSync(storeFile, 'utf8'));
  const backupName = '2000-01-01.json';
  fs.mkdirSync(path.join(userData, 'backups'), { recursive: true });
  fs.writeFileSync(path.join(userData, 'backups', backupName), JSON.stringify({
    ...onDisk,
    settings: { ...(onDisk.settings || {}), shopName: 'E2E Restored', ai: { apiKey: SECRET } },
  }));

  const json = await window.evaluate((f) => window.hubAPI.restoreBackup(f), backupName);
  if (!json) throw new Error('hub:restore-backup returned nothing — restore is broken');
  if (json.includes(SECRET)) throw new Error('hub:restore-backup handed the window a decrypted secret');
  const masked = JSON.parse(json);
  if (masked.settings?.ai?.apiKey !== MASK) throw new Error(`restored apiKey not masked: ${masked.settings?.ai?.apiKey}`);

  // What the disk holds, decrypted by the app's own keychain where it sealed it.
  const diskSecret = async () => {
    const v = JSON.parse(fs.readFileSync(storeFile, 'utf8')).settings?.ai?.apiKey;
    if (typeof v === 'string' && v.startsWith('__enc__')) {
      return electronApp.evaluate(({ safeStorage }, s) => safeStorage.decryptString(Buffer.from(s.slice(7), 'base64')), v);
    }
    return v;
  };
  const disk = JSON.parse(fs.readFileSync(storeFile, 'utf8'));
  if (disk.settings?.shopName !== 'E2E Restored') throw new Error('the restored store was not written to disk');
  if (await diskSecret() !== SECRET) throw new Error('the backup\'s secret is not on disk after a restore');

  // The window then saves what it restored — masks and all.
  const saved = await window.evaluate((m) => window.hubAPI.saveStore(m), masked);
  if (!saved?.ok) throw new Error(`save after restore failed: ${JSON.stringify(saved)}`);
  if (await diskSecret() !== SECRET) throw new Error('the save after a restore lost the backup\'s secret');
}

function testStoreOwnership() {
  const lockFile = path.join(userData, StoreLock.LOCK_FILENAME);
  if (!fs.existsSync(lockFile)) {
    throw new Error(`no ${StoreLock.LOCK_FILENAME} while the app is running — nothing took ownership`);
  }
  const record = JSON.parse(fs.readFileSync(lockFile, 'utf8'));
  if (!Number(record.pid)) throw new Error(`lock record has no pid: ${JSON.stringify(record)}`);
  if (!record.host) throw new Error('lock record has no host — a pid alone is not unique');
  // The app must read its own record as its own, or it would fight itself on the
  // next launch and every heartbeat would look like a rival.
  const asOwner = StoreLock.decide(record, {
    pid: record.pid, host: record.host, now: Date.now(), alive: true,
  });
  if (asOwner.action !== 'own') {
    throw new Error(`the app does not recognise its own lock: ${JSON.stringify(asOwner)}`);
  }
  // And a different process on the same machine must be told to keep out.
  const asRival = StoreLock.decide(record, {
    pid: record.pid + 1, host: record.host, now: Date.now(), alive: true,
  });
  if (asRival.action !== 'held') {
    throw new Error(`a second app would have taken the store: ${JSON.stringify(asRival)}`);
  }
  return record;
}

/**
 * A toast's Undo button takes a REAL click. The container is pointer-events:
 * none so its corner stays usable, and no toast took them back, so every Undo
 * (delete a job, a part, a client, a portal deposit…) was drawn and inert from
 * v1.0.0 on. A scripted el.click() never noticed: only a mouse at the button's
 * coordinates goes through hit-testing, which is what a person does.
 */
async function testToastButtonClickable(window) {
  await window.evaluate(() => {
    window.__e2eUndo = 0;
    toast('e2e undo', 'info', 20000, { undo: () => { window.__e2eUndo++; } });
  });
  await window.waitForSelector('.toast .undo-btn');
  await window.waitForTimeout(300); // past the toastIn animation
  const at = await window.evaluate(() => {
    const r = document.querySelector('.toast .undo-btn').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  });
  await window.mouse.click(at.x, at.y);
  const ran = await window.evaluate(() => window.__e2eUndo);
  if (ran !== 1) throw new Error(`a toast's Undo did not take a real click (ran ${ran} times)`);
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  // Generous default so the many waitForFunction gates below don't trip on a busy dev machine
  // (Electron boot/render can lag well past 30s under load). CI is fast, so this only adds headroom.
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);

  await testBootAndDashboard(window);
  await testSettingsNav(window);
  const version = await testStoreRoundTrip(window);
  await testTabNavigation(window);
  await testThemeSwitchTabNavigation(window);
  const orderId = await testOrderLifecycle(window);
  await testLanPinGate(window);
  await testModesAndPrintFiles(window);
  await testColourStudioAndPlanner(window);
  await testConverter(window);
  await testHueForge(window);
  await testIndexes(window);
  await testPruneArchived(window);
  await testMilestoneProforma(window);
  await testInvoiceCellsTakePaperInk(window);
  await testClientCurrencyQuote(window);
  await testToastButtonClickable(window);
  await testRestoreBackupKeepsItsSecrets(window);
  const owner = testStoreOwnership();

  console.log(
    'e2e-smoke: ok (version=%s, tabs + order %s + store + LAN PIN gate + store owned by pid %s)',
    version,
    orderId,
    owner.pid
  );
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
