/**
 * E2E smoke — lot tracing on the desktop, in a real window.
 *
 * A recall is only as good as what got recorded, so this drives a real spool
 * switch (one of the two desktop draws outside lib/order-deduction.js) and then
 * reads it back through the screens a shop would use:
 *
 *   spool history → each row's lot, "Total consumed" ignores a receipt,
 *   "Jobs from lot …" → the recall lists the jobs, failed prints included,
 *   with the client's NAME (desktop jobs carry a clientId), and the lot
 *   picker switches lots. Then once more in Arabic, for raw keys and RTL.
 *
 * Run: npm run test:e2e:lots
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.LOT_SMOKE_SHOTS || '';

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  await window.evaluate(() => {
    clients.push({ id: 'CL-LOT', nameEn: 'Recall Client', nameAr: 'عميل الاستدعاء' });
    inventory.length = 0;
    inventory.push(
      { id: 'SP-A', material: 'PLA', color: 'Red', weight: 900, weightTotal: 1000, lot: '2406-A', poId: 'PO-1',
        usageHistory: [
          { type: 'received', orderId: 'PO-1', weightUsed: -500, date: '2026-10-01', lot: '2406-A', poId: 'PO-1' },
          { orderId: 'J-1', project: 'Bracket', weightUsed: 60, date: '2026-10-02', lot: '2406-A' },
        ] },
      { id: 'SP-B', material: 'PETG', color: 'Blue', weight: 700, weightTotal: 1000, lot: '2410-B', usageHistory: [] },
    );
    printLog.push(
      { id: 'J-1', project: 'Bracket', clientId: 'CL-LOT', status: 'completed', date: '2026-10-02',
        completedAt: '2026-10-02T10:00:00Z',
        materialDrawn: { spools: [{ spoolId: 'SP-A', grams: 60, lot: '2406-A' }] },
        parts: [] },
      { id: 'J-2', project: 'Hinge', clientId: 'CL-LOT', status: 'printing', date: '2026-10-03',
        parts: [{ name: 'Hinge', material: 'PLA' }] },
      { id: 'J-3', project: 'Clip', status: 'printing', date: '2026-10-04', parts: [] },
    );
    wasteLog.push({ id: 'W-1', orderId: 'J-3', spoolId: 'SP-A', weight: 15, date: '2026-10-04',
      drawn: [{ spoolId: 'SP-A', grams: 15, lot: '2406-A' }] });
    saveAll();
  });

  // ---- a real spool switch on J-2, through its own dialog ----
  await window.evaluate(() => openSpoolSwitchModal('J-2'));
  await window.waitForSelector('.ss-spool-sel[data-pi="0"]', { timeout: 5000 });
  await window.selectOption('.ss-spool-sel[data-pi="0"]', 'SP-A');
  await window.fill('.ss-weight-inp[data-pi="0"]', '40');
  await window.click('.ss-add-btn[data-pi="0"]');
  await window.waitForTimeout(200);
  const row = await window.evaluate(() => inventory.find((i) => i.id === 'SP-A').usageHistory[0]);
  ok(row.orderId === 'J-2' && row.weightUsed === 40, `the switch wrote its row (${JSON.stringify(row)})`);
  ok(row.lot === '2406-A' && row.poId === 'PO-1', 'and stamped the spool\'s lot and order on it');
  await window.click('.modal [data-act="cancel"]');
  await window.waitForSelector('.modal', { state: 'detached', timeout: 5000 });

  // The shop relabels the spool afterwards; the recorded rows must not move.
  await window.evaluate(() => { inventory.find((i) => i.id === 'SP-A').lot = '2406-A2'; saveAll(); });

  // ---- spool history ----
  await switchTab(window, 'inventory-tab');
  await window.evaluate(() => openSpoolHistory('SP-A'));
  await window.waitForSelector('#spoolHistLotRecall', { timeout: 5000 });
  const hist = await window.evaluate(() => document.querySelector('.modal').innerText);
  ok(/2406-A2/.test(hist), 'the header shows the spool\'s lot');
  ok((hist.match(/2406-A\b/g) || []).length >= 2, 'each recorded row shows the lot it was taken from');
  // 60 + 40 left the shelf; the 500 g receipt arrived and is not consumption.
  ok(/100g/.test(hist), `Total consumed is 100g, not lowered by the receipt:\n${hist}`);
  ok(!/inv\.(lot|spool)/.test(hist), 'no raw locale key in the history');

  // ---- the recall, from the history's button ----
  await window.click('#spoolHistLotRecall');
  await window.waitForSelector('#lotRecallPick', { timeout: 5000 });
  const picked = await window.evaluate(() => document.querySelector('#lotRecallPick').value);
  ok(picked === '2406-A2', `it opens on the spool's lot (${picked})`);
  // The spool now says 2406-A2, but its recorded draws say 2406-A: pick that.
  await window.selectOption('#lotRecallPick', '2406-A');
  await window.waitForTimeout(100);
  const recall = await window.evaluate(() => ({
    text: document.querySelector('#lotRecallList').innerText,
    links: [...document.querySelectorAll('#lotRecallList .lot-recall-job')].map((a) => a.dataset.orderId),
    opts: [...document.querySelectorAll('#lotRecallPick option')].map((o) => o.value),
  }));
  ok(recall.opts.includes('2410-B') && recall.opts.includes('2406-A'), `every lot is offered (${recall.opts})`);
  for (const id of ['J-1', 'J-2', 'J-3']) ok(recall.links.includes(id), `${id} is in the recall`);
  ok(/Recall Client/.test(recall.text), 'the client column shows the name, not the id');
  ok(!/Project \/ Client/i.test(recall.text), 'the client column is headed Client, not Project / Client');
  ok(/Failed print/.test(recall.text), 'the failed attempt is marked');
  ok(/3 jobs used 115 g/.test(recall.text), `the summary adds up (${recall.text.split('\n')[0]})`);
  if (shots) await window.screenshot({ path: shots + '/lot-recall-en.png' });

  await window.selectOption('#lotRecallPick', '2410-B');
  await window.waitForTimeout(100);
  const empty = await window.evaluate(() => document.querySelector('#lotRecallList').innerText);
  ok(/No job has drawn filament from this lot/.test(empty), 'a lot nothing used says so');

  // A job link closes the window and finds the job in the log.
  await window.selectOption('#lotRecallPick', '2406-A');
  await window.click('.lot-recall-job[data-order-id="J-1"]');
  await window.waitForSelector('.modal', { state: 'detached', timeout: 5000 });
  await window.waitForTimeout(150);
  const search = await window.evaluate(() => logSearchTerm);
  ok(search === 'J-1', `the job opens in the log (${search})`);

  // ---- Arabic ----
  await window.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); });
  await switchTab(window, 'inventory-tab');
  await window.click('#btnLotRecall');
  await window.waitForSelector('#lotRecallPick', { timeout: 5000 });
  await window.selectOption('#lotRecallPick', '2406-A');
  await window.waitForTimeout(100);
  const ar = await window.evaluate(() => ({
    dir: document.documentElement.dir,
    text: document.querySelector('.modal').innerText,
  }));
  ok(ar.dir === 'rtl', 'Arabic lays out right to left');
  const lotDir = await window.evaluate(() => document.querySelector('#lotRecallPick').getAttribute('dir'));
  ok(lotDir === 'auto', 'a lot keeps its own direction inside Arabic (2406-A, not A-2406)');
  ok(!/inv\.lot/.test(ar.text), 'no raw locale key in Arabic');
  ok(/عميل الاستدعاء/.test(ar.text), 'the client\'s Arabic name is used');
  ok(/طباعة فاشلة/.test(ar.text), 'the failed mark is translated');
  if (shots) await window.screenshot({ path: shots + '/lot-recall-ar.png' });

  console.log('e2e-lot-recall: ok (switch stamps the lot → history shows it → recall lists jobs, failures and names, en + ar)');
} catch (err) {
  failed = true;
  console.error('e2e-lot-recall FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
