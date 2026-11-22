#!/usr/bin/env node
/**
 * Capture the same Workbench dashboard in each of the three experience modes
 * (Enthusiast / Simple / Professional) for the website's "three modes" section.
 * Output: ../khayt-website/screenshots/modes/dashboard-<mode>.png
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const outDir = process.env.KHAYT_SHOTS_OUT || path.resolve(root, '..', 'khayt-website', 'screenshots', 'modes');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-mode-shots-'));
const VIEWPORT = { width: 1440, height: 940 };
const MODES = ['enthusiast', 'simple', 'professional'];

let electronApp;
try {
  const demoStore = buildScreenshotDemoStore();
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
  await page.evaluate(async () => { await window.hubAPI.loadStore(); });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.khayt-app', { timeout: 90_000 });
  await page.waitForFunction(
    () => typeof printLog !== 'undefined' && Array.isArray(printLog) && printLog.length > 5,
    { timeout: 30_000 },
  );
  await page.evaluate(() => {
    settings.designTheme = 'workbench';
    settings.theme = 'light';
    if (typeof applyTheme === 'function') applyTheme('light');
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
  });

  fs.mkdirSync(outDir, { recursive: true });
  for (const mode of MODES) {
    await page.evaluate((m) => {
      settings.mode = m;
      if (typeof applyMode === 'function') applyMode(m);
      window.KhaytShell?.switchTab?.('dashboard-tab');
      const wiz = document.querySelector('#setup-wizard'); if (wiz) wiz.style.display = 'none';
      document.querySelector('#toastContainer')?.replaceChildren();
    }, mode);
    await page.waitForTimeout(1100);
    const out = path.join(outDir, `dashboard-${mode}.png`);
    await page.locator('.khayt-app').screenshot({ path: out, type: 'png' });
    console.log(`  ${path.relative(root, out)}`);
  }
  console.log(`\nDone — ${MODES.length} mode dashboards → ${outDir}`);
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
