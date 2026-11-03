#!/usr/bin/env node
/**
 * Capture the marketing-site screen set straight into ../khayt-website/screenshots/
 * in the website's own naming convention (screenshot[-ar]-<key>.png), across the
 * three featured themes (Workbench flat + Command/Vivid subdirs) in EN + AR.
 *
 * Unlike capture-screenshots.mjs (numbered README/release set), this writes the
 * exact files app.js references — no rename step. Gate on real demo data landing
 * so no screen renders empty.
 *
 * Env overrides (for iterating): KHAYT_SHOTS_THEMES=workbench  KHAYT_SHOTS_LANGS=en
 *   KHAYT_SHOTS_KEYS=dashboard,printfiles   KHAYT_SHOTS_OUT=/abs/dir
 * macOS runs headed; Linux CI: xvfb-run -a node scripts/capture-website-screenshots.mjs
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const outRoot = process.env.KHAYT_SHOTS_OUT || path.resolve(root, '..', 'khayt-website', 'screenshots');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-web-shots-'));
const VIEWPORT = { width: 1440, height: 940 };

// key → tab + a wait selector that proves the screen actually rendered.
const ALL_SCREENS = [
  { key: 'dashboard',   tab: 'dashboard-tab',   wait: '#dashboard-tab' },
  { key: 'queue',       tab: 'queue-tab',       wait: '#queue-tab .kanban-col, #queue-tab .kanban-board, #queue-tab' },
  { key: 'calculator',  tab: 'calculator-tab',  wait: '#calculator-tab #buildTableBody tr, #calculator-tab', setup: 'calculator' },
  { key: 'orders',      tab: 'logs-tab',        wait: '#logs-tab table tbody tr, #logs-tab' },
  { key: 'inventory',   tab: 'inventory-tab',   wait: '#inventory-tab table tbody tr, #inventory-tab' },
  { key: 'analytics',   tab: 'analytics-tab',   wait: '#analytics-tab .analytics-grid, #analytics-tab' },
  { key: 'clients',     tab: 'clients-tab',     wait: '#clients-tab table tbody tr, #clients-tab' },
  { key: 'catalog',     tab: 'catalog-tab',     wait: '#catalogGrid .product-card, #catalogGrid' },
  { key: 'giftcards',   tab: 'gift-cards-tab',  wait: '#giftCardsContainer table tbody tr, #gift-cards-tab' },
  { key: 'portfolio',   tab: 'portfolio-tab',   wait: '#portfolioGrid .portfolio-cell, #portfolioGrid' },
  { key: 'waste',       tab: 'waste-tab',       wait: '#wasteTable tbody tr, #waste-tab' },
  // 3.1 additions
  { key: 'printfiles',  tab: 'printfiles-tab',  wait: '#printfiles-tab .pf-grid .pf-card, #printfiles-tab' },
  { key: 'colorstudio', tab: 'colorstudio-tab', wait: '#colorstudio-tab' },
];

// Every design a visitor can pick in the app. Workbench is the default and
// writes the flat set the site falls back to; the rest live under themes/<id>/.
// Nocturne is captured DARK on purpose — it is the one design built for a dim
// workshop, and a light capture would sell it as another pale one.
const ALL_THEMES = [
  { id: 'workbench', appearance: 'light', dir: '' },              // flat set
  { id: 'command',   appearance: 'light', dir: 'themes/command' },
  { id: 'vivid',     appearance: 'light', dir: 'themes/vivid' },
  { id: 'khayt', appearance: 'light', dir: 'themes/khayt' },
  { id: 'blueprint', appearance: 'light', dir: 'themes/blueprint' },
  { id: 'nocturne',  appearance: 'dark',  dir: 'themes/nocturne' },
  { id: 'meridian',  appearance: 'light', dir: 'themes/meridian' },
  { id: 'foreman',   appearance: 'light', dir: 'themes/foreman' },
  { id: 'flow',      appearance: 'light', dir: 'themes/flow' },
];
const ALL_LANGS = ['en', 'ar'];

const pick = (envName, all, idOf) => {
  const raw = process.env[envName];
  if (!raw) return all;
  const want = raw.split(',').map((s) => s.trim());
  return all.filter((x) => want.includes(idOf(x)));
};
const themes = pick('KHAYT_SHOTS_THEMES', ALL_THEMES, (t) => t.id);
const langs = pick('KHAYT_SHOTS_LANGS', ALL_LANGS, (l) => l);
const screens = pick('KHAYT_SHOTS_KEYS', ALL_SCREENS, (s) => s.key);

async function seedCalculator(page) {
  await page.evaluate(() => {
    window.KhaytShell?.switchTab?.('calculator-tab');
    const parts = [
      { name: 'Gearbox housing', qty: 2, printWeight: 148, printTime: 4.37, spoolCost: 75, spoolWeight: 1000, wearRate: 0.05, powerDraw: 120, elecRate: 0.18, prepTime: 0.25, postTime: 0.5, laborRate: 45, failureRate: 5 },
      { name: 'Mounting bracket', qty: 4, printWeight: 62, printTime: 1.8, spoolCost: 82, spoolWeight: 1000, wearRate: 0.05, powerDraw: 120, elecRate: 0.18, prepTime: 0.15, postTime: 0.3, laborRate: 45, failureRate: 5 },
      { name: 'Cable clip', qty: 10, printWeight: 8, printTime: 0.4, spoolCost: 130, spoolWeight: 1000, wearRate: 0.05, powerDraw: 120, elecRate: 0.18, prepTime: 0.05, postTime: 0.1, laborRate: 45, failureRate: 8 },
    ];
    for (const p of parts) {
      for (const k in p) { const el = $('#' + ({ name: 'partName', qty: 'partQty' }[k] || k)); if (el) el.value = String(p[k]); }
      if ($('#margin')) $('#margin').value = '35';
      addPart();
    }
    renderBuild();
    calculateLivePartCost?.();
    window.KhaytBedReadyUI?.initStudioCalculatorLayout?.();
  });
}

async function applyTheme(page, theme, lang) {
  await page.evaluate(({ id, appearance, lang }) => {
    settings.designTheme = id;
    settings.theme = appearance;
    settings.lang = lang;
    if (typeof applyTheme === 'function') applyTheme(appearance);
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    if (typeof i18n !== 'undefined' && typeof i18n.set === 'function') i18n.set(lang, { silent: true });
    window.KhaytShell?.switchTab?.('dashboard-tab');
    const wiz = document.querySelector('#setup-wizard');
    if (wiz) wiz.style.display = 'none';
    document.querySelector('#toastContainer')?.replaceChildren();
    document.querySelector('#modalMount')?.replaceChildren();
  }, { ...theme, lang });
}

async function prepareShot(page, shot, calcSeeded) {
  if (shot.setup === 'calculator') {
    if (!calcSeeded.done) { await seedCalculator(page); calcSeeded.done = true; }
    else await page.evaluate(() => { window.KhaytShell?.switchTab?.('calculator-tab'); if (typeof renderBuild === 'function') renderBuild(); window.KhaytBedReadyUI?.initStudioCalculatorLayout?.(); });
    return;
  }
  await page.evaluate((tabId) => window.KhaytShell.switchTab(tabId), shot.tab);
}

let electronApp;
let total = 0;
try {
  const demoStore = buildScreenshotDemoStore();
  demoStore.settings = demoStore.settings || {};
  demoStore.settings.firstRun = false;
  demoStore.settings.firstRunDone = true;

  electronApp = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
    timeout: 120_000,
  });

  const page = await electronApp.firstWindow();
  await page.setViewportSize(VIEWPORT);
  await page.waitForSelector('.khayt-app', { timeout: 90_000 });
  await page.waitForFunction(
    () => typeof window.hubAPI?.loadStore === 'function' && typeof window.KhaytShell?.switchTab === 'function',
    { timeout: 90_000 },
  );

  const saveResult = await page.evaluate(async (store) => window.hubAPI.saveStore(store), demoStore);
  if (!saveResult?.ok) throw new Error(`saveStore failed: ${JSON.stringify(saveResult)}`);
  // Round-trip the store back from disk before reloading — forces the write to
  // flush and confirms the persisted snapshot actually contains the demo data.
  const diskCheck = await page.evaluate(async () => {
    const l = await window.hubAPI.loadStore();
    return { printLog: (l?.printLog || []).length, printFiles: (l?.printFiles || []).length };
  });
  console.log('disk after save:', JSON.stringify(diskCheck));

  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.khayt-app', { timeout: 90_000 });
  await page.waitForFunction(
    () => document.querySelector('#setup-wizard')?.style.display === 'none' && typeof window.KhaytShell?.switchTab === 'function',
    { timeout: 90_000 },
  );
  // Gate on the demo orders actually landing in the app global — loadAll applies
  // the disk store asynchronously after reload. An empty-state <tr> in the log
  // table is NOT a reliable signal (it exists before data lands); the global
  // printLog length is unambiguous and theme-independent.
  await page.waitForFunction(
    () => typeof printLog !== 'undefined' && Array.isArray(printLog) && printLog.length > 5
      && typeof printFiles !== 'undefined' && Array.isArray(printFiles) && printFiles.length > 0,
    { timeout: 30_000 },
  );

  for (const theme of themes) {
    for (const lang of langs) {
      const pre = lang === 'ar' ? 'ar-' : '';
      const outDir = path.join(outRoot, theme.dir);
      fs.mkdirSync(outDir, { recursive: true });
      await applyTheme(page, theme, lang);
      await page.waitForTimeout(900);
      const calcSeeded = { done: false };
      console.log(`\n[${theme.id} · ${lang}]`);

      for (const shot of screens) {
        await prepareShot(page, shot, calcSeeded);
        await page.waitForTimeout(600);
        try { await page.waitForSelector(shot.wait, { timeout: 12_000 }); }
        catch { console.warn(`  selector timeout for ${shot.key}, capturing anyway`); }
        await page.waitForTimeout(400);
        const out = path.join(outDir, `screenshot-${pre}${shot.key}.png`);
        await page.locator('.khayt-app').screenshot({ path: out, type: 'png' });
        total += 1;
        console.log(`  ${path.relative(outRoot, out)}`);
      }
    }
  }
  console.log(`\nDone — ${total} screenshots → ${outRoot}`);
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
