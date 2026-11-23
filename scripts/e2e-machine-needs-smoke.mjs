/**
 * E2E smoke — what a printer needs, under each card on the Machines page
 * (Figma 136:153, N1; lib/printer-needs.js through hub:printer-needs).
 *
 * Main's REAL answer is checked for the stored half (a finished print and a
 * cancelled one waiting at the machine, read from the book's completions with
 * no printer answering). The live half (a printer's own problems) cannot be
 * put into main's poll cache from here, so the rule's own output is drawn
 * through renderMachineNeeds(given). "Bed is clear" stamps the machine.
 *
 * Run: npm run test:e2e:needs   (CI wraps it in xvfb-run)
 */
import fs from 'node:fs'; import path from 'node:path'; import { createRequire } from 'node:module';
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';

const require_ = createRequire(import.meta.url);
const PN = require_('../lib/printer-needs.js');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shot = process.env.KHAYT_SHOT_DIR || '';

const now = Date.now();
const today = new Date(); today.setHours(0, 5, 0, 0);
const yest = new Date(now - 86400000); yest.setHours(18, 40, 0, 0);
// 192.0.2.x: documentation addresses, so main's polls never reach a device.
const machines = [
  { id: 'U1', name: 'Workshop U1', color: '#3b82f6', printerApi: { type: 'moonraker', host: '192.0.2.40' } },
  { id: 'CO', name: 'Bench CORE One', color: '#f97316', printerApi: { type: 'prusalink', host: '192.0.2.41' } },
  { id: 'EN', name: 'Old Ender', color: '#22c55e', printerApi: { type: 'octoprint', host: '192.0.2.42' } },
  { id: 'NB', name: 'New Bambu', color: '#a855f7' },
];
const cache = {
  U1: { state: 'paused', progress: 41, filename: 'plate_1.gcode', lastUpdated: now, problems: [
    { code: 'filament-runout', severity: 'serious', action: 'load-filament', source: 'moonraker', head: 1 },
    { code: 'power-lost', severity: 'info', action: 'resume-on-printer', source: 'moonraker' },
    { code: 'printer-exception', severity: 'serious', action: 'check-printer', source: 'moonraker', message: 'e3 heater not reaching target' } ] },
  CO: { state: 'idle', lastUpdated: now },
  EN: { state: 'idle', error: 'ECONNREFUSED', lastUpdated: now, consecutiveFailures: 9 },
};
const completions = { CO: [{ at: today.getTime(), result: 'finished' }], EN: [{ at: yest.getTime(), result: 'cancelled' }] };

// N2 (Figma 136:208): jobs finished today with one result per run.
const iso = (d) => d.toISOString();
const day = new Date().toISOString().slice(0, 10);
function jobs() {
  const out = [];
  let n = 0;
  const add = (machineId, results) => {
    const runs = results.map((r, i) => ({ machineId, at: iso(new Date(Date.now() - (i + 1) * 3600000)), started: true, ...(r ? { result: r, resultSource: 'printer' } : {}) }));
    out.push({ id: 'J' + (++n).toString(16), date: day, status: 'completed', completedAt: iso(new Date(Date.now() - 3 * 86400000)), machineId, price: 100, project: 'Sample job ' + n, printRuns: runs, parts: [] });
  };
  add('EN', ['finished', 'finished', 'finished', 'finished', 'finished', 'finished', 'finished', 'finished', 'finished', 'finished', 'failed', 'failed', 'failed', 'cancelled']);
  add('U1', Array(39).fill('finished').concat(['failed', 'failed']));
  add('CO', Array(25).fill('finished').concat(['cancelled', 'cancelled', 'cancelled', 'cancelled']));
  add('NB', [null, null, null]);
  return out;
}

async function run(lang) {
  const dir = makeUserDataDir();
  fs.writeFileSync(path.join(dir, 'khayt-store.json'), JSON.stringify({
    settings: { firstRun: false, firstRunDone: true, bizName: 'Sample Shop', lang, mode: 'professional' }, machines, printLog: jobs(), clients: [], inventory: [], printerCompletions: completions,
  }));
  const { electronApp, window } = await launchApp(dir);
  try {
    await dismissWizard(window);
    await window.setViewportSize({ width: 1400, height: 900 });
    await window.evaluate((l) => { if (typeof i18n !== 'undefined') i18n.set(l); openSettingsSection('printers'); renderMachines(); }, lang);
    await window.waitForTimeout(800);
    if (lang === 'en') {
      const real = await window.evaluate(() => window.hubAPI.printerNeeds());
      ok(real.CO && real.CO.waiting[0] && real.CO.waiting[0].reason === 'print-to-take-off', 'main: a finished print waits at the CORE One (stored, no printer answering)');
      ok(real.EN && real.EN.waiting[0] && real.EN.waiting[0].reason === 'bed-to-clear', 'main: a cancelled print\'s leftovers wait at the Ender');
      const shown = await window.evaluate(() => document.querySelector('[data-machine-needs="CO"]').innerText);
      ok(/finished print to take off/.test(shown) && /Bed is clear/.test(shown), 'the CORE One card says so, with Bed is clear');
    }
    const needs = PN.printerNeeds({ machines, cache, polled: PN.polledFrom(cache), completions, orders: [] });
    await window.evaluate((arg) => { Object.assign(machineStatusCache, arg.cache); renderMachines(); return renderMachineNeeds(arg.needs); }, { needs, cache });
    await window.waitForTimeout(200);
    const u1 = await window.evaluate(() => { const e = document.querySelector('[data-machine-needs="U1"]'); return { hidden: e.hidden, rows: e.querySelectorAll('.mn-row').length, text: e.innerText, bdi: e.querySelectorAll('bdi').length }; });
    ok(!u1.hidden && u1.rows === 3, `${lang}: the U1's three problems are listed`);
    ok(u1.bdi === 1 && /e3 heater not reaching target/.test(u1.text), `${lang}: the printer's own message, as it came, in its own direction`);
    if (lang === 'en') {
      ok(/Filament ran out on tool 2/.test(u1.text), 'head 1 reads as tool 2');
      ok(!/Waiting at the machine/.test(u1.text), 'a runout is said once, as a problem, not again as waiting');
      ok(await window.evaluate(() => /Paused/.test(document.querySelector('[data-machine-live="U1"]').innerText)), 'a paused printer says Paused, not Printing');
    }
    if (shot) await (await window.$('#machinesList')).screenshot({ path: path.join(shot, `n1-${lang}.png`) });
    // N2: the Machine P&L table's two new columns.
    await window.evaluate(() => { window.KhaytShell?.switchTab?.('analytics-tab'); renderMachinePL(); });
    await window.waitForTimeout(300);
    const pl = await window.evaluate(() => [...document.querySelectorAll('#machinePLSection tbody tr')].map((tr) => ({
      name: tr.querySelector('strong')?.innerText, prints: tr.querySelector('.mpl-prints')?.innerText, right: tr.querySelector('.mpl-right')?.innerText })));
    const row = (n) => pl.find((r) => r.name === n) || {};
    if (lang === 'en') {
      ok(row('Old Ender').prints === '14 · 3 failed · 1 cancelled' && row('Old Ender').right === '77%', `N2: Old Ender ${JSON.stringify(row('Old Ender'))}`);
      ok(row('Workshop U1').right === '95%' && row('Bench CORE One').right === '100%', 'N2: cancelled prints are left out of the rate');
      ok(row('New Bambu').prints === '3 · not marked yet' && row('New Bambu').right === '—', 'N2: unmarked prints are never a success');
    } else ok(pl.length >= 4 && pl.every((r) => r.prints && r.right), `${lang}: N2 columns filled`);
    if (shot) await (await window.$('#machinePLSection')).screenshot({ timeout: 5000, path: path.join(shot, `n2-${lang}.png`) });
    if (lang === 'en') {
      await window.evaluate(() => openSettingsSection('printers'));
      await window.waitForTimeout(300);
      await window.click('[data-machine-bed-clear="CO"]');
      await window.waitForFunction(() => !!machines.find((m) => m.id === 'CO').bedClearedAt, null, { timeout: 5000 });
      ok(true, 'Bed is clear stamps the machine');
      // The save reaches main a moment later (the window's debounced save, flushed by the click).
      let cleared = false;
      for (let i = 0; i < 25 && !cleared; i++) {
        const after = await window.evaluate(() => window.hubAPI.printerNeeds());
        cleared = after.CO && after.CO.waiting.length === 0;
        if (!cleared) await window.waitForTimeout(200);
      }
      ok(cleared, 'and main stops saying it waits once the save lands');
    }
  } finally { await electronApp.close(); }
}

let failed = false;
try { await run('en'); await run('ar'); console.log('\ne2e-machine-needs: ok'); }
catch (e) { failed = true; console.error('\ne2e-machine-needs FAILED: ' + (e && e.message || e)); }
process.exit(failed ? 1 : 0);
