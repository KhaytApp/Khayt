/**
 * E2E smoke — every main screen renders WITH REAL DATA, with zero errors.
 *
 * This exists because of a crash I shipped: renderPrinterUtilizationChart referenced a
 * variable belonging to a different function, and the Analytics tab threw
 * "ReferenceError: completed is not defined" — but ONLY once the shop had machines and
 * completed orders. The function returns early when `machines.length === 0`, so every
 * empty-store check sailed past it, including mine and 1056 unit tests.
 *
 * Empty states flatter a UI and hide its bugs. This seeds the demo store first.
 *
 * Run: npm run test:e2e:screens
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const TABS = ['dashboard-tab', 'queue-tab', 'calculator-tab', 'inventory-tab',
  'analytics-tab', 'clients-tab', 'catalog-tab', 'expenses-tab', 'settings-tab'];

const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-screens-'));
let app;
let failed = false;
try {
  app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`], cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_USER_DATA: userData },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e).slice(0, 200)));
  page.on('console', (m) => { if (m.type() === 'error') errors.push('[console] ' + m.text().slice(0, 200)); });

  await page.waitForSelector('.khayt-app', { timeout: 60_000 });
  await page.waitForFunction(
    () => (document.querySelector('#dashboardContent')?.innerHTML?.length || 0) > 100,
    { timeout: 60_000 },
  );

  // Seed real data — the whole point of this smoke.
  const demo = buildScreenshotDemoStore();
  await page.evaluate((store) => {
    const wiz = document.querySelector('#setup-wizard');
    if (wiz) wiz.style.display = 'none';
    if (typeof applyStoreFromSnapshot === 'function') applyStoreFromSnapshot(store);
    if (typeof settings !== 'undefined' && settings) { settings.firstRun = false; settings.mode = 'professional'; }
    try { saveAll(); } catch (_) { /* best effort */ }
  }, demo);
  await page.waitForTimeout(1200);

  const seeded = await page.evaluate(() => ({
    orders: (typeof printLog !== 'undefined' ? printLog.length : 0),
    machines: (typeof machines !== 'undefined' ? machines.length : 0),
  }));
  ok(seeded.orders > 0, `store seeded with ${seeded.orders} orders`);
  ok(seeded.machines > 0, `store seeded with ${seeded.machines} machines (the crash needed these)`);

  for (const tab of TABS) {
    const before = errors.length;
    await page.evaluate((t) => window.KhaytShell?.switchTab?.(t), tab);
    await page.waitForTimeout(700);
    const newErrors = errors.slice(before);
    ok(newErrors.length === 0, `${tab} renders clean${newErrors.length ? ': ' + newErrors[0] : ''}`);
  }

  // Each theme renders its own dashboard; a crash in one is invisible from the others.
  for (const theme of ['workbench', 'command', 'vivid']) {
    const before = errors.length;
    await page.evaluate((t) => {
      settings.designTheme = t;
      if (typeof applyDesignSettings === 'function') applyDesignSettings();
      if (typeof initialRender === 'function') initialRender();
    }, theme);
    await page.waitForTimeout(900);
    const newErrors = errors.slice(before);
    ok(newErrors.length === 0, `theme "${theme}" renders clean${newErrors.length ? ': ' + newErrors[0] : ''}`);
  }

  ok(errors.length === 0, `no page errors across ${TABS.length} screens and 3 themes`);
  console.log('\n✅ Populated-screens smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  try { if (app) await app.close(); } catch { /* already closed */ }
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch { /* best effort */ }
}
process.exit(failed ? 1 : 0);
