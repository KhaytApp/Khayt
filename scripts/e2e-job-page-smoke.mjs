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
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const { electronApp, window } = await launchApp(makeUserDataDir());
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
    );
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

  // The old editor is still there, from the page's Edit.
  await window.click('#jobPage [data-jp="edit"]');
  await window.waitForSelector('.modal', { state: 'visible', timeout: 5_000 });
  ok(true, 'Edit opens the existing job editor');

  console.log('e2e-job-page: ok');
} catch (err) {
  failed = true;
  console.error('e2e-job-page FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
