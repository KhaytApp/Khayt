#!/usr/bin/env node
/**
 * Capture Studio + Ledger theme preview images for the theme picker.
 * Linux CI: xvfb-run -a node scripts/capture-theme-previews.mjs
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const outDir = path.join(root, 'renderer/themes/previews');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-theme-previews-'));

// Current default trio (their preview thumbnails shipped as placeholders).
// Legacy themes already have real captures; override with KHAYT_THEME_SET to
// re-capture any of them.
const DEFAULT_THEMES = [
  { id: 'workbench', appearance: 'light', file: 'workbench.png' },
  { id: 'command', appearance: 'light', file: 'command.png' },
  { id: 'vivid', appearance: 'light', file: 'vivid.png' },
  { id: 'khayt', appearance: 'light', file: 'khayt.png' },
  { id: 'blueprint', appearance: 'light', file: 'blueprint.png' },
  // Captured DARK on purpose: Nocturne's defaultAppearance is dark, and a light
  // thumbnail would sell the one theme built for a dim workshop as another
  // pale one.
  { id: 'nocturne', appearance: 'dark', file: 'nocturne.png' },
  { id: 'meridian', appearance: 'light', file: 'meridian.png' },
  { id: 'foreman', appearance: 'light', file: 'foreman.png' },
  { id: 'flow', appearance: 'light', file: 'flow.png' },
];
const THEMES = process.env.KHAYT_THEME_SET
  ? JSON.parse(process.env.KHAYT_THEME_SET)
  : DEFAULT_THEMES;

const VIEWPORT = { width: 1280, height: 800 };

let electronApp;
try {
  fs.mkdirSync(outDir, { recursive: true });
  const demoStore = buildScreenshotDemoStore();
  demoStore.settings = demoStore.settings || {};
  demoStore.settings.firstRun = false;
  demoStore.settings.firstRunDone = true;
  demoStore.settings.designTheme = 'studio';

  electronApp = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
    timeout: 120_000,
  });

  const page = await electronApp.firstWindow();
  await page.setViewportSize(VIEWPORT);
  await page.waitForSelector('.khayt-app', { timeout: 90_000 });

  // Bake each theme into the saved store and reload, so the app renders that
  // design from a clean load with demo data already applied (switching design
  // at runtime re-renders the dashboard mid-shell-swap and comes out empty).
  for (const theme of THEMES) {
    demoStore.settings.designTheme = theme.id;
    demoStore.settings.theme = theme.appearance;
    const saveResult = await page.evaluate(async (store) => window.hubAPI.saveStore(store), demoStore);
    if (!saveResult?.ok) throw new Error(`saveStore failed: ${JSON.stringify(saveResult)}`);

    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.khayt-app', { timeout: 90_000 });
    await page.waitForFunction(
      () => document.querySelector('#setup-wizard')?.style.display === 'none',
      { timeout: 60_000 },
    );
    await page.waitForFunction(
      (id) => document.documentElement.dataset.design === id || document.body.classList.contains(`khayt-${id}`),
      theme.id,
      { timeout: 30_000 },
    );
    // loadAll() applies the disk store asynchronously after reload — wait for the
    // demo data to land, then render the dashboard, so the preview isn't empty.
    await page.evaluate(() => window.KhaytShell?.switchTab?.('logs-tab'));
    await page.waitForSelector('#logs-tab table tbody tr', { timeout: 30_000 });
    await page.evaluate(() => {
      window.KhaytShell?.switchTab?.('dashboard-tab');
      const wiz = document.querySelector('#setup-wizard');
      if (wiz) wiz.style.display = 'none';
      document.querySelector('#toastContainer')?.replaceChildren();
    });
    await page.waitForTimeout(900);

    const out = path.join(outDir, theme.file);
    await page.locator('.khayt-app').screenshot({ path: out, type: 'png' });
    console.log(`  ${theme.file}`);
  }

  console.log(`\nTheme previews saved to ${outDir}`);
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
