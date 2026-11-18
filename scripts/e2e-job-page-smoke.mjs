/**
 * E2E: the job page (S1 · desktop M4, read side; Figma 74:387 and 95:422),
 * with real clicks. Sample data only.
 *
 *   - Jobs › a job's ⋯ › Open page shows the job: header, stage pill, the
 *     next step pinned (primary filled), the stage track, parts, money,
 *     activity — all worded from lib/order-next-step.js.
 *   - Start printing moves the job (through the app's own status rule) and the
 *     page redraws with the next step after it.
 *   - A quote: Send quote is primary, Take job is beside it, and Paid and
 *     Owing read "—".
 *   - Back closes the page; the old job editor is untouched.
 *
 * Run: npm run test:e2e:jobpage
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
// The job page cards (S1 step 4): a photo and two attached files on disk, and
// a stand-in for the system Trash (main.js honours KHAYT_E2E_TRASH_DIR only in
// an unpackaged build), so Remove can be seen to MOVE the file, not delete it.
const userData = makeUserDataDir();
const trashDir = path.join(userData, 'trash-stand-in');
process.env.KHAYT_E2E_TRASH_DIR = trashDir;
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
fs.mkdirSync(path.join(userData, 'order-photos'), { recursive: true });
fs.mkdirSync(path.join(userData, 'order-files'), { recursive: true });
fs.writeFileSync(path.join(userData, 'order-photos', 'JP-CARDS-0-a.png'), Buffer.from(PNG, 'base64'));
fs.writeFileSync(path.join(userData, 'order-files', 'JP-CARDS-a.stl'), 'solid a\nendsolid a\n');
fs.writeFileSync(path.join(userData, 'order-files', 'JP-CARDS-b.stl'), 'solid b\nendsolid b\n');
const { electronApp, window } = await launchApp(userData);
let failed = false;

const openPage = async (id) => {
  await switchTab(window, 'logs-tab');
  await window.click(`.row-more-btn[data-id="${id}"]`);
  await window.click(`.row-actions-menu[data-for="${id}"] [data-act="job-page"]`);
  await window.waitForSelector('#jobPage:not([hidden]) .jp-title', { timeout: 5_000 });
};
const shot = async (name) => { if (process.env.E2E_SHOTS) await window.locator('#jobPage').screenshot({ path: `${process.env.E2E_SHOTS}/${name}.png` }); };
const text = (sel) => window.evaluate((s) => document.querySelector(s)?.innerText || '', sel);

try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.mode = 'professional'; settings.currency = 'SAR'; settings.enableVat = false;
    KhaytShell.applyMode();
    clients.push({ id: 'C-JP', nameEn: 'Sara Example', nameAr: 'سارة مثال', phone: '+966500000000' });
    const job = (id, over) => Object.assign({
      id, jobNumber: id, status: 'pending', clientId: 'C-JP', client: 'Sara Example', currency: 'SAR',
      date: '2026-11-12', project: 'Dragon ' + id, price: 340, paidAmount: 100, paidAt: '2026-11-12T09:00:00Z',
      material: 'PLA', dueDate: '2099-01-10',
      statusHistory: [{ status: 'quote', at: '2026-11-10T08:00:00Z' }, { status: 'pending', at: '2026-11-12T08:00:00Z' }],
      parts: [{ name: 'dragon-v2.stl', material: 'PLA', color: 'red', qty: 2, printWeight: 450, printTime: 3.5, baseCost: 80 }],
    }, over || {});
    printLog.unshift(
      job('JP-PENDING'),
      job('JP-QUOTE', { status: 'quote', paidAmount: 0, paidAt: null, dueDate: null, statusHistory: [{ status: 'quote', at: '2026-11-13T08:00:00Z' }] }),
      // Taken in USD at 3.75: its part's 75 SAR of cost is 20 USD.
      job('JP-QC', { status: 'qc', statusHistory: [{ status: 'qc', at: '2026-11-12T08:00:00Z' }] }),
      job('JP-DONE', { status: 'completed', statusHistory: [{ status: 'completed', at: '2026-11-12T08:00:00Z' }] }),
      // Re-priced from 2,000 to 2,120 after its 50% deposit proforma was sent
      // (Figma 96:1067): the deposit is 60 short, the unsent balance follows.
      job('JP-MS', { price: 2120, paidAmount: 1000, editHistory: [{ id: 'e', at: '2026-10-14T09:00:00Z', fields: { price: { from: 2000, to: 2120 } } }],
        milestoneInvoices: [{ id: 'MS-1', label: 'Deposit', percentage: 50, amount: 1000, issuedAt: '2026-10-08' },
          { id: 'MS-2', label: 'Balance', percentage: 50, amount: 1000, issuedAt: null }] }),
      job('JP-CARDS', {
        printPhotos: [{ thumb: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', filename: 'JP-CARDS-0-a.png', source: 'shop' }],
        attachedFiles: [{ filename: 'JP-CARDS-a.stl', originalName: 'arm.stl', size: 18 }, { filename: 'JP-CARDS-b.stl', originalName: 'clip.stl', size: 18 }],
      }),
      job('JP-TIMES', { status: 'completed', materialDeducted: true, printingStartedAt: '2026-11-17T08:00:00.000Z', completedAt: '2026-11-17T12:00:00.000Z',
        statusHistory: [{ status: 'completed', at: '2026-11-17T12:00:00.000Z' }] }),
      job('JP-USD', { currency: 'USD', fxRate: 3.75, price: 40, paidAmount: 0, paidAt: null, parts: [{ name: 'hook.stl', material: 'PLA', qty: 3, printWeight: 30, printTime: 1, baseCost: 75 }] }),
    );
    operators.push({ id: 'OP-N', name: 'Noura', active: true });
    saveAll();
    return flushSave();
  });

  // ── A pending job ────────────────────────────────────────────────────────
  await openPage('JP-PENDING');
  ok((await text('#jobPage .jp-title')).includes('Dragon JP-PENDING'), 'the page shows the job\'s name');
  ok(await window.evaluate(() => !document.querySelector('.row-actions-menu.open')), 'the ⋯ menu it came from is closed');
  ok(/Sara Example/.test(await text('#jobPage .jp-head')), 'with the customer under it');
  ok((await text('#jobPage .jp-steps .btn.primary')).trim() === 'Start printing', 'the next step is pinned: Start printing, filled');
  ok(await window.isVisible('#jobPage .jp-track-step.is-current'), 'the stage track marks where the job is');
  ok(/dragon-v2\.stl/.test(await text('#jobPage .jp-grid')) && /450 g/.test(await text('#jobPage .jp-grid')), 'parts are listed with their weight');
  await shot('job-page-pending');
  const moneyText = await text('#jobPage .jp-grid .jp-card:nth-child(2)');
  ok(/340/.test(moneyText) && /100/.test(moneyText) && /240/.test(moneyText), 'money: price 340, paid 100, owing 240');
  ok(/Markup/.test(moneyText) && !/Margin/.test(moneyText) && /Cost/.test(moneyText), 'with cost and markup (Turki: the % is a markup on cost)');
  // baseCost is the part's whole line (×2 already in it): the page multiplied
  // it by the quantity again and showed 160 (pre-release review, Nov 16).
  ok(/Cost[^\n]*\n\s*80[.,]00/.test(moneyText) && !/160/.test(moneyText), 'the cost is the parts\' cost as stored (80), not ×qty again');
  ok(/Moved to/.test(await text('#jobPage')), 'activity lists the moves');

  // A save elsewhere (here: a payment written and saved) shows on the open page.
  await window.evaluate(() => { const o = printLog.find((x) => x.id === 'JP-PENDING'); o.paidAmount = 150; saveAll(); });
  await window.waitForFunction(() => /190/.test(document.querySelector('#jobPage .jp-grid .jp-card:nth-child(2)')?.innerText || ''), null, { timeout: 5_000 });
  ok(true, 'a save elsewhere redraws the open page (owing now 190)');

  await window.click('#jobPage .jp-steps .btn.primary');
  await window.waitForFunction(() => /Mark printed/.test(document.querySelector('#jobPage .jp-steps .btn.primary')?.innerText || ''), null, { timeout: 5_000 });
  ok(await window.evaluate(() => printLog.find((o) => o.id === 'JP-PENDING').status) === 'printing', 'Start printing moved the job to Printing');
  ok(true, 'and the page now offers Mark printed');

  await window.click('#jobPage [data-jp="back"]');
  ok(await window.evaluate(() => document.getElementById('jobPage').hidden), 'Back closes the page');

  // ── A quote ──────────────────────────────────────────────────────────────
  await openPage('JP-QUOTE');
  ok((await text('#jobPage .jp-steps .btn.primary')).trim() === 'Send quote', 'a quote: Send quote is the next step');
  ok(/Take job/.test(await text('#jobPage .jp-steps')), 'Take job is beside it');
  const qMoney = await text('#jobPage .jp-grid .jp-card:nth-child(2)');
  await shot('job-page-quote');
  ok(/Paid\s*—/.test(qMoney) && /Owing\s*—/.test(qMoney), 'Paid and Owing read "—" on a quote');

  // A job taken in USD at 3.75: its parts' 75 SAR of cost reads 20 USD.
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-USD');
  const usdMoney = await text('#jobPage .jp-grid .jp-card:nth-child(2)');
  ok(/Cost[^\n]*\n[^\n]*20[.,]00/.test(usdMoney) && !/75[.,]00/.test(usdMoney), 'a USD job shows its SAR cost in USD (75 / 3.75 = 20)');
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-QUOTE');

  // ── The steps that ask: the desktop's own dialogs, not the old editor (S1) ──
  const closeModal = async () => { await window.click('.modal [data-act="cancel"]'); await window.waitForSelector('.modal', { state: 'detached', timeout: 5_000 }); };
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-QC');
  await window.click('#jobPage [data-jp-step="fail_check"]');
  await window.waitForSelector('.modal #qcFailReason', { state: 'visible', timeout: 5_000 });
  ok(true, 'Failed check opens the inspection-failure dialog');
  await closeModal();
  await window.click('#jobPage [data-jp-step="hold"]');
  await window.waitForSelector('.modal #holdReasonInput', { state: 'visible', timeout: 5_000 });
  await window.fill('.modal #holdReasonInput', 'Waiting for the customer’s file');
  await window.click('.modal [data-act="save"]');
  await window.waitForFunction(() => printLog.find((o) => o.id === 'JP-QC').status === 'on_hold', null, { timeout: 5_000 });
  ok(await window.evaluate(() => printLog.find((o) => o.id === 'JP-QC').holdReason) === 'Waiting for the customer’s file', 'Hold asks why and puts the job on hold with that reason');
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-DONE');
  await window.click('#jobPage [data-jp-step="ship"]');
  await window.waitForSelector('.modal #shipCarrier', { state: 'visible', timeout: 5_000 });
  ok(await window.evaluate(() => !!document.querySelector('.modal #shipTracking')), 'Ship opens the shipping dialog (carrier and tracking), not the job editor');
  await closeModal();
  // ── Milestones after a re-price (Turki, Nov 17; Figma 96:1067) ─────────
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-MS');
  const ms = await text('#jobPage .jp-milestones');
  ok(/no longer add up to the price/.test(ms) && /stays exactly as you sent it/.test(ms), 'the banner says the milestones no longer add up, and a sent proforma stays');
  ok(/1,?060\.00\s*SAR:\s*60\.00\s*SAR short/.test(ms), 'the sent deposit shows what it is now short (60)');
  ok(/1,?000\.00\s*SAR\s*→\s*1,?060\.00\s*SAR/.test(ms) && /2,?000\.00\s*SAR\s*of\s*2,?120\.00\s*SAR/.test(ms), 'the unsent balance shows old → new, and the total says 2,000 of 2,120');
  // Update moves only the unsent one.
  await window.click('#jobPage [data-jp="ms-refresh"]');
  const after = await window.evaluate(() => printLog.find((o) => o.id === 'JP-MS').milestoneInvoices.map((m) => [m.id, m.amount, !!m.issuedAt]));
  ok(JSON.stringify(after) === JSON.stringify([['MS-1', 1000, true], ['MS-2', 1060, false]]), 'Update moved the unsent balance to 1,060 and left the sent deposit at 1,000');
  ok(!(await window.evaluate(() => !!document.querySelector('#jobPage [data-jp="ms-refresh"]'))), 'with nothing unsent left at its old share, the Update button is gone');
  // Send the difference: a new proforma for 60, sent at once (the print path is stubbed here).
  await window.evaluate(() => { window.generateMilestoneInvoice = async (id, m) => { m.issuedAt = '2026-11-18'; saveAll(); }; });
  await window.click('#jobPage [data-jp="ms-diff"]');
  await window.waitForFunction(() => printLog.find((o) => o.id === 'JP-MS').milestoneInvoices.length === 3, null, { timeout: 5_000 });
  const diff = await window.evaluate(() => printLog.find((o) => o.id === 'JP-MS').milestoneInvoices[2]);
  ok(diff.kind === 'difference' && diff.forMilestoneId === 'MS-1' && diff.amount === 60 && diff.issuedAt, 'Send updated proforma added a 60 proforma for the deposit, and sent it');
  await window.waitForFunction(() => !/no longer add up/.test(document.querySelector('#jobPage .jp-milestones')?.innerText || ''), null, { timeout: 5_000 });
  ok(true, 'once both are done, the banner is gone and the card is the plain list');
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-QUOTE');

  // The old editor is still there, from the page's Edit.
  await window.click('#jobPage [data-jp="edit"]');
  await window.waitForSelector('.modal', { state: 'visible', timeout: 5_000 });
  ok(true, 'Edit opens the existing job editor');

  // ── Cards: photos, files, comments, connected apps (S1 step 4, Figma 103:1531) ──
  // The editor Edit opened above closes first.
  await window.click('.modal [data-act="cancel"]');
  await window.waitForSelector('.modal', { state: 'detached', timeout: 5_000 });
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-CARDS');
  ok(await window.evaluate(() => !document.querySelector('#jobPage .jp-apps')), 'with connectors off, the Connected apps card renders nothing');
  ok(await window.isVisible('#jobPage .jp-photos .jp-photo img'), 'the photo shows in the Photos card');
  await window.click('#jobPage [data-jpc="rm-photo"]');
  await window.waitForSelector('.modal [data-act="ok"]', { state: 'visible', timeout: 5_000 });
  const askPhoto = await window.textContent('.modal');
  ok(/Trash/.test(askPhoto) && /get it back/.test(askPhoto), 'Remove asks first, and says the photo goes to the Trash, where it can be got back');
  await window.click('.modal [data-act="ok"]');
  await window.waitForFunction(() => (printLog.find((o) => o.id === 'JP-CARDS').printPhotos || []).length === 0, null, { timeout: 5_000 });
  ok(fs.existsSync(path.join(trashDir, 'JP-CARDS-0-a.png')) && !fs.existsSync(path.join(userData, 'order-photos', 'JP-CARDS-0-a.png')),
    'the photo file was MOVED to the Trash, not deleted');
  await window.click('#jobPage [data-jpc="rm-file"][data-i="0"]');
  await window.waitForSelector('.modal [data-act="ok"]', { state: 'visible', timeout: 5_000 });
  await window.click('.modal [data-act="ok"]');
  await window.waitForFunction(() => printLog.find((o) => o.id === 'JP-CARDS').attachedFiles.length === 1, null, { timeout: 5_000 });
  ok(fs.existsSync(path.join(trashDir, 'JP-CARDS-a.stl')) && !fs.existsSync(path.join(userData, 'order-files', 'JP-CARDS-a.stl')), 'an attached file goes to the Trash too');
  // A Trash that refuses (here: a folder already where the file would go).
  fs.mkdirSync(path.join(trashDir, 'JP-CARDS-b.stl', 'blocker'), { recursive: true });
  await window.click('#jobPage [data-jpc="rm-file"][data-i="0"]');
  await window.waitForSelector('.modal [data-act="ok"]', { state: 'visible', timeout: 5_000 });
  await window.click('.modal [data-act="ok"]');
  await window.waitForFunction(() => /can.t be recovered/.test(document.querySelector('.modal')?.innerText || ''), null, { timeout: 5_000 });
  ok(true, 'when the Trash refuses, it asks again, saying the file can\'t be recovered');
  await window.click('.modal [data-act="ok"]');
  await window.waitForFunction(() => printLog.find((o) => o.id === 'JP-CARDS').attachedFiles.length === 0, null, { timeout: 5_000 });
  ok(!fs.existsSync(path.join(userData, 'order-files', 'JP-CARDS-b.stl')), 'and only then deletes it for good');
  await window.fill('#jobPage .jp-comments #commentInput', 'Matte finish on the arm');
  await window.click('#jobPage .jp-comments #btnPostComment');
  await window.waitForFunction(() => (printLog.find((o) => o.id === 'JP-CARDS').comments || []).length === 1, null, { timeout: 5_000 });
  ok(/Matte finish on the arm/.test(await text('#jobPage .jp-comments')), 'a comment posted on the page is saved and shown');

  // ── Step 5: operator, actual times, More, pay link and profit (Figma 105:1571) ──
  await window.click('#jobPage [data-jp="back"]');
  await openPage('JP-TIMES');
  await window.selectOption('#jobPage [data-jp-op]', 'OP-N');
  await window.waitForFunction(() => printLog.find((o) => o.id === 'JP-TIMES').operatorId === 'OP-N', null, { timeout: 5_000 });
  ok(true, 'the operator picked in the header is saved through the shared rule');
  ok(await window.evaluate(() => !!document.querySelector('#jobPage .qpl-line-host') && !!document.querySelector('#jobPage .jp-profit')), 'the Money card carries the pay-link line and the profit block');
  await window.click('#jobPage .jp-more > summary');
  ok(await window.isVisible('#jobPage [data-jp="status-save"]') && await window.isVisible('#jobPage [data-jp="status-open"]'), 'More offers Save status page and Open saved status page');
  await window.click('#jobPage .jp-more > summary');
  const timesBefore = await window.evaluate(() => JSON.parse(JSON.stringify(printLog.find((o) => o.id === 'JP-TIMES'))));
  await window.click('#jobPage [data-jp="time-edit"][data-k="completedAt"]');
  const local = await window.evaluate(() => isoToLocalInput('2026-11-17T11:30:00.000Z'));
  await window.fill('#jobPage [data-jp-time="completedAt"]', local);
  await window.click('#jobPage [data-jp="time-save"]');
  await window.waitForFunction(() => printLog.find((o) => o.id === 'JP-TIMES').completedAt === '2026-11-17T11:30:00.000Z', null, { timeout: 5_000 });
  const timesAfter = await window.evaluate(() => JSON.parse(JSON.stringify(printLog.find((o) => o.id === 'JP-TIMES'))));
  delete timesBefore.completedAt; delete timesAfter.completedAt; delete timesBefore.operatorId; delete timesAfter.operatorId; delete timesAfter.editHistory; delete timesBefore.editHistory;
  ok(JSON.stringify(timesAfter) === JSON.stringify(timesBefore), 'correcting the completion time moves only the time: status, deduction and the rest are as they were');
  await window.click('#jobPage [data-jp="time-edit"][data-k="completedAt"]');
  await window.fill('#jobPage [data-jp-time="completedAt"]', await window.evaluate(() => isoToLocalInput(new Date(Date.now() + 3 * 86400000).toISOString())));
  await window.click('#jobPage [data-jp="time-save"]');
  await window.waitForFunction(() => /in the future/.test(document.querySelector('#toastContainer')?.innerText || ''), null, { timeout: 5_000 });
  ok((await window.evaluate(() => printLog.find((o) => o.id === 'JP-TIMES').completedAt)) === '2026-11-17T11:30:00.000Z', 'a time in the future is refused, and the stamp stays');

  console.log('e2e-job-page: ok');

} catch (err) {
  failed = true;
  console.error('e2e-job-page FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
