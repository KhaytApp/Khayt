#!/usr/bin/env node
/**
 * Capture the main Khayt surfaces for a UI/UX review — including the cases that
 * normally go unlooked-at: Arabic RTL, a narrow window, and an empty store.
 *
 * Output → /tmp/khayt-ux/*.png
 * Run: node scripts/capture-ux-review-shots.mjs
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const outDir = '/tmp/khayt-ux';
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-ux-'));
fs.mkdirSync(outDir, { recursive: true });

const TABS = [
  ['dashboard-tab', 'dashboard'],
  ['queue-tab', 'queue'],
  ['calculator-tab', 'calculator'],
  ['catalog-tab', 'catalog'],
  ['clients-tab', 'clients'],
  ['inventory-tab', 'inventory'],
  ['analytics-tab', 'analytics'],
  ['settings-tab', 'settings'],
];

let app;
try {
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  await page.waitForSelector('.khayt-app', { timeout: 60_000 });
  await page.waitForFunction(() => typeof window.hubAPI?.saveStore === 'function', { timeout: 60_000 });
  await page.setViewportSize({ width: 1480, height: 940 });

  // Seed realistic data — an empty app tells you nothing about density or layout.
  const demo = buildScreenshotDemoStore();
  await page.evaluate((store) => {
    for (const [k, v] of Object.entries(store)) {
      try { if (typeof window[k] !== 'undefined') window[k] = v; } catch (_) {}
    }
    const wiz = document.querySelector('#setup-wizard');
    if (wiz) wiz.style.display = 'none';
    if (typeof settings !== 'undefined' && settings) settings.firstRun = false;
    try { window.saveAll?.(); } catch (_) {}
    try { window.KhaytShell?.switchTab?.('dashboard-tab'); } catch (_) {}
  }, demo);
  await page.waitForTimeout(1200);

  const shot = async (file, label) => {
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(outDir, file), type: 'png' });
    console.log(`  ✓ ${file} — ${label}`);
  };

  // 1. Every main tab at desktop width, populated.
  for (const [tab, name] of TABS) {
    await page.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
    await shot(`01-${name}.png`, `${name} (LTR, 1480px, populated)`);
  }

  // 2. Arabic RTL — the locale most likely to expose hardcoded direction.
  await page.evaluate(() => { window.i18n.set('ar'); });
  await page.waitForTimeout(600);
  // Fail loudly rather than silently capturing LTR and calling it RTL.
  const isRtl = await page.evaluate(() => document.documentElement.dir);
  if (isRtl !== 'rtl') throw new Error('language switch did not apply RTL, got dir=' + isRtl);
  console.log('  … dir=rtl confirmed');
  await page.waitForTimeout(1500);
  for (const [tab, name] of [['dashboard-tab', 'dashboard'], ['queue-tab', 'queue'], ['calculator-tab', 'calculator']]) {
    await page.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
    await shot(`02-rtl-${name}.png`, `${name} (Arabic RTL)`);
  }

  // 3. Narrow window — a laptop or a split screen.
  await page.evaluate(() => { window.i18n.set('en'); });
  await page.setViewportSize({ width: 1024, height: 768 });
  await page.waitForTimeout(900);
  for (const [tab, name] of [['dashboard-tab', 'dashboard'], ['queue-tab', 'queue'], ['settings-tab', 'settings']]) {
    await page.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
    await shot(`03-narrow-${name}.png`, `${name} (1024px)`);
  }

  console.log(`\nScreenshots → ${outDir}`);
} catch (e) {
  console.error('FAILED: ' + e.message);
} finally {
  try { if (app) await app.close(); } catch (_) {}
}
