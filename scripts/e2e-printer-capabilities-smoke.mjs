/**
 * E2E smoke — Figma page 134 on Windows/Linux: a printer card draws only the
 * controls its model has (CAP1), Edit printer's Accessories (CAP2), and what a
 * Snapmaker U1's heads hold with the Link dialog (U1-1, U1-2).
 *
 * No printer answers here: the poll cache and the U1's spool tags are set in
 * the window, as the poll and hub:printer-spool-tags would set them. Every
 * rule underneath (lib/printer-capabilities.js, lib/rfid-tray.js) is real.
 *
 * Run: npm run test:e2e:capabilities   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs'; import path from 'node:path';
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shot = process.env.KHAYT_SHOT_DIR || '';
const api = (type, host) => ({ type, host, serial: 'SN', accessCode: 'x' });
const machines = [
  { id: 'X1', name: 'Bambu X1C', color: '#3b82f6', printerModelName: 'Bambu Lab X1 Carbon', printerApi: api('bambu', '192.0.2.10') },
  { id: 'P1', name: 'Bambu P1P', color: '#f97316', printerModelName: 'Bambu Lab P1P', printerApi: api('bambu', '192.0.2.11') },
  { id: 'U1', name: 'Workshop U1', color: '#22c55e', printerModelName: 'Snapmaker U1', printerApi: { type: 'moonraker', host: '192.0.2.12' } },
  { id: 'RS', name: 'Resin bay', color: '#a855f7', printerModelName: 'Elegoo Saturn 4 Ultra', printerApi: { type: 'moonraker', host: '192.0.2.13' } },
  { id: 'A1', name: 'Garage A1', color: '#eab308', printerModelName: 'Bambu Lab A1', printerApi: api('bambu', '192.0.2.14') },
];
const inventory = [
  { id: 'S2', material: 'PLA', colourVariant: 'Black', color: '#080A0D', weight: 640, cost: 80, brand: 'Snapmaker', materialType: 'fdm' },
];
const now = Date.now();
const cache = {
  X1: { state: 'printing', progress: 62, lastUpdated: now },
  P1: { state: 'printing', progress: 18, lastUpdated: now },
  U1: { state: 'idle', lastUpdated: now, loaded: [
    { slot: 0, hex: '#080A0D', material: 'PLA' }, { slot: 1, hex: '#FFFFFF', material: 'PETG' }, { slot: 2, hex: '#D62828', material: 'PLA' } ] },
  RS: { state: 'printing', progress: 40, lastUpdated: now },
  A1: { state: 'idle', lastUpdated: now },
};
const tags = [
  { vendor: 'Snapmaker', manufacturer: 'Snapmaker', material: 'PLA', sub: '', colours: ['#080A0D'], weightG: 1000, diameterMm: 1.75, lengthM: null, sku: null, official: true },
  { vendor: 'Snapmaker', manufacturer: 'Snapmaker', material: 'PETG', sub: '', colours: ['#FFFFFF'], weightG: 1000, diameterMm: 1.75, lengthM: null, sku: null, official: true },
  null, null,
];

// U1-3 (Figma 134:359): four jobs whose U1 recorded a time-lapse.
const VIDEO = 'bracket-kit-plate-2_20261121111000.mp4';
const lapse = (bytes) => ({ machineId: 'U1', video: VIDEO, bytes, at: '2026-11-21T11:10:00Z' });
function lapseJobs() {
  const job = (id, extra) => Object.assign({ id, date: '2026-11-21', status: 'completed', machineId: 'U1', project: 'Bracket kit ' + id, client: 'Sample client', price: 120, parts: [] }, extra);
  return [
    job('A1F', { printerTimelapse: lapse(42 * 1048576) }),
    job('A20', { printerTimelapse: lapse(42 * 1048576), attachedFiles: [{ filename: 'A20-timelapse-x.mp4', originalName: VIDEO, size: 42 * 1048576, kind: 'timelapse', from: { machineId: 'U1', video: VIDEO } }] }),
    job('A21', { printerTimelapse: lapse(310 * 1048576) }),
  ];
}

async function run(lang) {
  const dir = makeUserDataDir();
  fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify({
    settings: { firstRun: false, firstRunDone: true, bizName: 'Sample Shop', lang, mode: 'professional' },
    machines: machines.map((m) => (m.id === 'U1' ? { ...m, headSpools: { 0: 'S2' } } : m)), printLog: lapseJobs(), clients: [], inventory,
  }));
  const { electronApp, window } = await launchApp(dir);
  try {
    await dismissWizard(window);
    await window.setViewportSize({ width: 1300, height: 1000 });
    const paint = async () => {
      await window.evaluate((arg) => {
        Object.assign(machineStatusCache, arg.cache);
        setHeadTags('U1', arg.tags);
        renderMachines();
      }, { cache, tags });
      await window.waitForTimeout(250);
    };
    await window.evaluate((l) => { if (typeof i18n !== 'undefined') i18n.set(l); openSettingsSection('printers'); }, lang);
    await paint();
    const card = (id) => window.evaluate((i) => {
      const row = document.querySelector(`.machine-row[data-machine-id="${i}"]`);
      return { switches: [...row.querySelectorAll('[data-printer-switch]')].map((s) => s.dataset.control),
        drop: !!row.querySelector('[data-act="printer-drop"]'), speed: !!row.querySelector('select[data-printer-control]'),
        note: row.querySelector('.mcap-note')?.innerText || '' };
    }, id);
    const x1 = await card('X1'), p1 = await card('P1'), u1 = await card('U1'), rs = await card('RS'), a1 = await card('A1');
    ok(x1.switches.includes('light') && x1.speed, `${lang}: X1C has its light and speed`);
    ok(!p1.switches.includes('light') && p1.note.length > 0, `${lang}: P1P has no light switch, and says why`);
    ok(u1.switches.includes('chamber-light') && !u1.drop, `${lang}: the U1 has its chamber light (idle, so no job controls)`);
    ok(!rs.drop && !rs.switches.length, `${lang}: a resin printer has no "skip an object"`);
    ok(a1.switches.includes('light') && a1.note.length > 0, `${lang}: an A1's light is shown, with "not known"`);
    if (lang === 'en') ok(/Edit printer › Accessories/.test(p1.note), 'the P1P note says where to fix it');

    // U1-1: what each head holds.
    const heads = await window.evaluate(() => [...document.querySelectorAll('[data-machine-heads="U1"] .mhead')].map((h) => h.innerText.replace(/\s+/g, ' ')));
    ok(heads.length === 4, `${lang}: four heads listed`);
    if (lang === 'en') {
      ok(/Tool 1 · PLA · Snapmaker/.test(heads[0]) && /Linked to Snapmaker PLA Black · 640 g left/.test(heads[0]) && /Change…/.test(heads[0]), 'tool 1: its tag, and the spool it is linked to');
      ok(/No spool in your inventory matches this tag/.test(heads[1]), 'tool 2: a tag that matches nothing says so');
      ok(/Set on the printer · no tag/.test(heads[2]) && /Not linked to a spool/.test(heads[2]), 'tool 3: set on the printer, no tag');
      ok(/Tool 4 · Nothing loaded/.test(heads[3]), 'tool 4: nothing loaded');
    }
    if (shot) await (await window.$('#machinesList')).screenshot({ path: path.join(shot, `p134-cap1-u1-1-${lang}.png`) });

    // U1-2: link tool 2 to a new spool filled in from its tag.
    await window.click('[data-head-link="U1"][data-head="1"]');
    await window.waitForSelector('.mlink-opt', { timeout: 5000 });
    const opts = await window.evaluate(() => [...document.querySelectorAll('.mlink-opt')].map((o) => o.querySelector('input').value));
    ok(opts.includes('__new'), `${lang}: the dialog offers "Add as a new spool" when nothing matches`);
    if (shot) await (await window.$('.modal')).screenshot({ path: path.join(shot, `p134-u1-2-${lang}.png`) });
    // U1-3: the job page's Files card says where the time-lapse is.
    const lapseOf = async (id) => {
      await window.evaluate((i) => { document.querySelector('.modal [data-act="cancel"]')?.click(); openJobPage(i); }, id);
      await window.waitForSelector('#jobPage .jp-lapse', { timeout: 8000 });
      return window.evaluate(() => document.querySelector('#jobPage .jp-lapse').innerText.replace(/\s+/g, ' '));
    };
    const found = await lapseOf('A1F');
    if (lang === 'en') ok(/Time-lapse found on Workshop U1/.test(found) && /42 MB/.test(found) && /Keep as proof/.test(found), 'U1-3: found on the printer, nothing copied');
    if (shot) await (await window.$('#jobPage .jp-files')).screenshot({ path: path.join(shot, `p134-u1-3-found-${lang}.png`) });
    const kept = await lapseOf('A20');
    if (lang === 'en') ok(/kept as proof/.test(kept) && /Show/.test(kept) && /Remove/.test(kept), 'U1-3: kept');
    const big = await lapseOf('A21');
    if (lang === 'en') ok(/310 MB · stays on the printer/.test(big) && /Open on printer/.test(big), 'U1-3: too large to keep');
    if (shot) await (await window.$('#jobPage .jp-files')).screenshot({ path: path.join(shot, `p134-u1-3-large-${lang}.png`) });
    if (lang === 'en') {
      // Keep as proof on a printer that does not answer (192.0.2.x): nothing copied, try again.
      await lapseOf('A1F');
      await window.click('#jobPage [data-jpc="lapse-keep"]');
      await window.waitForFunction(() => /Couldn’t reach the printer/.test(document.querySelector('#jobPage .jp-lapse')?.innerText || ''), null, { timeout: 20000 });
      ok(await window.evaluate(() => !!document.querySelector('#jobPage [data-jpc="lapse-keep"]')), 'U1-3: a printer that does not answer: nothing copied, Try again');
      ok(await window.evaluate(() => !(printLog.find((o) => o.id === 'A1F').attachedFiles || []).length), 'and no file was added to the job');
      if (shot) await (await window.$('#jobPage .jp-files')).screenshot({ path: path.join(shot, 'p134-u1-3-offline-en.png') });
    }
    if (lang === 'en') {
      // Back to the printers, and the Link dialog the U1-3 checks closed.
      await window.evaluate(() => { document.querySelector('#jobPage [data-jp="back"]')?.click(); window.KhaytShell?.switchTab?.('settings-tab'); openSettingsSection('printers'); });
      await paint();
      await window.click('[data-head-link="U1"][data-head="1"]');
      await window.waitForSelector('.mlink-opt', { timeout: 5000 });
      await window.click('[data-act="save"]');
      await window.waitForTimeout(300);
      const after = await window.evaluate(() => ({ head: machines.find((m) => m.id === 'U1').headSpools, n: inventory.length, made: inventory[inventory.length - 1], s2: inventory.find((x) => x.id === 'S2') }));
      ok(after.n === 2 && after.made.material === 'PETG' && after.head[1] === after.made.id, 'Link adds the spool from the tag and links tool 2 to it');
      ok(after.head[0] === 'S2' && after.s2.weight === 640 && after.s2.cost === 80 && after.s2.color === '#080A0D', 'tool 1 and the existing spool are untouched');
      await window.keyboard.press('Escape');   // the spool editor opened for its price
      await window.waitForTimeout(200);

      // One spool, one head (lib/head-spools.js, #2733; the Baby U1 on Nov 27):
      // tool 1's spool is moved to tool 3, so its tag now reads there. Linking
      // it to tool 3 takes it out of tool 1; before, it stayed in both.
      await window.evaluate((t) => { setHeadTags('U1', [null, t[1], t[0], null]); renderMachines(); }, tags);
      await window.waitForTimeout(250);
      await window.click('[data-head-link="U1"][data-head="2"]');
      await window.waitForSelector('.mlink-opt', { timeout: 5000 });
      ok(await window.evaluate(() => document.querySelector('input[name="mlinkPick"]:checked')?.value) === 'S2', 'tool 3: its tag picks the spool that was in tool 1');
      await window.click('[data-act="save"]');
      await window.waitForTimeout(300);
      const moved = await window.evaluate(() => machines.find((m) => m.id === 'U1').headSpools);
      ok(moved['2'] === 'S2' && !('0' in moved), 'linking it to tool 3 took it out of tool 1');
      ok(moved['1'] === after.made.id, 'tool 2 keeps its own spool');
      const shown = await window.evaluate(() => [...document.querySelectorAll('[data-machine-heads="U1"] .mhead')].map((h) => h.innerText.replace(/\s+/g, ' ')));
      ok(!/Linked to Snapmaker PLA Black/.test(shown[0]) && /Linked to Snapmaker PLA Black/.test(shown[2]), 'the card shows it in tool 3 only');
      // Colours by NAME, never a code (lib/colour-name.js, #2736; Turki, Nov 27).
      ok(shown.every((h) => !/#[0-9a-f]{6}/i.test(h)), 'no head row shows a hex code');
      ok(/Tool 3 · PLA · Snapmaker · Black/.test(shown[2]), 'tool 3 names its colour');
      const row = await window.evaluate((id) => {
        if (typeof renderInventory === 'function') renderInventory();
        const r = document.querySelector(`tr[data-inv-id="${id}"]`);
        return r ? { text: r.innerText.replace(/\s+/g, ' '), label: r.getAttribute('aria-label') || '', swatchHidden: r.querySelector('.colour-swatch')?.getAttribute('aria-hidden') } : null;
      }, after.made.id);
      ok(row && /White/.test(row.text) && !/#[0-9a-f]{6}/i.test(row.text + row.label), 'a spool with no colour name of its own reads "White" in the inventory, not its code');
      ok(row && row.swatchHidden === 'true', 'its swatch is hidden from a screen reader; the name is read');
      await window.evaluate((t) => { setHeadTags('U1', t); renderMachines(); }, tags);   // back as it was, for CAP2
      await window.waitForTimeout(250);

      // CAP2: tick the P1P's kit in Edit printer; its card gains the light.
      await window.click('.machine-row[data-machine-id="P1"] [data-act="edit-mach"]');
      await window.waitForSelector('#machAccessories [data-addon]', { timeout: 5000 });
      if (shot) await (await window.$('.modal')).screenshot({ path: path.join(shot, 'p134-cap2-en.png') });
      await window.click('#machAccessories [data-addon="bambu-p1-camera-led"]');
      await window.click('[data-act="save"]');
      await window.waitForTimeout(300);
      await paint();
      const p1b = await card('P1');
      ok(p1b.switches.includes('light') && !p1b.note, 'with the kit ticked, the P1P card has its light switch');
      const noAcc = await window.evaluate(async () => { openMachineEditor('X1'); await new Promise((r) => setTimeout(r, 200)); const n = document.querySelectorAll('#machAccessories [data-addon]').length; document.querySelector('[data-act="cancel"]')?.click(); return n; });
      ok(noAcc === 0, 'a model with no known accessories has no Accessories section');
    }
  } finally { await electronApp.close(); }
}

let failed = false;
try { await run('en'); await run('ar'); console.log('\ne2e-printer-capabilities: ok'); }
catch (e) { failed = true; console.error('\ne2e-printer-capabilities FAILED: ' + (e && e.message || e)); }
process.exit(failed ? 1 : 0);
