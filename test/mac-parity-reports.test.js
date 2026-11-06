'use strict';
/**
 * The reports lifted out of the desktop's screens so the Mac can draw them:
 * profit by filament, material usage, the two P&L trend charts, the
 * completion heatmap, the box-form VAT return, the shopping list and the
 * test-print log.
 *
 * ── HOW "UNCHANGED" IS HELD ───────────────────────────────────────────────
 *
 * Each `old…` function below is the inline code the desktop ran before the
 * lift, copied verbatim (only the globals it read became parameters). The
 * shared module must give the same answer on the same book — figure for
 * figure, and for the VAT return, byte for byte.
 *
 * The one deliberate change is the filament report's revenue: the screen
 * split the gross `price`, and now splits what the order EARNED
 * (`orderEarnedBase`, net of tax). The module's default is still the gross
 * price, which is how the old answer is pinned here; the screens pass
 * `revenueOf`.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
const Money = require('../lib/order-money.js');
const Tax = require('../lib/tax.js');
require('../lib/vat-periods.js');
const Pnl = require('../lib/pnl-report.js');
const Status = require('../lib/order-status.js');
const Deduction = require('../lib/order-deduction.js');
const FR = require('../lib/filament-report.js');
const Trend = require('../lib/pnl-trend.js');
const Heat = require('../lib/completion-heatmap.js');
const VatReturn = require('../lib/vat-return.js');
const Reorder = require('../lib/reorder.js');
const TP = require('../lib/test-prints.js');

// ── A book with something in every branch ─────────────────────────────────
const inventory = [
  { id: 'S1', material: 'PLA', color: '#ff0000', weight: 120, reorderPoint: 200, reorderQty: 1000,
    usageHistory: [{ date: '2026-10-03', weightUsed: 40 }, { date: '2026-09-12', weightUsed: 25.5 },
      { date: '2025-01-01', weightUsed: 999 }] },
  { id: 'S2', material: 'PETG', color: '#00ff00', weight: 900, supplierId: 'SUP1',
    usageHistory: [{ date: '2026-08-30', weightUsed: 100 }] },
  { id: 'S3', material: 'PLA', color: '#0000ff', weight: 50, reorderPoint: 100, supplierId: 'SUP2',
    usageHistory: [{ date: '2026-10-20', weightUsed: 12 }] },
  { id: 'S4', material: 'TPU', weight: 10, reorderPoint: 300, lot: 'L-7', poId: 'PO1', usageHistory: [] },
  { id: 'S5', weight: 0, reorderPoint: 50, usageHistory: [{ date: '2026-10-01', weightUsed: 0 }] },
];
const orders = [
  { id: 'o1', status: 'completed', date: '2026-09-01', price: 115, paidAmount: 115,
    actualPrintTime: 3, actualWeight: 60, printTime: 2.5,
    parts: [{ filamentId: 'S1', material: 'PLA', baseCost: 30, spoolCost: 80, spoolWeight: 1000, printWeight: 40, printTime: 1.5 },
            { filamentId: 'S2', baseCost: 10, spoolCost: 100, spoolWeight: 1000, printWeight: 20, printTime: 1 }] },
  { id: 'o2', status: 'delivered', date: '2026-10-02', price: 230,
    parts: [{ material: 'ASA', printWeight: 0 }, { filamentId: 'S1', printWeight: 10, spoolCost: 80 }] },
  { id: 'o3', status: 'printing', date: '2026-10-05', price: 50, parts: [{ filamentId: 'S3', printWeight: 5 }] },
  { id: 'o4', status: 'completed', date: '2026-10-06', price: 0, parts: [] },
  { id: 'o5', status: 'completed', date: '2026-10-07', price: 60, parts: [{ filamentId: 'GONE', printWeight: 3, spoolCost: 50 }] },
];

// ── Profit by filament ────────────────────────────────────────────────────
function oldFilament(printLog, inventory) {
  const agg = {};
  printLog
    .filter(o => Status.isFinished(o))
    .forEach(o => {
      const parts = o.parts || [];
      if (parts.length === 0) return;
      const totalBase = parts.reduce((s, p) => s + (+p.baseCost || 0), 0);
      parts.forEach(p => {
        const key = p.filamentId || p.material || 'unknown';
        const filItem = inventory.find(i => i.id === p.filamentId);
        const label = p.material || filItem?.material || key;
        if (!agg[key]) agg[key] = { label, color: filItem?.color || '#888', orderIds: new Set(), revenue: 0, matCost: 0, timePerGrams: [] };
        agg[key].orderIds.add(o.id);
        const revShare = totalBase > 0 ? (+p.baseCost / totalBase) * +o.price : +o.price / parts.length;
        agg[key].revenue += revShare;
        const spoolC = +p.spoolCost || 0;
        const spoolW = Math.max(1, +p.spoolWeight || 1000);
        const pw = +p.printWeight || 0;
        agg[key].matCost += (spoolC / spoolW) * pw;
        if (o.actualPrintTime != null && o.actualWeight != null && o.actualWeight > 0 && o.printTime > 0) {
          const timeShare = (p.printTime / o.printTime) * o.actualPrintTime;
          const weightShare = pw > 0 ? pw : o.actualWeight / parts.length;
          if (weightShare > 0) agg[key].timePerGrams.push(timeShare / weightShare);
        }
      });
    });
  return Object.values(agg).sort((a, b) => b.revenue - a.revenue).map((r) => ({
    label: r.label, color: r.color, orders: r.orderIds.size, revenue: r.revenue, matCost: r.matCost,
    margin: r.revenue > 0 ? ((r.revenue - r.matCost) / r.revenue * 100) : 0,
    avgTPG: r.timePerGrams.length > 0 ? r.timePerGrams.reduce((s, v) => s + v, 0) / r.timePerGrams.length : null,
  }));
}

test('profit by filament: the old screen\'s figures exactly, on the gross price', () => {
  const was = oldFilament(orders, inventory);
  const now = FR.profitByFilament(orders, inventory).map((r) => ({
    label: r.label, color: r.color, orders: r.orders, revenue: r.revenue, matCost: r.matCost,
    margin: r.marginPct, avgTPG: r.avgTimePerGram,
  }));
  assert.deepEqual(now, was);
  assert.ok(was.length >= 3, 'the fixture reaches several filaments');
});

test('profit by filament: revenue is what the caller says an order earned', () => {
  const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
  const rows = FR.profitByFilament(orders, inventory, {
    revenueOf: (o) => Money.orderEarnedBase(o, { settings, clients: [] }),
  });
  // o1 alone carries S2 (a quarter of its base cost): 115 with the 15% out is 100.
  const s2 = rows.find((r) => r.key === 'S2');
  assert.equal(Math.round(s2.revenue * 100) / 100, 25);
  // A printing job earns nothing yet.
  assert.equal(rows.find((r) => r.key === 'S3'), undefined);
});

// ── Material usage ────────────────────────────────────────────────────────
function oldUsage(inventory, months) {
  const materialData = {};
  for (const item of inventory) {
    if (!item.usageHistory || item.usageHistory.length === 0) continue;
    const mat = item.material || 'Unknown';
    if (!materialData[mat]) materialData[mat] = {};
    for (const h of item.usageHistory) {
      const mk = (h.date || '').slice(0, 7);
      if (!months.find(m => m.key === mk)) continue;
      materialData[mat][mk] = (materialData[mat][mk] || 0) + (+h.weightUsed || 0);
    }
  }
  const materials = Object.keys(materialData).filter(mat =>
    Object.values(materialData[mat]).some(v => v > 0)).slice(0, 6);
  const matColors = {};
  for (const mat of materials) {
    const invItem = inventory.find(i => i.material === mat);
    matColors[mat] = invItem?.color || '#5b9cf0';
  }
  const monthTotals = months.map(m => materials.reduce((s, mat) => s + (materialData[mat][m.key] || 0), 0));
  const cells = {};
  for (const mat of materials) for (const m of months) cells[mat + '|' + m.key] = materialData[mat][m.key] || 0;
  return { materials, matColors, maxG: Math.max(...monthTotals, 1), cells };
}

test('material usage: the old chart\'s materials, colours, grams and scale', () => {
  const keys = FR.lastMonths(new Date(2026, 9, 16), 6);
  assert.deepEqual(keys, ['2026-05', '2026-06', '2026-07', '2026-08', '2026-09', '2026-10']);
  const was = oldUsage(inventory, keys.map((key) => ({ key })));
  const now = FR.materialUsage(inventory, keys, { limit: 6 });
  assert.deepEqual(now.materials, was.materials);
  assert.deepEqual(now.colors, was.matColors);
  assert.equal(now.maxGrams, was.maxG);
  for (const mat of now.materials) for (const k of keys) assert.equal(now.grams[mat][k], was.cells[mat + '|' + k]);
  assert.deepEqual(now.materials, ['PLA', 'PETG']);   // TPU used nothing; S5's nothing either
});

test('lastMonths crosses a year end', () => {
  assert.deepEqual(FR.lastMonths(new Date(2027, 1, 3), 3), ['2026-12', '2027-01', '2027-02']);
});

// ── The P&L trend charts ──────────────────────────────────────────────────
test('the trend charts pick the old figures off the P&L rows', () => {
  const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
  const expenses = [{ id: 'e1', date: '2026-09-12', amount: 115, vatAmount: 15, category: 'rent' }];
  const NOW = new Date(2026, 9, 16, 12);
  const rows = Pnl.pnlByPeriod(orders, expenses, { settings, now: NOW, granularity: 'month',
    wasteLog: [{ id: 'w', date: '2026-10-01', cost: 7 }] });
  const months = FR.lastMonths(NOW, 6);
  const byKey = Object.fromEntries(rows.map((r) => [r.period, r]));
  const trend = Trend.monthlyTrend(rows, months);
  months.forEach((m, i) => {
    const rev = byKey[m] ? byKey[m].revenue : 0;
    const exp = byKey[m] ? byKey[m].expenses + (byKey[m].waste || 0) + (byKey[m].depreciation || 0) + (byKey[m].labour || 0) : 0;
    assert.equal(trend[i].revenue, rev);
    assert.equal(trend[i].expenses, exp);
    assert.equal(trend[i].profit, rev - exp);
    const margin = (byKey[m] && byKey[m].marginPct != null) ? byKey[m].marginPct : null;
    assert.equal(Trend.marginTrend(rows, months)[i].marginPct, margin);
  });
  assert.ok(trend.some((r) => r.revenue > 0) && trend.some((r) => r.expenses > 0));
  assert.equal(Trend.marginBand(40), 'good');
  assert.equal(Trend.marginBand(39.9), 'fair');
  assert.equal(Trend.marginBand(19), 'poor');
});

// ── The completion heatmap ────────────────────────────────────────────────
function oldHeat(completed, now) {
  const matrix = Array.from({ length: 7 }, () => Array(12).fill(0));
  completed.forEach(o => {
    try {
      const d = new Date(o.completedAt);
      const week = Math.min(11, Math.floor((now - d.getTime()) / (7 * 86400000)));
      const dow = d.getDay();
      if (week >= 0 && week < 12) matrix[dow][11 - week]++;
    } catch (_) { /* ignore */ }
  });
  const maxVal = Math.max(1, ...matrix.flat());
  const cells = [];
  for (let w = 0; w < 12; w++) for (let d = 0; d < 7; d++) cells.push((0.12 + (matrix[d][w] / maxVal) * 0.85).toFixed(2));
  return { matrix, maxVal, cells, hasData: completed.length >= 5 };
}

test('the heatmap counts what the old grid counted', () => {
  const now = new Date(2026, 10, 6, 15).getTime();
  const day = 86400000;
  const done = [0, 1, 1, 8, 15, 30, 70, 83, 100, -2].map((back, i) => ({
    id: 'h' + i, status: i % 2 ? 'completed' : 'delivered', completedAt: new Date(now - back * day).toISOString(),
  }));
  done.push({ id: 'bad', status: 'completed', completedAt: 'not a date' });
  const was = oldHeat(done, now);
  const heat = Heat.heatmap(done, { now });
  assert.deepEqual(heat.matrix, was.matrix);
  assert.equal(heat.maxVal, was.maxVal);
  assert.equal(heat.hasData, was.hasData);
  const cells = [];
  for (let w = 0; w < 12; w++) for (let d = 0; d < 7; d++) cells.push(Heat.intensity(heat.matrix[d][w], heat.maxVal).toFixed(2));
  assert.deepEqual(cells, was.cells);
  // Unfinished and undated work is not counted.
  assert.equal(Heat.heatmap([{ status: 'printing', completedAt: new Date(now).toISOString() },
    { status: 'completed' }], { now }).jobs, 0);
});

// ── The box-form VAT return ───────────────────────────────────────────────
function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}
function fmtMoney(n) { return (Math.round((+n || 0) * 100) / 100).toFixed(2); }

/** `exportGaztVatReturn`'s body before the lift, its globals made parameters. */
function oldVat({ printLog, expenses, settings, clients, fromDate, toDate, periodTitle, shopName, currencySymbol }) {
  const KhaytPnl = Pnl, KhaytTax = Tax;
  const orderNetRevenueBase = (o) => Money.orderNetRevenueBase(o, { settings, clients });
  const periodOrders = printLog.filter(o => {
    const day = KhaytPnl.taxPointDate(o);
    return KhaytPnl.isTaxPoint(o) && day >= fromDate && day <= toDate;
  });
  const taxProfile = KhaytTax.profileFromSettings(settings);
  const ratePct = taxProfile.rates.reduce((sum, r) => sum + r.percent, 0);
  const vatRegistered = ratePct > 0;
  const taxName = String(taxProfile.name || 'Tax');
  const isSaudiForm = settings.tax ? (settings.tax.country || '') === 'SA' : true;
  const boxNo = (n) => (isSaudiForm ? `Box ${n}` : '');
  let box1 = 0, box2 = 0, box3 = 0;
  for (const o of periodOrders) {
    const gross = orderNetRevenueBase(o);
    if (!gross) continue;
    if (vatRegistered) {
      const t = KhaytTax.computeTax(gross, taxProfile);
      box1 += t.subtotal;
      box3 += t.taxTotal;
    } else {
      box2 += gross;
    }
  }
  let adjSales = 0, adjVat = 0;
  if (vatRegistered && typeof KhaytPnl.vatCorrections === 'function') {
    const corrections = KhaytPnl.vatCorrections(printLog, { settings, clients, currencies: undefined });
    for (const c of corrections) {
      if (!(c.day >= fromDate && c.day <= toDate)) continue;
      box1 += c.sales;
      box3 += c.vat;
      if (c.kind === 'adjustment') { adjSales += c.sales; adjVat += c.vat; }
    }
  }
  const periodExp = (expenses || []).filter(e => e.date >= fromDate && e.date <= toDate);
  const box6 = periodExp.reduce((s, e) => s + (+e.amount || 0), 0);
  const box7 = periodExp.reduce((s, e) => s + (+e.vatAmount || 0), 0);
  const box7Known = periodExp.some(e => +e.vatAmount > 0);
  const netVat = box3 - box7;
  return `<!DOCTYPE html><html><head><meta charset="utf-8">
    <title>${escapeHtml(taxName)} summary — ${escapeHtml(periodTitle)}</title>
    <style>body{font-family:sans-serif;max-width:700px;margin:auto;padding:24px;}
      h1{font-size:18px;} table{width:100%;border-collapse:collapse;margin-top:16px;}
      th{background:#f3f4f6;text-align:left;padding:8px;border:1px solid #ddd;font-size:13px;}
      td{padding:8px;border:1px solid #ddd;font-size:13px;}
      .net{font-weight:700;background:#fef3c7;}
      .warn{margin-top:16px;padding:10px 12px;border:1px solid #f59e0b;background:#fffbeb;font-size:12px;}</style></head>
    <body>
      <h1>${escapeHtml(taxName)} summary — ${escapeHtml(shopName || '')} (${escapeHtml(periodTitle)})</h1>
      <p style="font-size:12px;color:#666;">Period: ${escapeHtml(fromDate)} to ${escapeHtml(toDate)}</p>
      <table>
        <thead><tr><th>Box</th><th>Description</th><th>Amount (${escapeHtml(currencySymbol)})</th></tr></thead>
        <tbody>
          <tr><td>${boxNo(1)}</td><td>Sales at the standard rate (net of ${escapeHtml(taxName)})</td><td>${fmtMoney(box1)}</td></tr>
          <tr><td>${boxNo(2)}</td><td>Sales at zero rate</td><td>${fmtMoney(box2)}</td></tr>
          <tr><td>${boxNo(3)}</td><td>${escapeHtml(taxName)} collected on sales</td><td>${fmtMoney(box3)}</td></tr>
          ${(adjVat || adjSales) ? `<tr><td></td><td>of which: adjustment for a filed period (sales ${fmtMoney(adjSales)})</td><td>${fmtMoney(adjVat)}</td></tr>` : ''}
          <tr><td>${boxNo(6)}</td><td>Total purchases</td><td>${fmtMoney(box6)}</td></tr>
          <tr><td>${boxNo(7)}</td><td>${escapeHtml(taxName)} paid on purchases (recoverable)</td><td>${box7Known ? fmtMoney(box7) : '&mdash;'}</td></tr>
          <tr class="net"><td colspan="2">Net ${escapeHtml(taxName)} payable</td><td>${fmtMoney(netVat)}</td></tr>
        </tbody>
      </table>
      ${box7Known ? '' : `<p class="warn">Khayt does not record ${escapeHtml(taxName)} on expenses, so the
        recoverable line is blank and the net figure assumes nothing is reclaimable. Add your own
        figure before filing.</p>`}
      <p class="warn">This is a summary to transcribe onto the return you file &mdash; not the return
        itself. Khayt applies one rate to every sale, so a shop with mixed or exempt rating must
        split these figures itself.${isSaudiForm ? '' : ' The box numbers on your form will differ.'}</p>
      <p style="font-size:12px;color:#666;margin-top:16px;">${taxProfile.mode === 'inclusive'
        ? `Prices in Khayt include ${escapeHtml(taxName)} at ${escapeHtml(String(ratePct))}%, and sales are shown with it removed.`
        : `Prices in Khayt exclude ${escapeHtml(taxName)}; it is added at ${escapeHtml(String(ratePct))}% and shown separately.`}</p>
    </body></html>`;
}

function newVat(a) {
  const b = VatReturn.boxes(a.printLog, a.expenses, {
    settings: a.settings, clients: a.clients, from: a.fromDate, to: a.toDate,
    revenueOf: (o) => Money.orderNetRevenueBase(o, { settings: a.settings, clients: a.clients }),
  });
  return { b, html: VatReturn.html(b, { shopName: a.shopName, periodTitle: a.periodTitle, currencySymbol: a.currencySymbol }) };
}

const vatBook = {
  printLog: [
    { id: 'v1', status: 'completed', date: '2026-07-10', price: 115 },
    { id: 'v2', status: 'printing', date: '2026-08-05', price: 230 },          // invoiced, not finished
    { id: 'v3', status: 'quote', date: '2026-08-06', price: 999 },             // no invoice yet
    { id: 'v4', status: 'completed', date: '2026-09-20', price: 57.5, voidedAt: '2026-09-21' },
    { id: 'v5', status: 'completed', date: '2026-10-02', price: 115 },         // outside Q3
    { id: 'v6', status: 'completed', date: '2026-06-28', quoteAcceptedAt: '2026-07-02', price: 46 },
  ],
  expenses: [
    { id: 'e1', date: '2026-08-12', amount: 115, vatAmount: 15 },
    { id: 'e2', date: '2026-09-20', amount: 50 },
    { id: 'e3', date: '2026-10-03', amount: 23, vatAmount: 3 },
  ],
  clients: [],
  fromDate: '2026-07-01', toDate: '2026-09-30', periodTitle: 'Q3 2026', shopName: 'Atelier <&> "Ink"', currencySymbol: 'ر.س',
};

for (const [name, settings] of [
  ['a legacy Saudi shop (inclusive 15%)', { currency: 'SAR', enableVat: true, vatRate: 15 }],
  ['a tax-added GST shop (not the Saudi form)', { currency: 'SAR', tax: { name: 'GST', country: 'AU', mode: 'exclusive', rates: [{ id: 'g', label: 'GST', percent: 10 }] } }],
  ['an unregistered shop (zero-rated)', { currency: 'SAR' }],
]) {
  test(`the VAT return is the old document byte for byte: ${name}`, () => {
    const a = Object.assign({}, vatBook, { settings });
    assert.equal(newVat(a).html, oldVat(a));
  });
}

test('the VAT return with no expense VAT recorded leaves box 7 for the shop', () => {
  const a = Object.assign({}, vatBook, { settings: { currency: 'SAR', enableVat: true, vatRate: 15 },
    expenses: [{ id: 'x', date: '2026-08-01', amount: 40 }] });
  const { b, html } = newVat(a);
  assert.equal(b.box7Known, false);
  assert.match(html, /&mdash;<\/td><\/tr>/);
  assert.equal(html, oldVat(a));
  // v1 + v2 + v6 (accepted in July): 115 + 230 + 46 = 391 gross, 340 net, 51 VAT.
  assert.equal(Math.round(b.box1 * 100) / 100, 340);
  assert.equal(Math.round(b.box3 * 100) / 100, 51);
  assert.equal(b.invoices, 3);
});

// ── The shopping list ─────────────────────────────────────────────────────
function oldShopping(low, suppliers, noSupplier, title) {
  const groups = {};
  low.forEach((item) => {
    let supName = '';
    try {
      const price = Reorder.perGramPriceFor(item, suppliers);
      supName = (price && price.supplierName) || '';
    } catch (e) { /* ignore */ }
    if (!supName && item.supplierId) {
      const s = suppliers.find((x) => x.id === item.supplierId);
      supName = (s && s.name) || '';
    }
    if (!supName) supName = noSupplier;
    (groups[supName] = groups[supName] || []).push({
      name: item.material || 'Filament', have: Math.round(+item.weight || 0),
      buy: Math.round(+item.reorderQty || 1000), color: item.color || '#888',
    });
  });
  const supNames = Object.keys(groups).sort();
  const textLines = [title, ''];
  supNames.forEach((sup) => {
    textLines.push(sup);
    groups[sup].forEach((r) => textLines.push(`  • ${r.name}   ${r.have} g → ${r.buy} g`));
    textLines.push('');
  });
  return { order: supNames, groups, text: textLines.join('\n') };
}

test('the shopping list is the old list, grouped and worded the same', () => {
  const suppliers = [
    { id: 'SUP1', name: 'Zeta Filaments' },
    { id: 'SUP2', name: 'Alpha Supply', prices: [{ material: 'TPU', pricePerKg: 120 }] },
  ];
  const isLow = (s) => Deduction.isLowStock(s, {});
  const low = inventory.filter(isLow);
  assert.ok(low.length >= 3, 'the fixture has several low spools');
  const was = oldShopping(low, suppliers, 'No supplier set', 'Shopping list — Shop');
  const groups = Reorder.shoppingList(inventory, suppliers, { isLow, noSupplier: 'No supplier set' });
  assert.deepEqual(groups.map((g) => g.supplier), was.order);
  for (const g of groups) {
    assert.deepEqual(g.items.map(({ id, ...rest }) => rest), was.groups[g.supplier]);
  }
  assert.equal(Reorder.shoppingListText(groups, 'Shopping list — Shop'), was.text);
});

// ── The test-print log ────────────────────────────────────────────────────
test('a test print is written in the desktop\'s fields, and takes its grams off the spool', () => {
  const spool = { id: 'S4', material: 'TPU', weight: 10, lot: 'L-7', poId: 'PO1', usageHistory: [{ date: 'x' }] };
  const input = TP.normalize({ date: '', machineId: '', testType: 'temp_tower', result: '', printTemp: '215',
    bedTemp: 'abc', speed: '', notes: '  tower  ', weightUsed: '4' }, '2026-11-06');
  assert.deepEqual(input, { date: '2026-11-06', machineId: null, testType: 'temp_tower', result: 'good',
    printTemp: 215, bedTemp: null, speed: null, notes: 'tower', weightUsed: 4 });
  const out = TP.addTestPrint([{ id: 'TP0', spoolId: 'S4', date: '2026-01-01' }], spool, input, { id: 'TP1' });
  assert.deepEqual(Object.keys(out.entry), ['id', 'spoolId', 'date', 'machineId', 'testType', 'result',
    'printTemp', 'bedTemp', 'speed', 'notes', 'weightUsed']);
  assert.equal(out.testPrints[0].id, 'TP1');
  assert.equal(out.item.weight, 6);
  assert.deepEqual(out.item.usageHistory[0], { orderId: 'TP1', project: 'Test print (temp_tower)',
    weightUsed: 4, date: '2026-11-06', lot: 'L-7', poId: 'PO1' });
  assert.equal(spool.weight, 10, 'the input spool is not changed');

  // No filament used: the spool is left alone.
  const none = TP.addTestPrint([], spool, TP.normalize({ testType: 'other' }, '2026-11-06'), { id: 'TP2' });
  assert.equal(none.item.weight, 10);
  assert.equal(none.item.usageHistory.length, 1);

  // Deleting puts the grams back; the log is newest first per spool.
  const back = TP.removeTestPrint(out.testPrints, out.item, 'TP1');
  assert.equal(back.item.weight, 10);
  assert.deepEqual(back.testPrints.map((t) => t.id), ['TP0']);
  assert.deepEqual(TP.forSpool([{ id: 'a', spoolId: 'S4', date: '2026-01-01' }, { id: 'b', spoolId: 'S4', date: '2026-03-01' },
    { id: 'c', spoolId: 'S9', date: '2026-04-01' }], 'S4').map((t) => t.id), ['b', 'a']);
  assert.equal(TP.resultTone('excellent'), 'good');
  assert.equal(TP.resultTone('poor'), 'bad');
  assert.equal(TP.resultTone('fair'), 'fair');
});

test('the usage history is capped at 200 lines', () => {
  const spool = { id: 'S', weight: 1000, usageHistory: Array.from({ length: 200 }, (_, i) => ({ date: String(i) })) };
  const out = TP.addTestPrint([], spool, TP.normalize({ weightUsed: 1 }, '2026-11-06'), { id: 'T' });
  assert.equal(out.item.usageHistory.length, 200);
  assert.equal(out.item.usageHistory[0].orderId, 'T');
});
