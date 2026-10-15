/**
 * P&L summary — turn a period's orders + expenses into an income-statement
 * summary and a spreadsheet-ready CSV. Pure (no DOM / no currency lookups) so
 * it is unit-testable; the renderer scopes the data to the selected analytics
 * date range, converts to base currency, then hands plain numbers in here.
 */
(function (global) {
  const round2 = (n) => Math.round((+n || 0) * 100) / 100;
  /** Finished work, in both spellings a book can hold. */
  const FINISHED = new Set(['completed', 'delivered']);

  /* ── FILAMENT IS COUNTED WHEN IT IS USED, NOT WHEN IT IS BOUGHT ────────────
   *
   * Receiving a purchase order books the spool as an expense (category
   * `filament`, lib/purchase-orders.js), and a shop can type one in by hand the
   * same way. Once net took the cost of goods out as well (#1623), that spool
   * was paid for twice in the P&L: once as an expense the day it arrived, and
   * again as each job's cost when it was printed — so net understated every
   * shop that recorded what it bought.
   *
   * The maintainer's decision (2026-09-26): accrual. A filament purchase is
   * INVENTORY — money turned into stock on the shelf — and it reaches the P&L
   * as cost of goods when a job uses it. It is left out of operating expenses
   * here and reported beside them as `inventoryPurchases`, so the money is
   * never simply gone from the report. The tax on it is still reclaimable:
   * accrual moves WHEN the cost is recognised, not the VAT position.
   *
   * Filament WASTED on a failed print never becomes a job's cost, so accrual
   * would drop it from the P&L entirely — it was hidden inside the purchase
   * before. So it is a line of its own (the maintainer's decision, same day):
   * each waste-log entry's `cost`, which lib/waste-entry.js and
   * lib/qc-failure.js record net of reclaimable tax, the basis a job is costed
   * on. A job's costBasis is its parts only (lib/order-status.js), so nothing
   * wasted is in cogs already. */
  const wasteCostOf = (w) => Math.max(0, +(w && w.cost) || 0);

  /* ── COST OF GOODS IS WHAT WAS STOCKED ─────────────────────────────────────
   *
   * A job's cost (lib/calculator-cost.js) is built for PRICING: material,
   * extra materials and packaging, plus estimates of machine wear, electricity
   * and labour, plus a failure buffer. The P&L then ALSO took off what the
   * shop actually paid for those — its electricity bills and maintenance
   * (expenses), its wages and rent (fixed costs), its failed prints (the waste
   * line) — so each was counted twice, once as an estimate and once as a bill.
   *
   * The maintainer's decision (2026-09-28), the same principle as filament:
   * in the P&L, cost of goods is only what is INVENTORIED — the job's material,
   * extra materials and packaging. Power, wear and labour stay in pricing and
   * reach the P&L once, as what was paid or depreciated. The buffer goes too:
   * actual failures are the waste line.
   *
   * The share is taken from each part's own costing inputs and applied to the
   * job's FROZEN costBasis, so last year's prices are not re-priced today. A
   * part with no inputs to split (a line priced from a product's unit cost, as
   * the LAN and public-quote paths write) has no known split and keeps its
   * whole cost — exactly as before.
   *
   * A part's own consumables are NOT stock either (the shop's decision,
   * 2026-10-04): bought as an expense, so they are taken back out of the
   * material share here — as a product's components already never enter it
   * (lib/kpi-rows.js orderCost). They stay in every per-job figure (job
   * margin, product profit, profit per hour, the quote), which read the full
   * cost, not this share. */
  function stockShare(order, ctx) {
    const CC = (typeof global !== 'undefined' && global.KhaytCalculatorCost) || null;
    if (!CC || typeof CC.computePartBreakdown !== 'function') return 1;
    const c = ctx || {};
    let whole = 0, stocked = 0;
    for (const p of (order && Array.isArray(order.parts) ? order.parts : [])) {
      if (!p) continue;
      const b = Math.max(0, +p.baseCost || 0);
      if (!b) continue;
      whole += b;
      let br = null;
      const partCtx = { inventory: c.inventory || [], settings: c.settings || {} };
      if (Array.isArray(c.consumables)) partCtx.consumables = c.consumables;
      try { br = CC.computePartBreakdown(p, partCtx); } catch (_) { br = null; }
      const total = br ? (br.material + br.machine + br.labor + br.buffer) : 0;
      // The part's own consumables (magnets, inserts — `part.consumables`) are
      // priced INTO the material bucket, but they are not stock: a consumable
      // purchase is booked as an expense (`other`, lib/purchase-orders.js), so
      // it reaches the P&L once, as what was paid. Left in, every magnet was
      // counted twice. The same figure the breakdown folded in, with the same
      // ctx, so the split cannot drift from it. A part with none: 0, unchanged.
      let cons = 0;
      if (br && typeof CC.partConsumablesCost === 'function') {
        try { cons = Math.max(0, +CC.partConsumablesCost(p, partCtx) || 0); } catch (_) { cons = 0; }
      }
      const stockedMaterial = br ? Math.max(0, br.material - cons) : 0;
      stocked += total > 0 ? b * (stockedMaterial / total) : b;
    }
    return whole > 0 ? stocked / whole : 1;
  }
  const INVENTORY_CATEGORIES = new Set(['filament']);
  const isInventoryPurchase = (e) =>
    !!e && INVENTORY_CATEGORIES.has(String(e.category || '').trim().toLowerCase());

  /* ── A MACHINE IS PAID FOR ONCE: AS ITS DEPRECIATION ──────────────────────
   *
   * A shop that buys a printer can record it twice without meaning to: as an
   * expense (the receipt), and as the machine's purchase price with a
   * depreciation method (lib/depreciation.js). The P&L charged both — the
   * whole price as an expense the day it was paid, and the same price again,
   * spread out, as the depreciation line. A 6,000 printer bought in July took
   * 6,000 + 504 off the quarter's net, when the quarter's cost was 504.
   *
   * The rule: an expense that is the capital purchase of a machine the P&L
   * depreciates is not an operating expense. It is left out of `expenses` and
   * `net` and reported beside them as `capital` ("Equipment bought
   * (depreciated)"), the way filament bought is reported as `inventory` — so
   * the money is never simply missing. Its reclaimable tax is reclaimed all
   * the same, and cash flow (lib/cash-flow.js) is untouched: the money did
   * leave the bank.
   *
   * WHICH EXPENSE IS ONE. Only an expense MATCHED to a depreciated machine
   * (`isCharged`), and each machine claims at most one. Anything unmatched —
   * a dryer, an enclosure, a second printer nobody set depreciation on — is
   * an ordinary operating expense, because then it is the only place that
   * cost reaches the P&L at all. Matched, in this order:
   *
   * 1. An explicit link: the expense's `machineId` names a depreciated
   *    machine. A match whatever its amount or date.
   * 2. The `equipment` category (lib/expense-book.js), what a shop picks for
   *    a machine it bought: the amount, as paid or net of the tax on the
   *    receipt, within 1% of the machine's price, dated within 31 days of its
   *    purchase date either way — a receipt is rarely the same day or the
   *    same figure as what the machine sheet says. The closest wins.
   * 3. The purchase as it is already on disk, filed under `tools` or `other`
   *    before there was an equipment category: the price to the cent (as
   *    paid or net of tax), dated the purchase date exactly. Strict, because
   *    these categories also hold ordinary spending. Nothing is migrated; a
   *    book written before this rule reads correctly the first time it is
   *    opened.
   *
   * A shop that never fills in depreciation has no depreciated machine, so
   * nothing matches and every purchase stays an expense.
   *
   * Filament is stock first: an expense is never both. */
  const CAPITAL_CATEGORIES = new Set(['equipment']);
  const isCapitalCategory = (e) =>
    !!e && CAPITAL_CATEGORIES.has(String(e.category || '').trim().toLowerCase());
  const Dep = () => ((typeof global !== 'undefined' && global.KhaytDepreciation)
    || (typeof require === 'function'
      ? (() => { try { return require('./depreciation.js'); } catch (e) { return null; } })()
      : null));
  /**
   * The expenses that are capital purchases of depreciated machines, as a Set
   * of the expense objects themselves.
   * @param {Array} expenses
   * @param {Array} machines  the book's machines, depreciation settings and all
   * @param {object} [opts]   `{ recentMonthlyHours: { [machineId]: hours } }`
   */
  function capitalPurchases(expenses, machines, opts) {
    const out = new Set();
    const D = Dep();
    if (!D || typeof D.isCharged !== 'function') return out;
    const recent = (opts && opts.recentMonthlyHours) || {};
    const charged = (Array.isArray(machines) ? machines : [])
      .filter((m) => m && m.id && D.isCharged(m, { recentMonthlyHours: recent[String(m.id)] }));
    if (!charged.length) return out;
    const list = (Array.isArray(expenses) ? expenses : []).filter((e) => e && !isInventoryPurchase(e));
    const done = new Set(); // machines that have claimed their one expense
    const claim = (m, e) => { done.add(String(m.id)); out.add(e); };
    const linkOf = (e) => String(e.machineId == null ? '' : e.machineId).trim();

    // 1. An explicit link.
    const byId = new Map(charged.map((m) => [String(m.id), m]));
    for (const e of list) {
      const id = linkOf(e);
      if (id && byId.has(id) && !done.has(id)) claim(byId.get(id), e);
    }

    const dayNo = (v) => {
      const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v || ''));
      return m ? Date.UTC(+m[1], +m[2] - 1, +m[3]) / 86400000 : null;
    };
    const cents = (n) => Math.round((+n || 0) * 100);
    const paidAndNet = (e) => [+e.amount || 0, (+e.amount || 0) - (+e.vatAmount || 0)];
    // An expense linked to some machine is that machine's or nobody's: it is
    // never matched to another one by its amount.
    const free = (e) => !out.has(e) && !linkOf(e);

    // 2. Equipment, near the price and the day; the closest match wins.
    for (const m of charged) {
      if (done.has(String(m.id))) continue;
      const s = D.settingsOf(m);
      const bought = dayNo(s.purchaseDate);
      if (bought === null) continue;
      let best = null, bestScore = Infinity;
      for (const e of list) {
        if (!free(e) || !isCapitalCategory(e)) continue;
        const d = dayNo(e.date);
        if (d === null || Math.abs(d - bought) > 31) continue;
        const off = Math.min(...paidAndNet(e).map((a) => Math.abs(a - s.price) / s.price));
        if (!(off <= 0.01)) continue;
        const score = Math.abs(d - bought) + off * 100;
        if (score < bestScore) { best = e; bestScore = score; }
      }
      if (best) claim(m, best);
    }

    // 3. Any other category: the price to the cent, on the purchase day.
    for (const m of charged) {
      if (done.has(String(m.id))) continue;
      const s = D.settingsOf(m);
      const day = String(s.purchaseDate || '');
      if (!day) continue;
      const hit = list.find((e) => free(e) && !isCapitalCategory(e)
        && String(e.date || '').slice(0, 10) === day
        && paidAndNet(e).some((a) => cents(a) === cents(s.price)));
      if (hit) claim(m, hit);
    }
    return out;
  }

  /* ── LABOUR IS WHAT THE SHOP PAID ITS PEOPLE FOR THE HOURS THEY LOGGED ────
   *
   * The shop's decision (2026-10-07): the time log (`store.timeEntries`, one
   * row per stretch of work — hours × the operator's hourly rate, FROZEN as
   * `cost` when the hours were logged, lib/operators.js) is a cost, and it is
   * a P&L line of its own — "Labour" — not folded into cost of goods or into
   * expenses, so a shop can see what its people cost beside what its material
   * did.
   *
   * WHEN: in the period the hours were WORKED (the entry's `date`, a local day
   * like every other date here). That is how this report already treats every
   * cost that is a payment rather than stock: an expense lands on the day it
   * was paid, waste on the day the print failed, depreciation over the days
   * the machine printed. Cost of goods follows the job only because it is
   * INVENTORY, released when the job ships; an hour of somebody's time is not
   * on a shelf waiting — it was paid for when it was worked, finished job or
   * not. It also means time logged against no job (cleaning, setup, a shift)
   * has a period at all, and it counts: the money was spent.
   *
   * WHICH: the hours on a job follow the job's SCOPE — a voided job, or one
   * the shop marked "not business" (lib/business-scope.js), is out of this
   * report's revenue and cost of goods, and its labour goes with it, so a
   * test print stays a test print all the way down. An entry whose job is no
   * longer in the book, or whose operator was deleted, still counts.
   *
   * NOT IN A JOB'S OWN MARGIN. Per-job figures (job margin, product profit,
   * the quote) read the PRICING cost, which already carries an estimate of
   * labour (lib/calculator-cost.js); putting logged hours in as well would
   * charge the job twice. The P&L is where the estimate is not, and the
   * logged figure is.
   *
   * THE ONE THING THIS CANNOT KNOW: whether the same people's pay is ALSO in
   * the book as an expense or a fixed cost ("Salaries" in the overhead, a
   * "wages" expense). Neither is deduplicated — guessing which hours a salary
   * covered would be inventing the shop's payroll — and a period holding both
   * says so instead (`labourOverlap`), so the shop can take one of them out.
   * A book with no time entries has a labour line of zero and every other
   * figure exactly as before. */
  const labourCostOf = (e) => {
    if (!e || typeof e !== 'object') return 0;
    const hours = +e.hours;
    if (!(hours > 0) || !Number.isFinite(hours)) return 0;
    const frozen = e.cost != null && Number.isFinite(Number(e.cost)) ? Number(e.cost) : null;
    const rate = Number.isFinite(+e.hourlyRate) ? +e.hourlyRate : 0;
    return Math.max(0, frozen != null ? frozen : hours * Math.max(0, rate));
  };
  /** Is this stretch of work inside the report: out with its job, when its job is out. */
  function labourCounts(e, orderById) {
    if (!e || !e.orderId) return true;
    const o = orderById && orderById.get(String(e.orderId));
    if (!o) return true;
    if (o.voidedAt) return false;
    const scope = (typeof global !== 'undefined' && global.KhaytBusinessScope) || null;
    return !(scope && !scope.countsForBusiness(o));
  }
  /* Words a shop uses for its payroll, in the languages Khayt speaks. Matched
   * against an expense's category and description and a fixed cost's name. A
   * false match costs one line of advice; a missed one, money counted twice
   * without a word — so it errs wide. */
  const PAYROLL_WORDS = /salar|wage|payroll|staff|labou?r|employee|\bpay\b|راتب|رواتب|أجور|اجور|موظف|عمالة|lohn|gehalt|personal|salaire|personnel|sueldo|n[oó]mina|maa[sş]|[uü]cret|給|工资|薪/i;
  const looksLikePayroll = (text) => PAYROLL_WORDS.test(String(text || ''));
  /* What an expense says about itself. Both apps write the free text to
   * `note` (lib/expense-book.js); `description` is kept for records written
   * before that. Reading only `description` missed "Staff wages September"
   * typed into either app's form, so labour and the same pay booked as an
   * expense went unflagged. */
  const expenseText = (e) => `${e.category || ''} ${e.note || ''} ${e.description || ''}`;
  /** The fixed costs that read as pay — which a period with labour may be counting twice. */
  const payrollFixedCosts = (settings) => (((settings || {}).fixedCosts) || [])
    .filter((fc) => fc && (+fc.amount || 0) > 0 && looksLikePayroll(fc.name || fc.label));

  /**
   * @param {object} input
   * @param {Array<{revenue:number, cogs:number, vat?:number}>} input.orders base-currency per order
   * @param {Array<{amount:number, category?:string}>} input.expenses base-currency
   * @param {string} [input.label] period label (e.g. "This month")
   * @returns {object} summary with totals + expenses grouped by category
   */
  function computePnl(input) {
    input = input || {};
    const orders = Array.isArray(input.orders) ? input.orders : [];
    const expenses = Array.isArray(input.expenses) ? input.expenses : [];

    let revenue = 0, cogs = 0, vatCollected = 0;
    for (const o of orders) {
      revenue += +o.revenue || 0;
      cogs += +o.cogs || 0;
      vatCollected += +o.vat || 0;
    }
    const byCat = {};
    let expensesTotal = 0, inventoryPurchases = 0, capitalBought = 0;
    // Machines bought that the depreciation line already spreads out — see A
    // MACHINE IS PAID FOR ONCE. A caller that passes no `machines` sees none.
    const capital = capitalPurchases(expenses, input.machines, { recentMonthlyHours: input.recentMonthlyHours });
    for (const e of expenses) {
      const amt = +e.amount || 0;
      if (isInventoryPurchase(e)) { inventoryPurchases += amt; continue; }
      if (capital.has(e)) { capitalBought += amt; continue; }
      const cat = (e.category && String(e.category).trim()) || 'Uncategorized';
      byCat[cat] = (byCat[cat] || 0) + amt;
      expensesTotal += amt;
    }
    let waste = 0;
    for (const w of (Array.isArray(input.waste) ? input.waste : [])) waste += wasteCostOf(w);
    // Machine depreciation for the period, worked out by the caller through
    // lib/depreciation.js (`periodCharges`). The one place machine wear enters
    // the P&L; absent is none, and nothing about an old book changes.
    const depreciation = Math.max(0, +input.depreciation || 0);
    // What the shop's people cost for the hours they logged in the period —
    // see LABOUR above. The caller has already scoped and dated the entries.
    let labour = 0;
    for (const e of (Array.isArray(input.labour) ? input.labour : [])) labour += labourCostOf(e);
    const labourOverlap = labour > 0 && (
      expenses.some((e) => e && !isInventoryPurchase(e) && !capital.has(e) && looksLikePayroll(expenseText(e)))
      // The same test `pnlByPeriod` uses: a payroll-named cost of nothing is
      // not pay, and the CSV warned where the screen did not.
      || payrollFixedCosts({ fixedCosts: input.fixedCosts }).length > 0);
    const grossProfit = revenue - cogs;
    const netProfit = grossProfit - expensesTotal - waste - depreciation - labour;
    return {
      label: input.label || '',
      orderCount: orders.length,
      revenue: round2(revenue),
      cogs: round2(cogs),
      grossProfit: round2(grossProfit),
      grossMargin: revenue > 0 ? Math.round((grossProfit / revenue) * 1000) / 10 : 0,
      expensesTotal: round2(expensesTotal),
      expensesByCategory: Object.keys(byCat).sort((a, b) => byCat[b] - byCat[a])
        .map((category) => ({ category, amount: round2(byCat[category]) })),
      // Filament bought in the period: stock, not an expense. It is in `cogs`
      // as the jobs that use it finish.
      inventoryPurchases: round2(inventoryPurchases),
      // Machines bought that depreciation already spreads out: not in
      // expenses or net — the depreciation line carries them.
      capitalBought: round2(capitalBought),
      // Filament lost to failed prints: a cost, and not in cogs.
      waste: round2(waste),
      // Machines losing value as they print — see lib/depreciation.js.
      depreciation: round2(depreciation),
      // The hours the shop's people logged, at their rate: a line of its own.
      labour: round2(labour),
      labourOverlap,
      vatCollected: round2(vatCollected),
      netProfit: round2(netProfit),
    };
  }

  // Spreadsheet-safe cell: quoted + quote-escaped. Numbers pass through as-is
  // (a leading "-" is a real value); only text gets formula-neutralized.
  function cell(v) {
    if (typeof v === 'number') return '"' + v + '"';
    const s = v == null ? '' : String(v);
    const safe = /^[=+\-@\t\r]/.test(s) ? "'" + s : s;
    return '"' + safe.replace(/"/g, '""') + '"';
  }

  /** Render a computed summary to a two-column CSV (Item, Amount). */
  function pnlToCsv(summary, opts) {
    opts = opts || {};
    const cur = opts.currency || '';
    const L = opts.labels || {};
    const lab = (k, d) => L[k] || d;
    const amtHeader = cur ? `${lab('amount', 'Amount')} (${cur})` : lab('amount', 'Amount');
    const rows = [
      [lab('title', 'P&L summary'), summary.label || ''],
      [lab('item', 'Item'), amtHeader],
      [lab('orders', 'Orders'), summary.orderCount],
      [lab('revenue', 'Revenue'), summary.revenue],
      [lab('cogs', 'Cost of goods sold'), -summary.cogs],
      [lab('gross', 'Gross profit'), summary.grossProfit],
      [lab('gross_margin', 'Gross margin %'), summary.grossMargin],
      ['', ''],
      [lab('opex', 'Operating expenses'), -summary.expensesTotal],
    ];
    for (const e of summary.expensesByCategory) rows.push(['  ' + e.category, -e.amount]);
    if (summary.waste) rows.push([lab('waste', 'Filament wasted (failed prints)'), -summary.waste]);
    if (summary.depreciation) rows.push([lab('depreciation', 'Machine depreciation'), -summary.depreciation]);
    if (summary.labour) rows.push([lab('labour', 'Labour (logged hours)'), -summary.labour]);
    rows.push(['', '']);
    rows.push([lab('vat', 'VAT collected'), summary.vatCollected]);
    rows.push([lab('net', 'Net profit'), summary.netProfit]);
    // Not part of the arithmetic above: filament bought is stock, and reaches
    // net only through cost of goods as it is used. Shown so the money is not
    // simply missing from the report.
    if (summary.inventoryPurchases) {
      rows.push(['', '']);
      rows.push([lab('inventory', 'Filament bought (stock, counted when used)'), summary.inventoryPurchases]);
    }
    // Nor is a machine bought that the depreciation line already spreads out.
    if (summary.capitalBought) {
      if (!summary.inventoryPurchases) rows.push(['', '']);
      rows.push([lab('capital', 'Equipment bought (depreciated)'), summary.capitalBought]);
    }
    return '﻿' + rows.map((r) => r.map(cell).join(',')).join('\r\n');
  }

  /**
   * The shop's quarters: what it earned, what it spent, what it kept.
   *
   * Lifted out of renderer/analytics.js's `renderPnLSection`, which built the
   * whole table inline — so the Mac app had no P&L at all and no way to have
   * one without a second opinion about which orders count.
   *
   * WHAT THE RULES ARE, each of which was a comment on the original:
   *
   * * A VOIDED order is skipped. Voiding keeps `status: 'completed'` by design
   *   (invoicing.js) and only sets `voidedAt`, so a status-only filter books a
   *   cancelled invoice as full revenue AND full VAT collected.
   * * Revenue is `orderNetRevenueBase` — the price less credit notes, in the
   *   shop's own currency.
   * * VAT is `computeTax(...).taxTotal`, not tax extracted from the revenue.
   *   Extracting is right only when prices include tax; computeTax extracts
   *   under inclusive pricing and ADDS under exclusive, which is right either
   *   way.
   * * Fixed overhead applies to EVERY quarter with activity, not just the
   *   current one. Charging it only to the current quarter overstated profit
   *   in every historical quarter, so the present always looked worse than the
   *   past — which invalidates quarter-over-quarter comparison, the table's
   *   whole purpose. The quarter in progress is pro-rated by days elapsed so
   *   it is not charged a full quarter's rent on day three.
   *
   * `ctx`: `{ settings, clients, currencies, now, granularity, wasteLog,
   * machines, recentMonthlyHours, timeEntries, jobs, range }`. `range` is
   * `{ from, to }`, book days (`YYYY-MM-DD`, either end optional) — see A
   * CHOSEN SPAN below; absent, every period in the book is reported exactly
   * as before. `timeEntries` is the
   * labour line (see LABOUR above); `jobs`, the whole book's orders, lets a
   * caller that passes a SLICE of the book as `orders` still leave out the
   * labour on a voided job. `machines` is what the depreciation line
   * is worked out from; a caller that passes none, or a book whose machines
   * carry no `depreciation`, gets `depreciation: 0` and the old net. The siblings
   * are consulted through the globals they assign themselves to, present in
   * both apps. `granularity` is `'quarter'` (the default, and the P&L table)
   * or `'month'` — the same arithmetic per calendar month, with the overhead
   * charged per month and the month in progress pro-rated. Added 2026-09-16
   * so the monthly revenue-against-expenses and margin charts draw from THIS
   * rule rather than from arithmetic of their own beside it.
   *
   * Returns rows newest first: `{ period, orders, revenue, shipping, expenses,
   * fixed, vatCollected, vatReclaimable, vatDue, net, cogs, marginPct }`.
   *
   * `net` = revenue − cogs − expenses − waste − fixed − depreciation −
   * labour, the same arithmetic as `computePnl`'s `netProfit`.
   *
   * `cogs` is what the finished work cost to make — each job's `costBasis`,
   * which `order-new` freezes from its parts — in the shop's currency, and
   * `marginPct` is (revenue − cogs) / revenue × 100, or null where nothing was
   * billed. BLENDED: money accumulated and divided once, never the mean of
   * per-job percentages, because a 100 job at 80% beside a 10,000 job at 10%
   * is a 10.7% month and not a 45% one. Revenue here is net of tax, so the
   * margin is a margin on what the shop kept.
   */
  function pnlByPeriod(orders, expenses, ctx) {
    const c = ctx || {};
    const now = c.now instanceof Date ? c.now : new Date();
    const monthly = c.granularity === 'month';
    const money = (typeof global !== 'undefined' && global.KhaytOrderMoney) || null;
    const tax = (typeof global !== 'undefined' && global.KhaytTax) || null;
    const moneyCtx = { settings: c.settings || {}, clients: c.clients || [] };
    const known = c.currencies || null;
    const profile = tax ? tax.profileFromSettings(c.settings || {}) : null;

    const quarterOf = (dateStr) => {
      const d = new Date(String(dateStr || '') + 'T00:00:00');
      if (isNaN(d)) return null;
      return monthly
        ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`
        : `${d.getFullYear()}-Q${Math.ceil((d.getMonth() + 1) / 3)}`;
    };

    /* ── A CHOSEN SPAN ─────────────────────────────────────────────────────
     *
     * "This month", "last quarter", a custom pair of days: the shop picks the
     * stretch it is asking about and every figure follows it. Records are kept
     * when their own day falls inside it — compared as `YYYY-MM-DD` strings,
     * the book's local days, as lib/date-range.js does — and each period row
     * is charged only the share of the overhead (and of a straight-line
     * machine's depreciation) that lies inside the span. A span shorter than
     * the grain — this month under the quarter view — is one row holding only
     * the span's days, and says so with its `from`/`to`. */
    const span = (c.range && (c.range.from || c.range.to))
      ? { from: String(c.range.from || '').slice(0, 10), to: String(c.range.to || '').slice(0, 10) }
      : null;
    const inSpan = (dateStr) => {
      if (!span) return true;
      const ds = String(dateStr || '').slice(0, 10);
      if (span.from && ds < span.from) return false;
      if (span.to && ds > span.to) return false;
      return true;
    };

    const byQuarter = {};
    const at = (key) => {
      if (!byQuarter[key]) {
        byQuarter[key] = {
          period: key, orders: 0, revenue: 0, shipping: 0, expenses: 0, inventory: 0, capital: 0, waste: 0,
          vatCollected: 0, vatReclaimable: 0, cogs: 0, unpriced: 0, labour: 0, payrollExpense: false,
        };
      }
      return byQuarter[key];
    };

    for (const o of orders || []) {
      // FINISHED BY EITHER SPELLING. `order-status.js` keeps a handed-over
      // job at `completed` and sets `deliveredAt`; books written before that
      // rule hold `status: 'delivered'` outright, and those are finished work
      // too. A P&L that skipped them under-reported every quarter of an
      // older book — the sample shop's own Q3 by thirteen jobs.
      if (!o || !FINISHED.has(o.status) || o.voidedAt) continue;
      // NOT BUSINESS. A test print, a gift, a bracket for the shop's own shelf:
      // `lib/business-scope.js` exists to keep them "OUT of revenue, order
      // counts and reports", and ten reports ask it — this one did not, so a
      // shop that marked its test prints still saw their material in the
      // margin.
      const scope = (typeof global !== 'undefined' && global.KhaytBusinessScope) || null;
      if (scope && !scope.countsForBusiness(o)) continue;
      const key = quarterOf(o.date);
      if (!key || !inSpan(o.date)) continue;
      const row = at(key);
      // WHAT THE CUSTOMER PAID, which is not what the shop earned.
      const charged = money ? money.orderNetRevenueBase(o, moneyCtx, known) : (+o.price || 0);
      // REVENUE IS NET OF TAX. ZATCA and IFRS 15 both treat tax collected on a
      // sale as money held for the government — a liability until it is
      // remitted, and never income. This report showed the charged figure as
      // revenue and subtracted only expenses from it, so an inclusive-VAT shop
      // read its own VAT as profit: 20,664.08 where 17,337.45 was kept, in the
      // quarter it would look at to decide whether it was making money.
      //
      // The accountant export next door has always split it correctly
      // (`vatSplit` in `lib/accounting-export.js`), so the same book answered
      // one way to the shop and another to its accountant.
      //
      // `netOfTax` is mode-aware: an exclusive-VAT shop's price IS the net
      // figure and comes back unchanged, and a shop that is not registered has
      // nothing to take out.
      const revenue = (tax && profile) ? tax.netOfTax(charged, profile) : charged;
      row.orders += 1;
      row.revenue += revenue;
      // Finished, charged nothing, and cost something to make: a gift, a test
      // or a job nobody priced. Counted so the screen can SAY why a margin is
      // negative instead of printing -495.8% and leaving the shop to guess.
      if (!(revenue > 0) && (+o.costBasis || 0) > 0) row.unpriced += 1;
      // What it cost to make, in the shop's currency — `costBasis` is frozen
      // in the ORDER's currency by `order-new`, beside the price it pairs with.
      const cost = (+o.costBasis || 0) * stockShare(o, c);
      row.cogs += money
        ? money.convertToBase(cost, money.orderCurrency(o, moneyCtx, known), moneyCtx)
        : cost;
      row.shipping += money
        ? money.convertToBase(+o.shippingCost || 0, money.orderCurrency(o, moneyCtx, known), moneyCtx)
        : (+o.shippingCost || 0);
      // On what was CHARGED, not on the net figure above — computing tax on a
      // figure the tax has already been taken out of understates it.
      row.vatCollected += (tax && profile) ? tax.computeTax(charged, profile).taxTotal : 0;
    }
    // Machines bought that the depreciation line below already spreads out —
    // see A MACHINE IS PAID FOR ONCE. Judged on the WHOLE expense list and
    // the book's machines; a caller that splits the book into piles (lib/
    // location-pl.js) judges once and hands the answer in as `capitalPurchases`.
    const capital = (c.capitalPurchases instanceof Set)
      ? c.capitalPurchases
      : capitalPurchases(expenses, c.machines, { recentMonthlyHours: c.recentMonthlyHours });
    for (const e of expenses || []) {
      if (!e) continue;
      const key = quarterOf(e.date);
      if (!key || !inSpan(e.date)) continue;
      const paid = +e.amount || 0;
      // THE TAX ON A PURCHASE IS NOT A COST — for a registered shop. It is
      // reclaimed from the authority, so it belongs against the tax collected
      // on sales and not in the profit and loss. A shop that is NOT registered
      // reclaims nothing, and every riyal it paid is a cost.
      //
      // `vatAmount` is what the supplier's invoice says, because that is what a
      // shop has in front of it: rates differ by line, imports and exempt
      // purchases carry none, and a rate typed once would be wrong for the
      // receipt with two of them on it. An expense that does not carry the
      // field — which is every expense recorded before this — reclaims nothing,
      // and nothing about an old book changes.
      const claimable = (tax && profile && profile.rates && profile.rates.length)
        ? Math.min(paid, Math.max(0, +e.vatAmount || 0))
        : 0;
      // Filament is stock, counted as cost of goods when used — see
      // INVENTORY_CATEGORIES. Its tax is reclaimable all the same.
      if (isInventoryPurchase(e)) at(key).inventory += paid - claimable;
      else if (capital.has(e)) at(key).capital += paid - claimable;
      else {
        at(key).expenses += paid - claimable;
        if (looksLikePayroll(expenseText(e))) at(key).payrollExpense = true;
      }
      at(key).vatReclaimable += claimable;
    }
    // Filament lost to failed prints, in the period it failed. A caller that
    // passes no waste log (a host that has not opted in yet) sees no change.
    for (const w of (Array.isArray(c.wasteLog) ? c.wasteLog : [])) {
      if (!w) continue;
      const key = quarterOf(w.date);
      if (!key || !inSpan(w.date)) continue;
      const cost = wasteCostOf(w);
      if (cost > 0) at(key).waste += cost;
    }
    // Labour, in the period it was worked — see LABOUR above. A caller that
    // passes no time log (`timeEntries`) sees no change. `jobs` is the whole
    // book's orders when `orders` is a slice of it (a branch's pile), so an
    // hour on a voided job is still known to be one.
    const labourEntries = Array.isArray(c.timeEntries) ? c.timeEntries : [];
    if (labourEntries.length) {
      const orderById = new Map();
      for (const o of (Array.isArray(c.jobs) ? c.jobs : []).concat(orders || [])) {
        if (o && o.id != null && !orderById.has(String(o.id))) orderById.set(String(o.id), o);
      }
      for (const e of labourEntries) {
        if (!e || !labourCounts(e, orderById)) continue;
        const key = quarterOf(e.date);
        if (!key || !inSpan(e.date)) continue;
        const cost = labourCostOf(e);
        if (cost > 0) at(key).labour += cost;
      }
    }

    // The overhead per period: a quarter's worth, or a month's.
    const fixedPerQuarter = ((c.settings || {}).fixedCosts || [])
      .reduce((s, fc) => s + (+((fc && fc.amount)) || 0), 0) * (monthly ? 1 : 3);
    const payrollOverhead = payrollFixedCosts(c.settings).length > 0;
    const nowQuarter = monthly
      ? `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`
      : `${now.getFullYear()}-Q${Math.ceil((now.getMonth() + 1) / 3)}`;
    const elapsed = (() => {
      const startMonth = monthly ? now.getMonth() : Math.floor(now.getMonth() / 3) * 3;
      const start = new Date(now.getFullYear(), startMonth, 1);
      const end = new Date(now.getFullYear(), startMonth + (monthly ? 1 : 3), 0);
      const total = Math.round((end - start) / 86400000) + 1;
      const done = Math.round((now - start) / 86400000) + 1;
      return Math.max(0, Math.min(1, done / total));
    })();

    // ── MACHINE DEPRECIATION, THE ONE PLACE MACHINE WEAR IS COUNTED ──────
    //
    // The maintainer's decision (2026-09-28): cost of goods is what was
    // inventoried, and a machine's wear reaches the P&L as its depreciation —
    // perHour on the hours it printed in the period, straightLine as its
    // monthly amount pro-rated for the period, the one in progress only up to
    // today (as fixed overhead is). lib/depreciation.js does the arithmetic.
    // Charged to the periods with activity, as fixed overhead is.
    const D = (typeof global !== 'undefined' && global.KhaytDepreciation)
      || (typeof require === 'function'
        ? (() => { try { return require('./depreciation.js'); } catch (e) { return null; } })()
        : null);
    const pad = (n) => String(n).padStart(2, '0');
    const iso = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    /** The whole period's first and last day, and its end Date. */
    const wholeOf = (key) => {
      const y = +key.slice(0, 4);
      const first = monthly ? +key.slice(5, 7) - 1 : (+key.slice(6) - 1) * 3;
      const from = new Date(y, first, 1);
      const end = new Date(y, first + (monthly ? 1 : 3), 0);
      return { from: iso(from), to: iso(end), end };
    };
    /** A period's days cut to the chosen span; the period itself without one. */
    const clipped = (key) => {
      const w = wholeOf(key);
      let from = w.from, to = w.to;
      if (span && span.from && span.from > from) from = span.from;
      if (span && span.to && span.to < to) to = span.to;
      return { from, to };
    };
    const boundsOf = (key) => {
      const w = wholeOf(key);
      const cut = clipped(key);
      let to = iso(key === nowQuarter && now < w.end ? now : w.end);
      if (cut.to < to) to = cut.to;
      return { key, from: cut.from, to };
    };
    // Days between two book days, counted on the calendar (UTC arithmetic on
    // the three numbers, so a clock change inside the span cannot cost a day).
    const dayNo = (s) => Date.UTC(+s.slice(0, 4), +s.slice(5, 7) - 1, +s.slice(8, 10)) / 86400000;
    const today = iso(now);
    /** The share of a period's overhead inside the span, and up to today. */
    const spanShare = (key) => {
      const w = wholeOf(key);
      const cut = clipped(key);
      let to = cut.to;
      if (key === nowQuarter && today < to) to = today;
      if (to < cut.from) return 0;
      return Math.max(0, Math.min(1, (dayNo(to) - dayNo(cut.from) + 1) / (dayNo(w.to) - dayNo(w.from) + 1)));
    };
    const machines = Array.isArray(c.machines) ? c.machines : [];
    const depreciationBy = (D && machines.length)
      ? D.periodCharges(machines, orders, Object.keys(byQuarter).map(boundsOf),
                        { recentMonthlyHours: c.recentMonthlyHours })
      : {};

    return Object.keys(byQuarter).sort().reverse().map((key) => {
      const row = byQuarter[key];
      const fixed = span
        ? fixedPerQuarter * spanShare(key)
        : (key === nowQuarter ? fixedPerQuarter * elapsed : fixedPerQuarter);
      const depreciation = (depreciationBy[key] && depreciationBy[key].total) || 0;
      // Only under a span: which of the period's days the row holds. Without
      // one the row is the whole period and the output is as it always was.
      const days = span ? clipped(key) : null;
      return {
        period: key,
        ...(days ? { from: days.from, to: days.to } : {}),
        orders: row.orders,
        revenue: round2(row.revenue),
        shipping: round2(row.shipping),
        expenses: round2(row.expenses),
        // Filament bought this period, net of reclaimable tax: stock, not an
        // expense, so it is not in `net` — `cogs` carries it when it is used.
        inventory: round2(row.inventory),
        // A machine bought this period, net of reclaimable tax, that the
        // depreciation line spreads out: not in `expenses` or `net`.
        capital: round2(row.capital),
        // Filament lost to failed prints: a cost, and not in cogs.
        waste: round2(row.waste),
        fixed: round2(fixed),
        // Machines losing value, per lib/depreciation.js: in net, below.
        depreciation: round2(depreciation),
        // The hours the shop's people logged, at their rate — see LABOUR.
        labour: round2(row.labour),
        // Labour logged in a period that ALSO books pay as an expense or a
        // fixed cost: possibly the same money twice. Said, never subtracted.
        labourOverlap: row.labour > 0 && (row.payrollExpense || (payrollOverhead && fixed > 0)),
        vatCollected: round2(row.vatCollected),
        vatReclaimable: round2(row.vatReclaimable),
        // What the shop actually owes the authority for the quarter: the tax it
        // charged, less the tax it paid. Negative means a refund is due, which
        // is a real position for a quarter that bought a printer.
        vatDue: round2(row.vatCollected - row.vatReclaimable),
        // NET IS WHAT WAS LEFT AFTER EVERYTHING, the cost of making the work
        // included. This was `revenue - expenses - fixed`, while the margin
        // beside it and `computePnl` (the desktop's own "Net profit" headline)
        // both took the cost of goods out — so the shop's real book printed a
        // -495.8% margin beside a 50.00 net income for the same quarter, and
        // the two figures could not both be true.
        net: round2(row.revenue - row.cogs - row.expenses - row.waste - fixed - depreciation - row.labour),
        cogs: round2(row.cogs),
        unpriced: row.unpriced,
        marginPct: row.revenue > 0 ? Math.round(((row.revenue - row.cogs) / row.revenue) * 1000) / 10 : null,
      };
    });
  }

  /* ── THE P&L AS A FILE ────────────────────────────────────────────────────
   *
   * `pnlByPeriod`'s rows, over the span the shop chose, written out for an
   * accountant: a CSV a spreadsheet opens and the HTML a PDF is printed from.
   * Both from ONE set of totals (`periodTotals`), so the file and the screen —
   * which sums the same rows — cannot disagree about a figure.
   *
   * MONEY IS A PLAIN NUMBER in the CSV: no currency mark, no thousands
   * separator, a point for the decimal, unquoted — so a spreadsheet reads a
   * number and can add it up. The currency is said once, in the header. Text
   * is quoted and formula-guarded like every other export here. A BOM leads,
   * because Excel on Windows reads a UTF-8 file without one in the system code
   * page and turns Arabic labels into mojibake.
   *
   * The words are the caller's (`opts.labels`, keyed like the defaults below),
   * so the file reads in the shop's language; the English defaults keep a
   * caller that passes none readable. */
  const STATEMENT_LABELS = {
    title: 'Profit & Loss', period: 'Period', from: 'From', to: 'To', currency: 'Currency',
    orders: 'Orders', revenue: 'Revenue', cogs: 'Cost of goods sold',
    waste: 'Filament wasted (failed prints)', depreciation: 'Machine depreciation',
    labour: 'Labour (logged hours)', expenses: 'Expenses', fixed: 'Fixed overhead',
    costs: 'Costs', net: 'Net income', margin: 'Gross margin %',
    vatCollected: 'VAT collected', vatReclaimable: 'VAT reclaimed', vatDue: 'VAT to remit',
    total: 'Total', inventory: 'Filament bought (stock, counted when used)',
    capital: 'Equipment bought (depreciated)',
    vatTitle: 'VAT for the period', vatOutput: 'Output VAT on sales',
    vatInput: 'Input VAT on expenses', vatNet: 'Net VAT payable', vatSales: 'Sales, net of VAT',
    vatMode: '', vatMissing: '',
  };

  /** Every money column of the rows added up, the margin blended once. */
  function periodTotals(rows) {
    const t = { orders: 0, revenue: 0, cogs: 0, waste: 0, depreciation: 0, labour: 0, expenses: 0,
      fixed: 0, net: 0, vatCollected: 0, vatReclaimable: 0, vatDue: 0, inventory: 0, capital: 0 };
    for (const r of Array.isArray(rows) ? rows : []) {
      if (!r) continue;
      for (const k of Object.keys(t)) t[k] += +r[k] || 0;
    }
    const out = {};
    for (const k of Object.keys(t)) out[k] = k === 'orders' ? t[k] : round2(t[k]);
    out.marginPct = t.revenue > 0 ? Math.round(((t.revenue - t.cogs) / t.revenue) * 1000) / 10 : null;
    return out;
  }

  /** A number as a spreadsheet reads one: plain, two places at most. */
  const plainNumber = (n) => (n == null || !Number.isFinite(+n) ? '' : String(round2(+n)));
  const csvText = (v) => {
    const t = v == null ? '' : String(v);
    const safe = /^[=+\-@\t\r]/.test(t) ? "'" + t : t;
    return '"' + safe.replace(/"/g, '""') + '"';
  };
  const csvCell = (v) => (typeof v === 'number' ? plainNumber(v) : csvText(v));
  /** Oldest first, which is how a statement reads down the page. */
  const chronological = (rows) => (Array.isArray(rows) ? rows.filter(Boolean) : [])
    .slice().sort((a, b) => String(a.period).localeCompare(String(b.period)));
  /** The whole days a period key names: "2026-Q3", "2026-09". */
  function periodDays(key) {
    const m = /^(\d{4})-(?:Q([1-4])|(0[1-9]|1[0-2]))$/.exec(String(key || ''));
    if (!m) return null;
    const y = +m[1];
    const first = m[2] ? (+m[2] - 1) * 3 : +m[3] - 1;
    const count = m[2] ? 3 : 1;
    const p2 = (n) => String(n).padStart(2, '0');
    const last = new Date(Date.UTC(y, first + count, 0)).getUTCDate();
    return { from: `${y}-${p2(first + 1)}-01`, to: `${y}-${p2(first + count)}-${p2(last)}` };
  }
  /** Does the span hold only some of this row's period? */
  const isPartial = (r) => {
    if (!r || !r.from || !r.to) return false;
    const w = periodDays(r.period);
    return !w || r.from !== w.from || r.to !== w.to;
  };
  /** A row cut short by the span says which of its days it holds. */
  const rowName = (r) => (isPartial(r) ? `${r.period} (${r.from} – ${r.to})` : String(r.period));

  /**
   * @param {Array} rows    pnlByPeriod's rows
   * @param {object|null} vat   lib/vat-summary.js `summarize`, or null
   * @param {object} [opts] `{ labels, currency, periodLabel, from, to }`
   */
  function periodsToCsv(rows, vat, opts) {
    const o = opts || {};
    const L = Object.assign({}, STATEMENT_LABELS, o.labels || {});
    const list = chronological(rows);
    const t = periodTotals(list);
    const out = [];
    out.push([L.title, o.periodLabel || '']);
    if (o.from) out.push([L.from, o.from]);
    if (o.to) out.push([L.to, o.to]);
    if (o.currency) out.push([L.currency, o.currency]);
    out.push([]);
    const cols = ['period', 'orders', 'revenue', 'cogs', 'waste', 'depreciation', 'labour', 'expenses',
      'fixed', 'net', 'margin', 'vatCollected', 'vatReclaimable', 'vatDue'];
    out.push(cols.map((k) => L[k]));
    const line = (name, r) => cols.map((k) => {
      if (k === 'period') return name;
      if (k === 'margin') return r.marginPct == null ? '' : +r.marginPct;
      return +r[k] || 0;
    });
    for (const r of list) out.push(line(rowName(r), r));
    out.push(line(L.total, t));
    if (t.inventory || t.capital) out.push([]);
    if (t.inventory) out.push([L.inventory, t.inventory]);
    if (t.capital) out.push([L.capital, t.capital]);
    if (vat && vat.applies) {
      out.push([]);
      out.push([L.vatTitle]);
      out.push([L.vatSales, +vat.sales || 0]);
      out.push([L.vatOutput, +vat.output || 0]);
      out.push([L.vatInput, +vat.input || 0]);
      out.push([L.vatNet, +vat.net || 0]);
      if (L.vatMode) out.push([L.vatMode]);
      if (L.vatMissing) out.push([L.vatMissing]);
    }
    return '﻿' + out.map((r) => r.map(csvCell).join(',')).join('\r\n') + '\r\n';
  }

  const escapeHtml = (v) => String(v == null ? '' : v)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  /** Money on paper: grouped, two places, Western digits, a real minus. */
  const paperMoney = (n) => {
    const v = round2(+n || 0);
    const parts = Math.abs(v).toFixed(2).split('.');
    return (v < 0 ? '−' : '') + parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',') + '.' + parts[1];
  };

  /**
   * The same statement as a page to print: the span's totals as a list of
   * lines, the periods inside it as a short table, and the VAT summary. A4
   * portrait holds six columns legibly; the CSV carries every one.
   *
   * @param {object} [opts] `{ labels, currency, periodLabel, from, to, dir, lang, shopName }`
   */
  function periodsToHtml(rows, vat, opts) {
    const o = opts || {};
    const L = Object.assign({}, STATEMENT_LABELS, o.labels || {});
    const list = chronological(rows);
    const t = periodTotals(list);
    const dir = o.dir === 'rtl' ? 'rtl' : 'ltr';
    const lineRow = (label, value, cls) =>
      `<tr${cls ? ` class="${cls}"` : ''}><th scope="row">${escapeHtml(label)}</th><td>${paperMoney(value)}</td></tr>`;
    const lines = [lineRow(L.revenue, t.revenue)];
    lines.push(lineRow(L.cogs, -t.cogs));
    if (t.waste) lines.push(lineRow(L.waste, -t.waste));
    if (t.depreciation) lines.push(lineRow(L.depreciation, -t.depreciation));
    if (t.labour) lines.push(lineRow(L.labour, -t.labour));
    lines.push(lineRow(L.expenses, -t.expenses));
    if (t.fixed) lines.push(lineRow(L.fixed, -t.fixed));
    lines.push(lineRow(L.net, t.net, t.net < 0 ? 'net neg' : 'net'));
    if (t.inventory) lines.push(lineRow(L.inventory, t.inventory, 'aside'));
    if (t.capital) lines.push(lineRow(L.capital, t.capital, 'aside'));

    const head = ['period', 'orders', 'revenue', 'costs', 'net', 'margin']
      .map((k) => `<th scope="col">${escapeHtml(L[k])}</th>`).join('');
    const costsOf = (r) => (+r.cogs || 0) + (+r.waste || 0) + (+r.depreciation || 0)
      + (+r.labour || 0) + (+r.expenses || 0) + (+r.fixed || 0);
    const pct = (m) => (m == null ? '—' : `${m}%`);
    const periodRow = (name, r) => `<tr><th scope="row">${escapeHtml(name)}</th>`
      + `<td>${+r.orders || 0}</td><td>${paperMoney(r.revenue)}</td><td>${paperMoney(-costsOf(r))}</td>`
      + `<td>${paperMoney(r.net)}</td><td>${pct(r.marginPct)}</td></tr>`;
    const body = list.map((r) => periodRow(rowName(r), r)).join('');

    let vatBlock = '';
    if (vat && vat.applies) {
      const notes = [L.vatMode, L.vatMissing].filter(Boolean)
        .map((n) => `<p class="note">${escapeHtml(n)}</p>`).join('');
      vatBlock = `<h2>${escapeHtml(L.vatTitle)}</h2><table class="lines">`
        + lineRow(L.vatSales, vat.sales, 'aside')
        + lineRow(L.vatOutput, vat.output)
        + lineRow(L.vatInput, -(+vat.input || 0))
        + lineRow(L.vatNet, vat.net, 'net')
        + `</table>${notes}`;
    }
    const sub = [o.periodLabel, o.from && o.to ? `${o.from} – ${o.to}` : '', o.currency || '']
      .filter(Boolean).map(escapeHtml).join(' · ');
    return `<div class="pnl-doc" dir="${dir}"${o.lang ? ` lang="${escapeHtml(o.lang)}"` : ''}>`
      + '<style>'
      + '.pnl-doc{font:11px/1.5 -apple-system,"SF Pro Text","Segoe UI",Tahoma,sans-serif;color:#1a1a1a}'
      + '.pnl-doc h1{font-size:18px;margin:0 0 2px}.pnl-doc h2{font-size:13px;margin:18px 0 6px}'
      + '.pnl-doc .sub{color:#555;margin:0 0 14px}'
      + '.pnl-doc table{width:100%;border-collapse:collapse;margin:0 0 6px}'
      + '.pnl-doc th,.pnl-doc td{padding:4px 6px;border-bottom:1px solid #e3e0da;text-align:start;font-weight:400}'
      + '.pnl-doc td{text-align:end;font-variant-numeric:tabular-nums;white-space:nowrap}'
      + '.pnl-doc thead th{text-align:end;font-size:10px;color:#555;border-bottom:1px solid #999}'
      + '.pnl-doc thead th:first-child{text-align:start}'
      + '.pnl-doc tr.net th,.pnl-doc tr.net td{font-weight:700;border-top:1px solid #999}'
      + '.pnl-doc tr.neg td{color:#b3261e}.pnl-doc tr.aside th,.pnl-doc tr.aside td{color:#666}'
      + '.pnl-doc tfoot th,.pnl-doc tfoot td{font-weight:700;border-top:1px solid #999}'
      + '.pnl-doc .note{color:#555;margin:4px 0}'
      + '</style>'
      + `<h1>${escapeHtml(L.title)}${o.shopName ? ' · ' + escapeHtml(o.shopName) : ''}</h1>`
      + `<p class="sub">${sub}</p>`
      + `<table class="lines">${lines.join('')}</table>`
      + `<h2>${escapeHtml(L.period)}</h2>`
      + `<table class="periods"><thead><tr>${head}</tr></thead><tbody>${body}</tbody>`
      + `<tfoot>${periodRow(L.total, t)}</tfoot></table>`
      + vatBlock
      + '</div>';
  }

  const api = { computePnl, pnlToCsv, pnlByPeriod, isInventoryPurchase, INVENTORY_CATEGORIES, stockShare,
    capitalPurchases, CAPITAL_CATEGORIES,
    labourCostOf, labourCounts, looksLikePayroll, payrollFixedCosts,
    periodTotals, periodsToCsv, periodsToHtml, STATEMENT_LABELS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPnl = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
