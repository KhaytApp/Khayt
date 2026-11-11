#!/usr/bin/env node
/**
 * E2E: a connector update that asks for more, on the desktop.
 *
 * A sample connector is installed at 2.0.0 and a verified 2.1.0 is waiting in
 * `settings.connectorUpdates` (written straight onto the store on disk, as a
 * check would — no network). With connectors on (KHAYT_CONNECTORS=1):
 *   - the row shows "Update waiting" and the Settings nav entry a badge,
 *     in steel, and no sheet opens by itself;
 *   - "Review update" opens the sheet: what is NEW first, each line tagged
 *     New / New place, then what was already agreed;
 *   - "Not now" closes it and changes nothing — on disk or on screen;
 *   - "Agree and update" goes through main (lib/plugin-update.js agree): the
 *     entry is 2.1.0 granted what was shown, the old one kept for Revert, the
 *     badge gone — and a later window save does not wind it back.
 *
 *   node scripts/e2e-connector-update-smoke.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const require = createRequire(import.meta.url);
const M = require('../lib/plugin-manifest.js');
require('../lib/plugin-host.js');
const U = require('../lib/plugin-update.js');

const userData = makeUserDataDir();
const storeFile = path.join(userData, 'khayt-store.json');
const fail = (m) => { throw new Error(m); };
const ID = 'app.test.courier';

function sample(version, toA, toB) {
  return {
    khayt: { manifest: 1 }, id: ID, name: { en: 'Sample Courier' }, publisher: 'Test', version,
    domains: ['api.example.com', 'tracking.example.com'],
    actions: [
      { id: 'ship', label: { en: 'Ship' }, placement: 'order', kind: 'post', url: 'https://api.example.com/ship',
        body: { format: 'json-template', template: toA } },
      { id: 'track', label: { en: 'Track' }, placement: 'order', kind: 'post', url: 'https://tracking.example.com/track',
        body: { format: 'json-template', template: toB } },
    ],
    signature: 'A'.repeat(86) + '==',
  };
}
const V1 = sample('2.0.0', { n: '{customer.name}', p: '{customer.phone}', j: '{order.number}' }, { t: '{order.id}' });
const V2 = sample('2.1.0', { n: '{customer.name}', p: '{customer.phone}', a: '{customer.address}', j: '{order.number}' },
  { t: '{order.id}', j: '{order.number}' });
const ENTRY = { id: ID, version: '2.0.0', enabled: true, manifest: V1, granted: M.grantFor(V1), config: {} };

const readDisk = () => JSON.parse(fs.readFileSync(storeFile, 'utf8'));
async function stubReviewed(electronApp) {
  await electronApp.evaluate(({ ipcMain }) => {
    ipcMain.removeHandler('hub:plugin-reviewed');
    ipcMain.handle('hub:plugin-reviewed', (_e, list) => Object.fromEntries((list || []).map((m) => [m.id, !!m.signature])));
  });
}
async function openConnections(window) {
  await window.evaluate(async () => { await loadPluginsEnabled(); await refreshPluginReviewed(); renderPluginSettings(); });
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="connections"]');
  await window.waitForSelector(`.plg-row[data-plugin="${ID}"]`, { timeout: 10000 });
}

let electronApp;
try {
  process.env.KHAYT_CONNECTORS = '1';
  delete process.env.KHAYT_CONNECTOR_UPDATES;

  // ── 1. a book with the sample connector installed at 2.0.0 ──
  {
    const l = await launchApp(userData);
    electronApp = l.electronApp;
    await dismissWizard(l.window);
    await l.window.evaluate((entry) => { settings.mode = 'professional'; applyMode(); settings.plugins = [entry]; saveAll(); return flushSave(); }, ENTRY);
    await l.window.waitForTimeout(500);
    // A window cannot write the update state: only main does.
    await l.window.evaluate(() => { settings.connectorUpdates = { serial: 99, connectors: { x: { skipped: ['1'] } } }; saveAll(); return flushSave(); });
    await l.window.waitForTimeout(500);
    if (readDisk().settings.connectorUpdates) fail('a window save wrote settings.connectorUpdates');
    await electronApp.close();
    electronApp = null;
  }

  // ── 2. a check found 2.1.0 (verified; written as main would write it) ──
  {
    const store = readDisk();
    const NOW = Date.now();
    const index = { khaytIndex: 1, serial: 5, issuedAt: new Date(NOW - 3600e3).toISOString(), expires: new Date(NOW + 30 * 86400e3).toISOString(),
      entries: [{ kind: 'connector', id: ID, version: '2.1.0', url: `https://khaytapp.com/connectors/${ID}/2.1.0.json`, sha256: 'a'.repeat(64) }] };
    const r = U.applyIndex(store.settings, index, { signedBy: 'test-key', nowMs: NOW, platform: 'desktop', appVersion: '9.9.9', schema: 1 }, { [ID]: V2 });
    if (!r.ok || U.stateOf(r.settings, ID).pending?.version !== '2.1.0') fail(`the sample update is not pending: ${JSON.stringify(r.notes)}`);
    store.settings = r.settings;
    fs.writeFileSync(storeFile, JSON.stringify(store));
  }

  const l = await launchApp(userData);
  electronApp = l.electronApp;
  const window = l.window;
  await dismissWizard(window);
  await stubReviewed(electronApp);
  await openConnections(window);

  // ── 3. the badge, steel; nothing opens by itself ──
  const look = await window.evaluate(() => {
    const badge = document.querySelector('.plg-row .plg-update-badge');
    const nav = document.querySelector('.settings-nav-item[data-settings-section="connections"] .plg-nav-badge');
    return {
      badge: badge && badge.textContent, badgeBg: badge && getComputedStyle(badge).backgroundColor,
      nav: nav && nav.textContent, navBg: nav && getComputedStyle(nav).backgroundColor,
      review: !!document.querySelector('.plg-row [data-plugin-act="review-update"]'),
      sheet: !!document.querySelector('.plg-upd-sheet'),
    };
  });
  if (look.badge !== 'Update waiting' || !look.review) fail(`row: ${JSON.stringify(look)}`);
  if (look.nav !== '1') fail(`nav badge: ${JSON.stringify(look)}`);
  const STEEL = ['rgb(58, 70, 88)', 'rgb(237, 240, 244)'];
  if (!STEEL.includes(look.badgeBg) || !STEEL.includes(look.navBg)) fail(`the badge is not steel: ${JSON.stringify(look)}`);
  if (look.sheet) fail('the update sheet opened by itself');

  // ── 4. Review update: NEW first, tagged; then already agreed ──
  await window.click('.plg-row [data-plugin-act="review-update"]');
  await window.waitForSelector('.plg-upd-sheet', { timeout: 10000 });
  const sheet = await window.evaluate(() => {
    const el = document.querySelector('.plg-upd-sheet');
    const sections = [...el.querySelectorAll('section')].map((s) => s.className);
    const fresh = [...el.querySelectorAll('.plg-upd-new li')].map((li) => [li.closest('.plg-upd-host').dataset.host, li.dataset.key, li.dataset.tag, li.querySelector('.plg-upd-tag')?.textContent]);
    const agreed = [...el.querySelectorAll('.plg-upd-agreed li')].map((li) => li.dataset.key);
    return {
      sections, fresh, agreed, agreedTags: el.querySelectorAll('.plg-upd-agreed .plg-upd-tag').length,
      title: el.querySelector('h3').textContent.replace(/\s+/g, ' ').trim(),
      reviewed: el.querySelector('.plg-upd-reviewed')?.textContent,
      sub: el.querySelector('.plg-upd-sub').textContent, lead: el.querySelector('.plg-upd-lead')?.textContent,
      foot: el.querySelector('.plg-upd-foot').textContent,
      buttons: [...el.querySelectorAll('.btn-row button')].map((b) => b.textContent),
      focused: document.activeElement && document.activeElement.dataset.act,
    };
  });
  if (sheet.sections.join() !== 'plg-upd-new,plg-upd-agreed') fail(`sections out of order: ${sheet.sections}`);
  const wantFresh = [['api.example.com', 'customer.address', 'new', 'New'], ['tracking.example.com', 'order.number', 'new_place', 'New place']];
  if (JSON.stringify(sheet.fresh) !== JSON.stringify(wantFresh)) fail(`new lines: ${JSON.stringify(sheet.fresh)}`);
  if (sheet.agreed.join() !== 'customer.name,customer.phone,order.number,order.id' || sheet.agreedTags) fail(`agreed lines: ${JSON.stringify(sheet)}`);
  if (sheet.title !== 'Sample Courier 2.1.0' || sheet.reviewed !== '✓ Reviewed by Khayt') fail(`header: ${JSON.stringify(sheet)}`);
  if (sheet.sub !== 'Updates version 2.0.0') fail(`sub: ${sheet.sub}`);
  if (sheet.lead !== 'This version asks for more than you agreed to. Nothing new is sent until you agree.') fail(`lead: ${sheet.lead}`);
  if (sheet.foot !== 'Version 2.0.0 keeps running until you agree. Keys you entered stay on this device.') fail(`footer: ${sheet.foot}`);
  if (sheet.buttons.join('|') !== 'Not now|Agree and update' || sheet.focused !== 'agree') fail(`buttons: ${JSON.stringify(sheet)}`);

  // ── 5. Not now changes nothing ──
  const before = fs.readFileSync(storeFile, 'utf8');
  const beforeWindow = await window.evaluate(() => JSON.stringify([settings.plugins, settings.connectorUpdates]));
  await window.click('.plg-upd-sheet [data-act="not-now"]');
  await window.waitForTimeout(600);
  if (await window.$('.plg-upd-sheet')) fail('Not now did not close the sheet');
  if (fs.readFileSync(storeFile, 'utf8') !== before) fail('Not now changed the store on disk');
  if (await window.evaluate(() => JSON.stringify([settings.plugins, settings.connectorUpdates])) !== beforeWindow) fail('Not now changed the window\'s book');
  if (!(await window.$('.plg-row .plg-update-badge')) || !(await window.$('.settings-nav-item .plg-nav-badge'))) fail('the badge went away after Not now');

  // ── 6. Agree and update ──
  await window.click('.plg-row [data-plugin-act="review-update"]');
  await window.waitForSelector('.plg-upd-sheet', { timeout: 10000 });
  await window.click('.plg-upd-sheet [data-act="agree"]');
  await window.waitForFunction(() => !document.querySelector('.plg-upd-sheet') && !document.querySelector('.plg-row .plg-update-badge'), null, { timeout: 10000 });
  const check = () => {
    const s = readDisk().settings;
    const e = s.plugins.find((p) => p.id === ID);
    const st = U.stateOf(s, ID);
    if (e.version !== '2.1.0' || e.manifest.version !== '2.1.0') fail(`not updated on disk: ${e.version}`);
    if (JSON.stringify(e.granted) !== JSON.stringify(M.grantFor(V2))) fail('the grant is not what the sheet showed');
    if (st.pending || st.previous?.version !== '2.0.0' || st.updatedFrom !== '2.0.0') fail(`update state: ${JSON.stringify(st)}`);
    if (s.connectorUpdates.serial !== 5) fail('the serial moved');
  };
  check();
  const after = await window.evaluate(() => ({
    version: settings.plugins[0].version, pending: !!(settings.connectorUpdates?.connectors?.['app.test.courier']?.pending),
    nav: !!document.querySelector('.settings-nav-item .plg-nav-badge'),
    revert: !!document.querySelector('.plg-row [data-plugin-act="revert"]'),
  }));
  if (after.version !== '2.1.0' || after.pending || after.nav || !after.revert) fail(`window after agree: ${JSON.stringify(after)}`);
  // A later window save keeps it.
  await window.evaluate(() => { settings.currency = settings.currency || 'SAR'; saveAll(); return flushSave(); });
  await window.waitForTimeout(500);
  check();

  console.log('connector update smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
