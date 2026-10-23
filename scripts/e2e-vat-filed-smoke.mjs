/**
 * E2E smoke — a VAT return marked filed keeps its figures.
 *
 * The owner's rule (2026-10-22, lib/vat-periods.js): once the shop marks a
 * return period filed, a later cancel of one of its invoices is not taken out
 * of that period — it is adjusted in the first open period. Here: an invoice
 * in last quarter, the quarter marked filed on the VAT return card, the
 * invoice cancelled today; the filed quarter still reads its VAT and the
 * current quarter carries the reversal. Un-filing asks first and keeps what
 * was filed; filing again offers to restore it. Settings → VAT sets the
 * frequency, and the return picker follows it (months for a monthly filer).
 *
 * Run: npm run test:e2e:vatfiled
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  // The VAT return card is in the Professional analytics, as its export is.
  await window.evaluate(() => { settings.mode = 'professional'; applyMode(); saveAll(); });
  const seeded = await window.evaluate(() => {
    settings.enableVat = true;
    settings.tax = { country: 'SA', name: 'VAT', mode: 'inclusive', rates: [{ name: 'VAT', percent: 15 }] };
    settings.vatFilingFrequency = 'quarterly';
    delete settings.vatFiledPeriods;
    // An invoice dated in the quarter before this one.
    const V = KhaytVatPeriods;
    const today = V.localDay(new Date().toISOString());
    const cur = V.periodKeyOf(today, 'quarterly');
    const prevDay = (() => { const b = V.periodBounds(cur); const d = new Date(Date.UTC(+b.from.slice(0, 4), +b.from.slice(5, 7) - 1, 0)); return d.toISOString().slice(0, 10); })();
    const last = V.periodKeyOf(prevDay, 'quarterly');
    const day = V.periodBounds(last).from.slice(0, 8) + '15';
    printLog.push({ id: 'INV-vat-1', date: day, status: 'completed', price: 115, project: 'Filed job', parts: [], currency: '' });
    saveAll();
    return { cur, last };
  });

  await switchTab(window, 'analytics-tab');
  await window.evaluate(() => applyAnalyticsModeView());
  await window.waitForSelector(`#vatFilingSection .vat-filing-row[data-period="${seeded.last}"]`);
  const picker = await window.evaluate(() => [...document.querySelectorAll('#vatReturnPeriod option')].map((o) => o.value));
  ok(picker[0] === 'year' && picker.includes(seeded.cur), `the return picker lists this year and its quarters (${picker.join(', ')})`);

  await window.click(`#vatFilingSection button[data-act="vat-file"][data-period="${seeded.last}"]`);
  const mark = await window.evaluate((k) => KhaytVatPeriods.markFor(settings, k), seeded.last);
  ok(mark && mark.totals && Math.abs(mark.totals.vat - 15) < 0.01, `"Mark as filed" records what the return held (VAT ${mark && mark.totals && mark.totals.vat})`);
  const row = await window.evaluate((k) => document.querySelector(`#vatFilingSection .vat-filing-row[data-period="${k}"]`).innerText, seeded.last);
  ok(/Filed/.test(row) && /Mark as not filed/.test(row), `the row says Filed (${row.replace(/\s+/g, ' ')})`);

  // Cancel the invoice today.
  await window.evaluate(() => updateStatus('INV-vat-1', 'cancelled'));
  await window.waitForTimeout(300);
  const after = await window.evaluate(({ last, cur }) => {
    const c = KhaytPnl.vatCorrections(printLog, { settings, clients, currencies: typeof CURRENCIES !== 'undefined' ? CURRENCIES : undefined });
    const inP = (k, x) => { const b = KhaytVatPeriods.periodBounds(k); return x.day >= b.from && x.day <= b.to; };
    const sum = (k) => c.filter((x) => inP(k, x)).reduce((s, x) => s + x.vat, 0);
    return { lastAdj: sum(last), curAdj: sum(cur), cancelledAt: printLog.find((o) => o.id === 'INV-vat-1').cancelledAt };
  }, seeded);
  ok(!!after.cancelledAt, `the cancel is stamped with its day (${after.cancelledAt})`);
  ok(Math.abs(after.lastAdj - 15) < 0.01, `the filed quarter keeps its 15.00 VAT after the cancel (correction +${after.lastAdj.toFixed(2)} over the book's 0)`);
  ok(Math.abs(after.curAdj + 15) < 0.01, `the reversal (−15.00) lands in the open quarter (${after.curAdj.toFixed(2)})`);

  // Un-filing asks, and keeps the snapshot.
  await window.click(`#vatFilingSection button[data-act="vat-unfile"][data-period="${seeded.last}"]`);
  await window.waitForSelector('.modal');
  const ask = await window.evaluate(() => document.querySelector('.modal').innerText);
  ok(/as not filed\?/.test(ask) && /forgets what you filed/.test(ask), 'un-filing asks first');
  await window.click('.modal [data-act="save"]');
  const unfiled = await window.evaluate((k) => ({ filed: KhaytVatPeriods.isFiled(settings, k), kept: (settings.vatUnfiledPeriods || []).some((r) => r.period === k) }), seeded.last);
  ok(!unfiled.filed && unfiled.kept, 'un-filed, with what was filed kept aside');

  // Filing again offers to restore it.
  await window.click(`#vatFilingSection button[data-act="vat-file"][data-period="${seeded.last}"]`);
  await window.waitForSelector('.modal');
  const refile = await window.evaluate(() => document.querySelector('.modal').innerText);
  ok(/again\?/.test(refile) && /Restore what you filed/.test(refile), 'filing again offers to restore what was filed');
  await window.click('.modal [data-act="save"]');
  const restored = await window.evaluate((k) => KhaytVatPeriods.markFor(settings, k), seeded.last);
  ok(restored && restored.filedAt === mark.filedAt && Math.abs(restored.totals.vat - 15) < 0.01, 'and restoring brings back the same filed return');

  // Settings → VAT: the frequency, saved through the shared settings edit.
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="invoice"]');
  await window.waitForSelector('#set_vatFilingFrequency');
  await window.evaluate(() => loadSettingsIntoForm());
  const disabled = await window.evaluate(() => document.getElementById('set_vatFilingFrequency').disabled);
  ok(!disabled, 'the frequency can be set while VAT is on');
  await window.selectOption('#set_vatFilingFrequency', 'monthly');
  await window.evaluate(() => saveSettingsFromPanel());
  await window.waitForTimeout(300);
  ok(await window.evaluate(() => settings.vatFilingFrequency === 'monthly'), 'Save stores a monthly filer');
  await switchTab(window, 'analytics-tab');
  await window.evaluate(() => renderAnalytics());
  const months = await window.evaluate(() => [...document.querySelectorAll('#vatReturnPeriod option')].map((o) => o.value));
  ok(months.slice(1).every((k) => /^\d{4}-\d{2}$/.test(k)) && months.length > 1, `the return picker now lists months (${months.slice(1, 4).join(', ')}…)`);
  const quarterStillFiled = await window.evaluate((k) => KhaytVatPeriods.isFiled(settings, k), seeded.last);
  ok(quarterStillFiled, 'a quarter filed before the switch stays filed');

  // A manager reads Settings but may not change them, and filing is a
  // settings write: the card's buttons are off and the action refuses.
  const mgr = await window.evaluate((k) => {
    operators.push({ id: 'e2e-mgr', name: 'Manager', roleKey: 'manager' });
    settings.operatorLockEnabled = true;
    settings.activeOperatorId = 'e2e-mgr';
    applyOperatorPermissions();
    renderAnalytics();
    const btns = [...document.querySelectorAll('#vatFilingSection button[data-act]')];
    const before = JSON.stringify(settings.vatFiledPeriods);
    setVatPeriodFiled(k, false);
    const out = { n: btns.length, allOff: btns.every((b) => b.disabled), unchanged: JSON.stringify(settings.vatFiledPeriods) === before };
    settings.operatorLockEnabled = false;
    applyOperatorPermissions();
    renderAnalytics();
    return out;
  }, seeded.last);
  ok(mgr.n > 0 && mgr.allOff && mgr.unchanged, `a manager cannot mark or un-mark a return (${mgr.n} buttons off, marks unchanged)`);

  // Arabic.
  await window.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); renderAnalytics(); });
  const ar = await window.evaluate(() => document.getElementById('vatFilingSection').innerText);
  ok(/إقرارات ضريبة القيمة المضافة/.test(ar) && !/pnl\./.test(ar), 'the card is translated');

  console.log('e2e-vat-filed: ok (mark filed records the return; a later cancel lands in the open period; un-file asks and keeps it; re-file restores; monthly picker)');
} catch (err) {
  failed = true;
  console.error('e2e-vat-filed FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
