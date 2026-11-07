#!/usr/bin/env node
/**
 * E2E: the desktop review's data fixes, each where it used to go wrong.
 *
 *  1. The job editor's actual start/finish stamps survive a save unchanged in
 *     a UTC+3 window (they used to move three hours earlier per save).
 *  2. Bulk "Move to…" goes through the status rules: a job moved to Printing
 *     gets its print stamp, and a job already in the column is left alone.
 *  3. Undo puts the job back where it is NOW, after another order was
 *     unshifted onto the list during the toast.
 *  4. A carrier's tracking update, written to disk by the LAN server, is not
 *     written over by the window's next save.
 *  5. "Test connection" asks one printer and leaves the fleet's polling alone.
 *
 *   node scripts/e2e-review-fixes-smoke.mjs
 */
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';
import fs from 'node:fs';

process.env.TZ = 'Asia/Riyadh';
const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  const offset = await window.evaluate(() => new Date().getTimezoneOffset());
  if (offset !== -180) fail(`window is not on Riyadh time (offset ${offset})`);

  await window.evaluate(() => {
    const job = (id, status, extra) => Object.assign({ id, project: id, date: localDateStr(), status,
      parts: [{ grams: 10, printTime: 1, qty: 1, material: 'PLA' }] }, extra || {});
    printLog.push(
      job('J-edit', 'completed', { printingStartedAt: '2026-11-05T07:00:00.000Z', completedAt: '2026-11-05T10:00:00.000Z' }),
      job('J-bulk1', 'pending'), job('J-bulk2', 'printing', { printingStartedAt: '2026-11-01T08:00:00.000Z' }),
      job('J-undo', 'pending'),
      job('J-ship', 'completed'),
    );
    saveAll();
  });

  // ---- 1. the editor's stamps survive a save ----
  for (let i = 0; i < 2; i++) {
    await window.evaluate(() => openOrderEditor('J-edit'));
    await window.waitForSelector('#oeCompletedAt', { state: 'attached', timeout: 10_000 });
    const shown = await window.$eval('#oeCompletedAt', (el) => el.value);
    if (shown !== '2026-11-05T13:00') fail(`editor shows ${shown} for 10:00Z, wanted 13:00 local`);
    await window.click('.modal-footer [data-act="save"]');
    await window.waitForSelector('#oeCompletedAt', { state: 'detached', timeout: 5_000 });
  }
  const stamps = await window.evaluate(() => { const o = printLog.find((x) => x.id === 'J-edit'); return [o.printingStartedAt, o.completedAt]; });
  if (stamps[0] !== '2026-11-05T07:00:00.000Z' || stamps[1] !== '2026-11-05T10:00:00.000Z') {
    fail(`two saves moved the stamps: ${JSON.stringify(stamps)}`);
  }

  // ---- 2. bulk move through the rules ----
  const bulk = await window.evaluate(() => {
    const r = moveOrdersTo(['J-bulk1', 'J-bulk2'], 'printing');
    const a = printLog.find((x) => x.id === 'J-bulk1');
    const b = printLog.find((x) => x.id === 'J-bulk2');
    return { r, aStatus: a.status, aStarted: a.printingStartedAt || a.timerStart || null,
      bHistory: (b.statusHistory || []).length, bStarted: b.printingStartedAt };
  });
  if (bulk.aStatus !== 'printing' || !bulk.aStarted) fail(`bulk move skipped the rule: ${JSON.stringify(bulk)}`);
  if (bulk.r.moved !== 1 || bulk.bHistory !== 0 || bulk.bStarted !== '2026-11-01T08:00:00.000Z') {
    fail(`a job already printing was moved again: ${JSON.stringify(bulk)}`);
  }

  // ---- 3. Undo by id, after the list moved ----
  const undo = await window.evaluate(async () => {
    const realToast = window.toast;
    let undoFn = null;
    window.toast = (msg, type, ms, opts) => { if (opts && opts.undo) undoFn = opts.undo; };
    try { updateStatus('J-undo', 'post'); } finally { window.toast = realToast; }
    printLog.unshift({ id: 'J-arrived', project: 'arrived', date: localDateStr(), status: 'pending', parts: [] });
    if (!undoFn) return { error: 'no undo offered' };
    undoFn();
    return {
      undone: printLog.find((x) => x.id === 'J-undo').status,
      arrived: printLog.filter((x) => x.id === 'J-arrived').length,
      copies: printLog.filter((x) => x.id === 'J-undo').length,
    };
  });
  if (undo.error) fail(undo.error);
  if (undo.undone !== 'pending' || undo.arrived !== 1 || undo.copies !== 1) fail(`undo hit the wrong job: ${JSON.stringify(undo)}`);

  // ---- 4. a carrier update written to disk survives the next save ----
  await window.evaluate(async () => {
    saveAll();
    await flushSave();   // the book on disk first, as the LAN server would find it
    const store = await window.hubAPI.loadStore();
    const o = store.printLog.find((x) => x.id === 'J-ship');
    o.shippingStatus = 'in_transit';
    o.shippingHistory = [{ status: 'in_transit', at: '2026-11-07T09:00:00Z' }];
    o.shippedAt = '2026-11-07T09:00:00Z';
    await window.hubAPI.saveStore(store);
  });
  await electronApp.evaluate(async ({ BrowserWindow }) => {
    const store = null; // the record as written: the window re-reads it from disk
    BrowserWindow.getAllWindows()[0].webContents.send('lan-order-updated',
      { id: 'J-ship', status: 'completed', shippingStatus: 'in_transit', store });
  });
  await window.waitForFunction(() => printLog.find((x) => x.id === 'J-ship').shippingStatus === 'in_transit', null, { timeout: 5_000 });
  const ship = await window.evaluate(async () => {
    saveAll();
    if (typeof flushSave === 'function') await flushSave();
    const disk = await window.hubAPI.loadStore();
    const o = disk.printLog.find((x) => x.id === 'J-ship');
    return { shippingStatus: o.shippingStatus, shippedAt: o.shippedAt, history: (o.statusHistory || []).length };
  });
  if (ship.shippingStatus !== 'in_transit' || ship.shippedAt !== '2026-11-07T09:00:00Z') fail(`tracking lost on save: ${JSON.stringify(ship)}`);
  if (ship.history !== 0) fail(`a status history line was invented for a tracking update: ${JSON.stringify(ship)}`);

  // ---- 5. Test connection does not replace the fleet's polling ----
  const probe = await window.evaluate(async () => {
    await window.hubAPI.startPrinterPolling([{ id: 'M-fleet', printerApi: { type: 'octoprint', host: '192.168.77.77', apiKey: 'x' } }]);
    const r = await window.hubAPI.probePrinter({ id: 'M-draft', printerApi: { type: 'octoprint', host: '192.168.77.78', apiKey: 'x' } });
    const cache = await window.hubAPI.getPrinterStatus();
    return { probed: !!r, draftInCache: 'M-draft' in cache, fleetInCache: 'M-fleet' in cache };
  });
  if (!probe.probed) fail('probe returned nothing');
  if (probe.draftInCache || !probe.fleetInCache) fail(`probe touched the fleet's cache: ${JSON.stringify(probe)}`);

  console.log('review-fixes smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
