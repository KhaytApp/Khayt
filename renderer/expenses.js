/**
 * Expense tracker, recurring expenses, profitability, tax CSV export.
 */
let expRangeFilter = 'all';
let _expReceiptPath = null;
const EXP_CATEGORIES = ['filament','electricity','maintenance','tools','shipping','other'];

(function (global) {
/** The rule, however this file happens to be loaded — a script tag in the
 *  window, or `require` in a test. */
const ExpenseBook = (typeof globalThis !== 'undefined' && globalThis.KhaytExpenseBook)
  || (() => { try { return require('../lib/expense-book.js'); } catch (e) { return null; } })();

/** The rule is lib/expense-book.js; this is the name the rest of this file calls. */
function calcNextDueDate(fromDate, recurring) {
  return ExpenseBook.nextDueDate(fromDate, recurring);
}

function checkRecurringExpenses() {
  const todayStr = localDateStr();
  const due = ExpenseBook.due(expenses, todayStr);
  if (due.length === 0) return;
  for (const exp of due) {
    const label = `${expCatLabel(exp.category)} ${fmtPrice(exp.amount)}`;
    const c = document.createElement('div');
    c.className = 'toast info';
    c.style.cssText = 'max-width:360px;';
    c.innerHTML = `<span>${escapeHtml(t('exp.recurring_due'))}: ${escapeHtml(label)}</span>`;
    const addBtn = document.createElement('button');
    addBtn.className = 'undo-btn';
    addBtn.textContent = t('common.add') || 'Add';
    const skipBtn = document.createElement('button');
    skipBtn.className = 'undo-btn';
    skipBtn.style.marginInlineStart = '4px';
    skipBtn.textContent = 'Skip';
    addBtn.addEventListener('click', () => {
      expenses.unshift(ExpenseBook.recurrence(exp, { id: uid('EXP'), today: todayStr }));
      exp.nextDue = calcNextDueDate(exp.nextDue || todayStr, exp.recurring);
      saveAll();
      renderExpenses();
      toast(t('exp.recurring_added'), 'success');
      c.remove();
    });
    skipBtn.addEventListener('click', () => {
      exp.nextDue = calcNextDueDate(exp.nextDue || todayStr, exp.recurring);
      saveAll();
      c.remove();
    });
    c.appendChild(addBtn);
    c.appendChild(skipBtn);
    $('#toastContainer').appendChild(c);
    setTimeout(() => { c.style.opacity = '0'; c.style.transition = 'opacity .2s'; }, 8000 - 250);
    setTimeout(() => c.remove(), 8000);
  }
}

/* ============================================================
   Expense tracker
   ============================================================ */
let expRangeFilter = 'all';

const EXP_CATEGORIES = ['filament','electricity','maintenance','tools','shipping','other'];

function expCatLabel(cat) {
  return t('exp.cat.' + cat) || cat;
}

// Module-level variable for the current expense receipt path
let _expReceiptPath = null;

function addExpense() {
  // The record is lib/expense-book.js's, so the Mac writes the same one. It
  // was built here from seven controls, which is why only this window could.
  const made = ExpenseBook.newExpense({
    amount:      $('#expAmount').value,
    vatAmount:   $('#expVatAmount')?.value,
    date:        $('#expDate').value,
    category:    $('#expCategory').value,
    note:        $('#expNote').value,
    orderId:     $('#expOrderRef')?.value,
    recurring:   $('#expRecurring')?.value,
    receiptPath: _expReceiptPath,
    locationId:  $('#exp_locationId')?.value,
  }, { id: uid('EXP'), today: localDateStr() });
  if (made.refused) { toast(t('exp.amount_required'), 'error'); return; }
  expenses.unshift(made.expense);
  saveAll();
  // Budget overspend check, AFTER the expense is in, against the shop's own
  // calendar month — see overBudget for why not UTC's.
  const expCat = made.expense.category;
  const over = ExpenseBook.overBudget(expenses, expCat, localMonthStr(), settings.expBudgets);
  if (over) {
    toast(t('exp.budget_exceeded', { cat: expCatLabel(expCat), spent: fmtMoney(over.spent), budget: fmtMoney(over.budget) }), 'warning', 5000);
  }
  $('#expAmount').value = '';
  if ($('#expVatAmount')) $('#expVatAmount').value = '';
  $('#expNote').value   = '';
  if ($('#expOrderRef')) $('#expOrderRef').value = '';
  if ($('#expRecurring')) $('#expRecurring').value = '';
  _expReceiptPath = null;
  const nameEl = $('#expReceiptName');
  if (nameEl) nameEl.textContent = '';
  renderExpenses();
  toast(t('exp.added'), 'success');
}

function showLinkedExpenses(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const linked = expenses.filter(e => e.orderId === orderId);
  const total = linked.reduce((s, e) => s + (+e.amount || 0), 0);
  const tableHtml = linked.length === 0
    ? `<p style="color:var(--text-muted); font-size:13px; text-align:center; padding:16px 0;">${escapeHtml(t('exp.no_linked'))}</p>`
    : `<div class="table-wrap"><table style="width:100%;">
        <thead><tr>
          <th>${escapeHtml(t('common.date'))}</th>
          <th>${escapeHtml(t('exp.category'))}</th>
          <th>${escapeHtml(t('exp.amount'))}</th>
          <th>${escapeHtml(t('exp.note'))}</th>
        </tr></thead>
        <tbody>${linked.map(e => `<tr>
          <td style="font-size:12px; color:var(--text-dim);">${escapeHtml(e.date || '')}</td>
          <td><span class="exp-cat-badge cat-${escapeHtml(e.category)}">${escapeHtml(expCatLabel(e.category))}</span></td>
          <td style="color:var(--danger); font-variant-numeric:tabular-nums;">${fmtPrice(e.amount)}</td>
          <td style="color:var(--text-muted); font-size:12.5px;">${escapeHtml(e.note || '')}</td>
        </tr>`).join('')}</tbody>
      </table></div>
      <div style="text-align:right; font-size:13px; font-weight:600; margin-top:10px; color:var(--danger);">
        ${escapeHtml(t('exp.sum.expenses'))}: ${fmtPrice(total)}
      </div>`;
  openFormModal({
    title: `${t('exp.linked_expenses')} — ${escapeHtml(order.id)}`,
    noSave: true,
    sizeLg: true,
    bodyHtml: tableHtml,
  });
}

async function emailOrderToClient(orderId, isQuote = false) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  if (!client?.email) { toast(t('ord.no_email'), 'error'); return; }
  const clientName = localName(client) || order.project || '';
  const shopName = shopName() || 'Khayt';
  const subjectText = isQuote
    ? `Quote #${order.id} — ${order.project}`
    : `Invoice for order #${order.id} — ${order.project}`;

  // Use configured SMTP if available, fall back to mailto
  const cfg = settings.emailConfig;
  const smtpReady = cfg && cfg.provider !== 'none' && cfg.provider !== 'mailto' && (
    (cfg.provider === 'custom' && cfg.smtpHost && (cfg.fromEmail || cfg.smtpUser)) ||
    (cfg.provider !== 'custom' && cfg.apiKey)
  );
  if (smtpReady && window.hubAPI?.sendEmail) {
    const htmlBody = `<div style="font-family:sans-serif;max-width:500px;margin:0 auto;padding:20px;">
      <h2 style="color:${safeCssColor(settings.invAccentColor, '#5E2E14')};">${escapeHtml(shopName)}</h2>
      <p>Dear ${escapeHtml(clientName)},</p>
      <p>${isQuote
        ? `Please find below your quote <strong>${escapeHtml(order.id)}</strong> for <strong>${fmtPrice(order.price)}</strong>.`
        : `Please find below your invoice <strong>${escapeHtml(order.id)}</strong> for <strong>${fmtPrice(order.price)}</strong>.`
      }</p>
      <p>Project: ${escapeHtml(order.project || '')}</p>
      <p>Date: ${escapeHtml(order.date || '')}</p>
      ${!isQuote && settings.paymentInstructions ? `<p>${escapeHtml(settings.paymentInstructions)}</p>` : ''}
      <p>Thank you for your business!</p>
      <p style="font-size:12px;color:#888;">— ${escapeHtml(shopName)}</p>
    </div>`;
    try {
      const result = await window.hubAPI.sendEmail({ to: client.email, subject: subjectText, body: htmlBody, smtpConfig: cfg });
      if (result?.ok) {
        toast('📧 ' + t('ord.email_sent'), 'success');
        return;
      }
      // Say WHY the configured sender failed before quietly falling back. An expired
      // SendGrid key or failed SMTP auth used to be dropped on the floor and reported as
      // a success, and the mailto fallback carries no PDF — so the customer received a
      // bare text email instead of the invoice, and the shop never knew.
      if (result?.error) {
        toast('⚠ ' + (t('ord.email_send_failed') || 'Could not send from your mail account') + ': ' + result.error, 'error', 7000);
      }
    } catch(e) {
      console.error('sendEmail failed:', e);
      toast('⚠ ' + (t('ord.email_send_failed') || 'Could not send from your mail account'), 'error', 7000);
    }
  }

  // Fallback: open OS mail client
  const bodyLines = [
    `Dear ${clientName},`, '',
    isQuote
      ? `Please find attached your quote #${order.id} for ${fmtPrice(order.price)}.`
      : `Please find attached your invoice #${order.id} for ${fmtPrice(order.price)}.`,
    `Order: ${order.project}`, `Date: ${order.date}`,
  ];
  if (!isQuote && settings.paymentInstructions) bodyLines.push('', settings.paymentInstructions);
  bodyLines.push('', 'Thank you for your business!', shopName);
  const mailtoUrl = `mailto:${encodeURIComponent(client.email)}?subject=${encodeURIComponent(subjectText)}&body=${encodeURIComponent(bodyLines.join('\n'))}`;
  window.open(mailtoUrl);
  // 'opened', not 'sent' — nothing has been delivered yet and there is no attachment.
  toast(t('ord.email_opened'), 'info');
}

function populateExpOrderDatalist() {
  const dl = $('#expOrderList');
  if (!dl) return;
  dl.innerHTML = printLog.slice(0, 50).map(o =>
    `<option value="${escapeHtml(o.id)}">${escapeHtml(o.id)} — ${escapeHtml(o.project || '')}</option>`
  ).join('');
}

async function deleteExpense(id) {
  const expense = expenses.find(e => e.id === id);
  const label = expense ? (expense.note || expCatLabel(expense.category) || expense.category) : '';
  const msg = expense
    ? `${t('common.delete')} "${escapeHtml(label)}" — ${fmtPrice(expense.amount)}?`
    : t('common.delete') + '?';
  const ok = await confirmModal(msg, { danger: true });
  if (!ok) return;
  expenses = expenses.filter(e => e.id !== id);
  saveAll();
  renderExpenses();
}

function renderExpenses() {
  const filtered = expenses.filter(e => inRange(e.date, expRangeFilter, 'expenses'));
  const tbody = $('#expenseTable tbody');

  // A shop that is not registered reclaims nothing, so it is not asked. Read
  // through the tax rule rather than from `enableVat`, so a shop configured
  // through the country presets is answered the same way its invoices are.
  const vatRow = $('#expVatRow');
  if (vatRow) {
    const profile = (typeof KhaytTax !== 'undefined' && settings)
      ? KhaytTax.profileFromSettings(settings) : null;
    vatRow.hidden = !(profile && profile.rates && profile.rates.length);
  }

  if (expenses.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" class="empty-state">${escapeHtml(t('exp.empty'))}</td></tr>`;
  } else if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="5" class="empty-state">${escapeHtml(t('exp.empty_filter'))}</td></tr>`;
  } else {
    tbody.innerHTML = filtered.map(e => `
      <tr data-expense-id="${escapeHtml(e.id)}">
        <td style="font-family:var(--font-num); font-size:12px; color:var(--text-dim); white-space:nowrap;">${escapeHtml(e.date)}</td>
        <td><span class="exp-cat-badge cat-${escapeHtml(e.category)}">${escapeHtml(expCatLabel(e.category))}</span></td>
        <td style="font-weight:600; font-variant-numeric:tabular-nums; color:var(--danger);">${fmtPrice(e.amount)}</td>
        <td style="color:var(--text-muted); font-size:12.5px;">
          ${escapeHtml(e.note)}
          ${e.recurring ? `<span class="rec-badge" style="font-size:10px;">🔁 ${escapeHtml(t('exp.recurring_' + e.recurring))}${e.nextDue ? ' · ' + escapeHtml(e.nextDue) : ''}</span>` : ''}
        </td>
        <td style="white-space:nowrap;">
          ${e.receiptPath ? `<button class="btn small ghost" data-act="open-receipt" data-path="${escapeHtml(e.receiptPath)}" title="${escapeHtml(t('exp.open_receipt'))}" aria-label="${escapeHtml(t('exp.open_receipt'))}"><span aria-hidden="true">📎</span></button>` : ''}
          <button class="btn danger small" data-act="del-exp" data-id="${e.id}">${escapeHtml(t('common.delete'))}</button>
        </td>
      </tr>`).join('');
  }

  // Summary
  const totalExpenses = filtered.reduce((s, e) => s + e.amount, 0);
  const revenue = printLog
    .filter(o => o.status === 'completed' && inRange(o.date, expRangeFilter, 'expenses'))
    .reduce((s, o) => s + orderNetRevenueBase(o), 0);
  const profit = revenue - totalExpenses;

  const byCategory = {};
  EXP_CATEGORIES.forEach(c => { byCategory[c] = 0; });
  filtered.forEach(e => { byCategory[e.category] = (byCategory[e.category] || 0) + e.amount; });

  const summaryEl = $('#expenseSummary');
  if (summaryEl) {
    summaryEl.innerHTML = `
      <div class="exp-summary-row">
        <span>${escapeHtml(t('exp.sum.revenue'))}</span>
        <strong style="color:var(--success);">${fmtPrice(revenue)}</strong>
      </div>
      <div class="exp-summary-row">
        <span>${escapeHtml(t('exp.sum.expenses'))}</span>
        <strong style="color:var(--danger);">${fmtPrice(totalExpenses)}</strong>
      </div>
      <div class="exp-summary-row exp-profit">
        <span>${escapeHtml(t('exp.sum.profit'))}</span>
        <strong style="color:${profit >= 0 ? 'var(--success)' : 'var(--danger)'};">${fmtPrice(profit)}</strong>
      </div>
      <hr style="border:none; border-top:1px solid var(--border); margin:14px 0 10px;">
      ${EXP_CATEGORIES.filter(c => byCategory[c] > 0).map(c => {
        const budget = (settings.expBudgets || {})[c] || 0;
        const pct = budget > 0 ? Math.min(100, (byCategory[c] / budget) * 100) : 0;
        const over = budget > 0 && byCategory[c] > budget;
        return `
        <div class="exp-summary-row" style="font-size:12.5px; flex-direction:column; align-items:stretch; gap:3px;">
          <div style="display:flex; justify-content:space-between; align-items:center;">
            <span class="exp-cat-badge cat-${escapeHtml(c)}">${escapeHtml(expCatLabel(c))}</span>
            <span style="color:${over ? 'var(--danger)' : 'var(--text-dim)'};">${fmtPrice(byCategory[c])}${budget > 0 ? ` / ${fmtPrice(budget)}` : ''}</span>
          </div>
          ${budget > 0 ? `<div class="exp-budget-bar"><div class="exp-budget-fill${over ? ' over' : ''}" style="width:${pct.toFixed(1)}%;"></div></div>` : ''}
        </div>`;
      }).join('')}
    `;
  }
  renderExpenseBudgets();
}

function renderExpenseBudgets() {
  const el = $('#expenseBudgetSection');
  if (!el) return;
  const budgets = settings.expBudgets || {};
  const hasBudgets = EXP_CATEGORIES.some(c => (budgets[c] || 0) > 0);
  if (!hasBudgets) {
    el.innerHTML = `<p style="color:var(--text-muted); font-size:13px;">${escapeHtml(t('exp.no_budgets'))}</p>`;
    return;
  }
  // Budgets are monthly — use the active month if a month filter is selected, otherwise current month
  const budgetFilter = (expRangeFilter === 'month' || expRangeFilter === 'last_month') ? expRangeFilter : 'month';
  const filteredExpenses = expenses.filter(e => inRange(e.date, budgetFilter, 'expenses'));
  const byCategory = {};
  EXP_CATEGORIES.forEach(c => { byCategory[c] = 0; });
  filteredExpenses.forEach(e => { byCategory[e.category] = (byCategory[e.category] || 0) + e.amount; });

  const rows = EXP_CATEGORIES.filter(c => (budgets[c] || 0) > 0).map(c => {
    const budget = budgets[c];
    const spent = byCategory[c] || 0;
    const remaining = budget - spent;
    const pct = Math.min(100, (spent / budget) * 100);
    const barColor = pct >= 100 ? 'var(--danger)' : pct >= 70 ? 'var(--warning)' : 'var(--success)';
    return `<tr>
      <td><span class="exp-cat-badge cat-${escapeHtml(c)}">${escapeHtml(expCatLabel(c))}</span></td>
      <td style="font-variant-numeric:tabular-nums; text-align:right;">${fmtPrice(budget)}</td>
      <td style="font-variant-numeric:tabular-nums; text-align:right; color:${pct >= 100 ? 'var(--danger)' : 'inherit'};">${fmtPrice(spent)}</td>
      <td style="font-variant-numeric:tabular-nums; text-align:right; color:${remaining >= 0 ? 'var(--success)' : 'var(--danger)'};">${remaining >= 0 ? fmtPrice(remaining) : '−' + fmtPrice(-remaining)}</td>
      <td style="min-width:120px; padding-inline-start:12px;">
        <div style="background:rgba(255,255,255,0.08); border-radius:4px; height:8px; overflow:hidden;">
          <div style="background:${barColor}; width:${pct.toFixed(1)}%; height:100%; border-radius:4px; transition:width 0.3s;"></div>
        </div>
        ${pct >= 100 ? `<div style="font-size:10px; color:var(--danger); margin-top:2px;">${escapeHtml(t('exp.over_budget'))}</div>` : ''}
      </td>
    </tr>`;
  }).join('');

  el.innerHTML = `<div class="table-wrap"><table style="width:100%;">
    <thead><tr>
      <th>${escapeHtml(t('exp.category'))}</th>
      <th style="text-align:right;">${escapeHtml(t('exp.budget_col'))}</th>
      <th style="text-align:right;">${escapeHtml(t('exp.actual_col'))}</th>
      <th style="text-align:right;">${escapeHtml(t('exp.remaining_col'))}</th>
      <th style="padding-inline-start:12px;">Progress</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table></div>`;
}

function exportExpensesCsv() {
  const filtered = expenses.filter(e => inRange(e.date, expRangeFilter, 'expenses'));
  const lines = [
    [`Date`,`Category`,`Amount (${currencySymbol()})`,`Note`,`Order ID`].map(csvEsc).join(','),
    ...filtered.map(e => [e.date, expCatLabel(e.category), e.amount, e.note, e.orderId || ''].map(csvEsc).join(','))
  ];
  downloadBlob(new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' }),
    `expenses-${localDateStr()}.csv`);
}

/* ============================================================
   Order file attachments helpers
   ============================================================ */
function renderAttachedFiles(files) {
  if (!files || files.length === 0) {
    return `<p style="font-size:12px; color:var(--text-muted); margin:6px 0 0;">${escapeHtml(t('oe.no_files'))}</p>`;
  }
  return files.map((f, i) => {
    const fmtSize = f.size > 1048576 ? (f.size / 1048576).toFixed(1) + ' MB'
      : f.size > 1024 ? (f.size / 1024).toFixed(0) + ' KB' : (f.size || 0) + ' B';
    return `<div class="attached-file-row" data-fi="${i}">
      <span class="attached-file-icon">📎</span>
      <span class="attached-file-name">${escapeHtml(f.originalName || f.filename)}</span>
      <span class="attached-file-size">${fmtSize}</span>
      <button class="btn small ghost" data-act="open-file" data-fi="${i}" title="${escapeHtml(t('oe.open_file'))}">${escapeHtml(t('oe.open_file'))}</button>
      <button class="btn danger small" data-act="rm-file" data-fi="${i}" title="${escapeHtml(t('common.delete'))}" aria-label="${escapeHtml(t('common.delete'))}"><span aria-hidden="true">×</span></button>
    </div>`;
  }).join('');
}

function buildProfitabilityHtml(order) {
  if (!order.parts || order.parts.length === 0) return '';
  const estCost = order.parts.reduce((s, p) => s + partTotalCost(p), 0);
  if (estCost <= 0) return '';
  const revenue = +order.price || 0;

  // --- Estimated row ---
  const estProfit = revenue - estCost;
  const estMargin = revenue > 0 ? (estProfit / revenue) * 100 : 0;
  const estCol = estProfit >= 0 ? 'var(--success)' : 'var(--danger)';

  const statCell = (label, value, color = '') => `
    <div style="background:var(--surface-2,rgba(255,255,255,.04)); padding:8px; border-radius:6px; text-align:center;">
      <div style="color:var(--text-muted); font-size:11px;">${label}</div>
      <div style="font-weight:600;${color ? ` color:${color};` : ''}">${value}</div>
    </div>`;

  let actualRowHtml = '';
  const hasActual = (order.actualWeight != null && order.actualWeight > 0) ||
                    (order.actualPrintTime != null && order.actualPrintTime > 0);
  if (hasActual) {
    // Compute actual cost by scaling each part's material & machine components
    const totalEstWeight    = order.parts.reduce((s, p) => s + (+p.printWeight || 0), 0);
    const totalEstTime      = order.parts.reduce((s, p) => s + (+p.printTime   || 0), 0);
    const weightRatio = (totalEstWeight > 0 && order.actualWeight   > 0) ? order.actualWeight   / totalEstWeight : 1;
    const timeRatio   = (totalEstTime   > 0 && order.actualPrintTime > 0) ? order.actualPrintTime / totalEstTime  : 1;
    const actualCost = order.parts.reduce((s, p) => {
      const bd = computePartBreakdown(p);
      return s + (bd.material * weightRatio) + (bd.machine * timeRatio) + bd.labor + bd.buffer;
    }, 0);
    const actualProfit = revenue - actualCost;
    const actualMargin = revenue > 0 ? (actualProfit / revenue) * 100 : 0;
    const actualCol    = actualProfit >= 0 ? 'var(--success)' : 'var(--danger)';
    actualRowHtml = `
      <div style="font-size:11px; color:var(--text-muted); margin:8px 0 4px; padding-inline-start:2px;">${escapeHtml(t('oe.actual_row'))}</div>
      <div style="display:grid; grid-template-columns:repeat(3,1fr); gap:8px; font-size:13px;">
        ${statCell(escapeHtml(t('oe.revenue')), fmtPrice(revenue))}
        ${statCell(escapeHtml(t('oe.actual_cost')), fmtPrice(actualCost))}
        ${statCell(escapeHtml(t('oe.profit')), `${fmtPrice(actualProfit)} <span style="font-size:11px;">(${actualMargin.toFixed(0)}%)</span>`, actualCol)}
      </div>`;
  }

  return `
    <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0;">${escapeHtml(t('oe.profitability'))}</label>
      <div style="font-size:11px; color:var(--text-muted); margin:6px 0 4px; padding-inline-start:2px;">${escapeHtml(t('oe.est_row'))}</div>
      <div style="display:grid; grid-template-columns:repeat(3,1fr); gap:8px; font-size:13px;">
        ${statCell(escapeHtml(t('oe.revenue')), fmtPrice(revenue))}
        ${statCell(escapeHtml(t('oe.est_cost')), fmtPrice(estCost))}
        ${statCell(escapeHtml(t('oe.profit')), `${fmtPrice(estProfit)} <span style="font-size:11px;">(${estMargin.toFixed(0)}%)</span>`, estCol)}
      </div>
      ${actualRowHtml}
    </div>`;
}

/* ============================================================
   Monthly Tax Summary Export
   ============================================================ */
/** Map orders → the accounting-export invoice row shape (VAT-inclusive price).
 *
 * The decisions — a quote is not an invoice, an order with no price is not
 * one, the shop's rate and pricing mode, which customer a clientId belongs to —
 * moved to lib/accounting-rows.js so that the Mac app produces the same file.
 * Two apps disagreeing about a VAT figure is a disagreement an auditor finds.
 * This is now only the renderer's globals, handed over. */
function ordersToInvoiceRows() {
  return KhaytAccountingRows.ordersToInvoiceRows(printLog, {
    settings,
    clients,
    KhaytTax,
    currencyOf: (o) => ((typeof clientCurrency === 'function')
      ? orderCurrency(o) : (settings.currency || 'SAR')),
    toBase: (typeof convertToBase === 'function')
      ? ((amt, cur) => convertToBase(amt, cur)) : ((amt) => amt),
  });
}

/** Map ONE order to the invoice row shape (same rules as ordersToInvoiceRows). */
function orderToInvoiceRow(o) {
  const _tp = KhaytTax.profileFromSettings(settings);
  const rate = _tp.rates.reduce((sum, r) => sum + r.percent, 0);
  const baseCurrency = settings.currency || 'SAR';
  const cur = (typeof clientCurrency === 'function') ? orderCurrency(o) : baseCurrency;
  const client = clients.find(c => c.id === o.clientId);
  return {
    id: o.invoiceNumber || o.id,
    date: o.paidAt || o.date || '',
    clientName: (client && client.name) || o.clientName || o.client || '',
    price: +o.price || 0,
    currency: cur,
    vatRate: rate,
    taxMode: _tp.mode,
    baseCurrency,
    baseAmount: (typeof convertToBase === 'function') ? convertToBase(+o.price || 0, cur) : (+o.price || 0),
  };
}

/** Push a paid order to the accounting webhook once (idempotent via accountingPushedAt). */
function maybePushAccounting(order) {
  const cfg = settings.accountingSync;
  if (!cfg || !cfg.enabled || cfg.pushOnPaid === false) return;
  if (!order || order.paymentStatus !== 'paid' || order.accountingPushedAt) return;
  if (typeof KhaytAccountingExport === 'undefined' || !window.hubAPI?.accountingPush || !/^https?:\/\//i.test(cfg.webhookUrl || '')) return;
  const payload = KhaytAccountingExport.buildInvoicePayload(orderToInvoiceRow(order), { format: cfg.format, salesAccount: cfg.salesAccount, taxCode: cfg.taxCode });
  window.hubAPI.accountingPush({ url: cfg.webhookUrl, secret: cfg.secret, payload })
    .then((r) => {
      if (r && r.ok) { order.accountingPushedAt = new Date().toISOString(); saveAll(); return; }
      // This fires on exactly one event — the unpaid→paid transition — so a failure here
      // is never retried: the order is already paid and the transition cannot recur. The
      // invoice silently never reaches the books. Record the failure so the boot-time
      // sweep below can retry it, and tell the owner.
      order.accountingPushFailedAt = new Date().toISOString();
      order.accountingPushError = String((r && r.error) || 'unknown error');
      saveAll();
      toast('⚠ ' + (t('acct.push_failed') || 'Could not send this invoice to your accounting system') +
        ' — ' + order.accountingPushError, 'error', 7000);
    })
    .catch((e) => {
      console.error('accounting push:', e);
      order.accountingPushFailedAt = new Date().toISOString();
      order.accountingPushError = String(e && e.message || e);
      saveAll();
      toast('⚠ ' + (t('acct.push_failed') || 'Could not send this invoice to your accounting system'), 'error', 7000);
    });
}

/**
 * Retry invoices whose accounting push failed. Called at boot: without this a transient
 * outage at the moment an order was marked paid meant the invoice never reached the
 * books, with nothing to trigger another attempt.
 */
function retryFailedAccountingPushes() {
  const cfg = settings.accountingSync;
  if (!cfg || !cfg.enabled) return;
  const stuck = (printLog || []).filter(o =>
    o && o.paymentStatus === 'paid' && !o.accountingPushedAt && o.accountingPushFailedAt);
  for (const order of stuck) maybePushAccounting(order);
}

/** Export invoices/expenses as accountant-ready CSV (QuickBooks/Xero/Zoho/generic). */
function exportAccounting() {
  if (typeof KhaytAccountingExport === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  openFormModal({
    title: t('an.accounting_export') || 'Accounting CSV',
    sizeLg: false,
    saveLabel: t('set.export') || 'Export',
    bodyHtml: `
      <label>${escapeHtml(t('acct.dataset') || 'Data')}</label>
      <select id="acctDataset" style="margin-bottom:10px;">
        <option value="invoices">${escapeHtml(t('acct.invoices') || 'Invoices')}</option>
        <option value="expenses">${escapeHtml(t('acct.expenses') || 'Expenses')}</option>
      </select>
      <label>${escapeHtml(t('acct.format') || 'Format')}</label>
      <select id="acctFormat">
        <option value="generic">${escapeHtml(t('acct.generic') || 'Generic CSV')}</option>
        <option value="quickbooks">QuickBooks</option>
        <option value="xero">Xero</option>
        <option value="zoho">Zoho Books</option>
      </select>
      <div id="acctMapping" style="margin-top:10px;">
        <div class="inline-pair">
          <div>
            <label style="margin-top:0;">${escapeHtml(t('acct.sales_account') || 'Sales account code')}</label>
            <input id="acctSalesAccount" type="text" maxlength="40" placeholder="${escapeHtml(t('acct.sales_account_ph') || 'e.g. 200')}" value="${escapeHtml((settings.accountingSync && settings.accountingSync.salesAccount) || '')}">
          </div>
          <div>
            <label style="margin-top:0;">${escapeHtml(t('acct.tax_code') || 'Tax code')}</label>
            <input id="acctTaxCode" type="text" maxlength="40" placeholder="${escapeHtml(t('acct.tax_code_ph') || 'e.g. OUTPUT15')}" value="${escapeHtml((settings.accountingSync && settings.accountingSync.taxCode) || '')}">
          </div>
        </div>
        <p style="font-size:11px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('acct.mapping_hint') || 'Xero/Zoho require an account code and a tax code on imported invoices.')}</p>
      </div>`,
    onSave(modal) {
      const dataset = modal.querySelector('#acctDataset').value;
      const format = modal.querySelector('#acctFormat').value;
      const salesAccount = (modal.querySelector('#acctSalesAccount')?.value || '').trim();
      const taxCode = (modal.querySelector('#acctTaxCode')?.value || '').trim();
      // Remember the mapping for next time + the webhook push.
      settings.accountingSync = Object.assign({}, settings.accountingSync, { salesAccount, taxCode });
      saveAll();
      const stamp = localDateStr();
      let csv, name;
      if (dataset === 'expenses') {
        csv = KhaytAccountingExport.buildExpenseCsv(expenses, { format });
        name = `expenses-${format}-${stamp}.csv`;
      } else {
        csv = KhaytAccountingExport.buildInvoiceCsv(ordersToInvoiceRows(), { format, salesAccount, taxCode });
        name = `invoices-${format}-${stamp}.csv`;
      }
      downloadBlob(new Blob([csv], { type: 'text/csv;charset=utf-8;' }), name);
      toast(t('maint.saved') || 'Exported', 'success');
      return true;
    },
  });
}

function exportTaxSummary() {
  // New Feature 4: Show period selector modal before exporting
  const now = new Date();
  const curY = now.getFullYear();
  const curM = now.getMonth(); // 0-based
  const curQ = Math.floor(curM / 3); // 0-based quarter

  openFormModal({
    title: t('tax.period'),
    sizeLg: false,
    saveLabel: t('set.export'),
    bodyHtml: `
      <label>${escapeHtml(t('tax.period'))}</label>
      <select id="taxPeriodSel" style="margin-bottom:10px;">
        <option value="month">${escapeHtml(t('an.this_month') || 'This month')}</option>
        <option value="last_month">${escapeHtml(t('an.last_month') || 'Last month')}</option>
        <option value="quarter">${escapeHtml(t('tax.this_quarter'))}</option>
        <option value="last_quarter">${escapeHtml(t('tax.last_quarter'))}</option>
        <option value="year">${escapeHtml(t('tax.this_year'))}</option>
        <option value="all" selected>${escapeHtml(t('common.all'))}</option>
        <option value="custom">${escapeHtml(t('tax.custom_range'))}</option>
      </select>
      <div id="taxCustomRange" style="display:none;">
        <div class="inline-pair">
          <div>
            <label style="margin-top:0;">${escapeHtml(t('common.date'))} (from)</label>
            <input type="date" id="taxFromDate">
          </div>
          <div>
            <label style="margin-top:0;">${escapeHtml(t('common.date'))} (to)</label>
            <input type="date" id="taxToDate">
          </div>
        </div>
      </div>`,
    onMount(modal) {
      const sel = modal.querySelector('#taxPeriodSel');
      const customDiv = modal.querySelector('#taxCustomRange');
      sel.addEventListener('change', () => {
        customDiv.style.display = sel.value === 'custom' ? '' : 'none';
      });
    },
    onSave(modal) {
      const period = modal.querySelector('#taxPeriodSel').value;
      const fromInput = modal.querySelector('#taxFromDate')?.value || '';
      const toInput   = modal.querySelector('#taxToDate')?.value || '';

      // Helper: last calendar day of a given year/month (1-based month)
      const lastDay = (y, m) => new Date(y, m, 0).getDate();
      const pad = n => String(n).padStart(2, '0');

      // Compute date range
      let fromDate = '', toDate = '';
      if (period === 'month') {
        fromDate = `${curY}-${pad(curM + 1)}-01`;
        toDate   = `${curY}-${pad(curM + 1)}-${lastDay(curY, curM + 1)}`;
      } else if (period === 'last_month') {
        const lm = new Date(curY, curM - 1, 1);
        const ly = lm.getFullYear(), lmm = lm.getMonth() + 1;
        fromDate = `${ly}-${pad(lmm)}-01`;
        toDate   = `${ly}-${pad(lmm)}-${lastDay(ly, lmm)}`;
      } else if (period === 'quarter') {
        const qFrom = curQ * 3 + 1, qTo = curQ * 3 + 3;
        fromDate = `${curY}-${pad(qFrom)}-01`;
        toDate   = `${curY}-${pad(qTo)}-${lastDay(curY, qTo)}`;
      } else if (period === 'last_quarter') {
        const lq = curQ === 0 ? { y: curY - 1, q: 3 } : { y: curY, q: curQ - 1 };
        const lqFrom = lq.q * 3 + 1, lqTo = lq.q * 3 + 3;
        fromDate = `${lq.y}-${pad(lqFrom)}-01`;
        toDate   = `${lq.y}-${pad(lqTo)}-${lastDay(lq.y, lqTo)}`;
      } else if (period === 'year') {
        fromDate = `${curY}-01-01`;
        toDate   = `${curY}-12-31`;
      } else if (period === 'custom') {
        fromDate = fromInput;
        toDate   = toInput;
      }
      // 'all' — no filter

      _doExportTaxSummary(period, fromDate, toDate);
      return true;
    }
  });
}

function _doExportTaxSummary(periodLabel, fromDate, toDate) {
  const inPeriod = (dateStr) => {
    if (!fromDate && !toDate) return true;
    if (!dateStr) return false;
    if (fromDate && dateStr < fromDate) return false;
    if (toDate   && dateStr > toDate)   return false;
    return true;
  };

  // Group completed orders by YYYY-MM
  const monthMap = {};
  for (const o of printLog) {
    if (o.status !== 'completed') continue;
    const ds = (o.date || '').slice(0, 10);
    if (!inPeriod(ds)) continue;
    const month = ds.slice(0, 7);
    if (!month) continue;
    if (!monthMap[month]) monthMap[month] = { orders: 0, revenue: 0, vatCollected: 0, shipping: 0 };
    monthMap[month].orders++;
    monthMap[month].revenue += orderNetRevenueBase(o);
    monthMap[month].shipping += convertToBase(+o.shippingCost || 0, orderCurrency(o));
    // orderNetRevenueBase is net of credit notes, not of tax — still gross.
    monthMap[month].vatCollected += KhaytTax.computeTax(
      orderNetRevenueBase(o), KhaytTax.profileFromSettings(settings)).taxTotal;
  }
  // Group expenses by YYYY-MM
  const expMap = {};
  for (const e of expenses) {
    const ds = (e.date || '').slice(0, 10);
    if (!inPeriod(ds)) continue;
    const month = ds.slice(0, 7);
    if (!month) continue;
    expMap[month] = (expMap[month] || 0) + (+e.amount || 0);
  }

  const allMonths = [...new Set([...Object.keys(monthMap), ...Object.keys(expMap)])].sort();

  if (allMonths.length === 0) {
    toast(t('an.tax_empty'), 'error');
    return;
  }

  // Build period label for filename/header
  const labelMap = {
    month: 'this-month', last_month: 'last-month',
    quarter: 'this-quarter', last_quarter: 'last-quarter',
    year: 'this-year', all: 'all'
  };
  const fileLabel = labelMap[periodLabel] || periodLabel;

  const cur = currencySymbol();
  const headers = [
    `Period: ${fileLabel} ${fromDate ? fromDate + ' to ' + toDate : ''}`,
    `Month`, `Orders`, `Revenue (${cur})`, `Shipping (${cur})`,
    `VAT Collected (${cur})`, `Expenses (${cur})`, `Net Income (${cur})`
  ];
  const headerRow = headers.slice(1).map(csvEsc).join(',');
  const periodRow = [csvEsc(headers[0]), ...new Array(6).fill(csvEsc(''))].join(',');

  const rows = allMonths.map(m => {
    const rev  = monthMap[m]?.revenue  || 0;
    const ship = monthMap[m]?.shipping || 0;
    const vat  = monthMap[m]?.vatCollected || 0;
    const exp  = expMap[m] || 0;
    const net  = rev - exp;
    return [
      m,
      monthMap[m]?.orders || 0,
      rev.toFixed(2),
      ship.toFixed(2),
      vat.toFixed(2),
      exp.toFixed(2),
      net.toFixed(2)
    ].map(csvEsc).join(',');
  });

  downloadBlob(
    new Blob(['﻿' + [periodRow, headerRow, ...rows].join('\r\n')], { type: 'text/csv;charset=utf-8;' }),
    `tax-summary-${fileLabel}-${localDateStr()}.csv`
  );
  toast(t('an.tax_exported'), 'success');
}
  const api = {
    retryFailedAccountingPushes,
    calcNextDueDate,
    checkRecurringExpenses,
    expCatLabel,
    addExpense,
    showLinkedExpenses,
    emailOrderToClient,
    populateExpOrderDatalist,
    deleteExpense,
    renderExpenses,
    renderExpenseBudgets,
    exportExpensesCsv,
    renderAttachedFiles,
    buildProfitabilityHtml,
    exportTaxSummary,
    exportAccounting,
    ordersToInvoiceRows,
    orderToInvoiceRow,
    maybePushAccounting,
  };
  Object.assign(global, api);
  global.KhaytExpenses = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
