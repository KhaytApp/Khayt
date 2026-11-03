#!/usr/bin/env node
/**
 * Capture Khayt POPULATED, across every shipped design, for a UI/UX audit.
 *
 * The earlier pass captured empty states, which flatter a design — every screen looks calm
 * when there is nothing on it. Real density is the thing to judge.
 *
 * Output → /tmp/khayt-audit/*.png
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const outDir = '/tmp/khayt-audit';
fs.mkdirSync(outDir, { recursive: true });
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-audit-'));

// Every design a user can pick. This said three for the whole 3.4 line, so an
// audit meant to cover 'all shipped themes' silently skipped five of them.
const THEMES = ['khayt', 'workbench', 'command', 'vivid', 'blueprint', 'nocturne', 'meridian', 'foreman', 'flow'];
const TABS = [
  ['dashboard-tab', 'dashboard'],
  ['queue-tab', 'queue'],
  ['calculator-tab', 'calculator'],
  ['inventory-tab', 'inventory'],
  ['analytics-tab', 'analytics'],
];

let app;
try {
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`], cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_USER_DATA: userData },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  await page.waitForSelector('.khayt-app', { timeout: 60_000 });
  await page.waitForFunction(() => (document.querySelector('#dashboardContent')?.innerHTML?.length || 0) > 100, { timeout: 60_000 });
  await page.setViewportSize({ width: 1512, height: 950 });

  // Seed real data. Collections are module-scoped `let`s, so assign through the store
  // loader rather than window.* — that was the mistake in the first pass.
  const demo = buildScreenshotDemoStore();
  await page.evaluate((store) => {
    const wiz = document.querySelector('#setup-wizard');
    if (wiz) wiz.style.display = 'none';
    if (typeof applyStoreFromSnapshot === 'function') applyStoreFromSnapshot(store);
    if (typeof settings !== 'undefined' && settings) { settings.firstRun = false; settings.mode = 'professional'; }
    try { saveAll(); } catch (_) {}
  }, demo);
  await page.waitForTimeout(1500);

  for (const theme of THEMES) {
    await page.evaluate((t) => {
      settings.designTheme = t;
      if (typeof applyDesignSettings === 'function') applyDesignSettings();
      if (typeof initialRender === 'function') initialRender();
    }, theme);
    await page.waitForTimeout(1200);

    for (const [tab, name] of TABS) {
      await page.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
      await page.waitForTimeout(800);
      const file = `${theme}-${name}.png`;
      await page.screenshot({ path: path.join(outDir, file), type: 'png' });
      console.log(`  ✓ ${file}`);
    }
  }

  // Arabic RTL on the default theme — half the market.
  await page.evaluate(() => {
    settings.designTheme = 'workbench';
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    settings.lang = 'ar';
    window.i18n.set('ar');
    if (typeof initialRender === 'function') initialRender();
  });
  await page.waitForTimeout(1500);
  for (const [tab, name] of [['dashboard-tab', 'dashboard'], ['queue-tab', 'queue']]) {
    await page.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
    await page.waitForTimeout(800);
    await page.screenshot({ path: path.join(outDir, `rtl-${name}.png`), type: 'png' });
    console.log(`  ✓ rtl-${name}.png`);
  }

  console.log(`\n→ ${outDir}`);
} catch (e) {
  console.error('FAILED: ' + e.message);
} finally {
  try { if (app) await app.close(); } catch { /* already closed */ }
}
