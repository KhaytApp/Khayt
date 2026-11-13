'use strict';
/* ============================================================
   Simple mode — the reduced Loyalty, Expenses and Money screens
   ============================================================
 *
 * lib/feature-tiers.js SIMPLE_MAP marks `loyalty`, `expenses` and `money`
 * 'reduced': Simple gets a smaller form of the screen, not an empty one and
 * not the Professional one. Figma 7Iqw0GcrLLRW7CLDEhTa1P, "S4 · Simple mode
 * (desktop)", cards 3–5. The figures are lib/simple-screens.js's, which reads
 * the existing modules; this file only draws them.
 *
 * Each screen is drawn into its own host marked `.sm-simple-only` beside the
 * Professional markup, which carries `data-simple-pro`. styles.css shows one
 * or the other by the body's mode class, so Professional is untouched: its
 * markup, handlers and renders run as before.
 */
(function () {
  const S = () => (typeof KhaytSimpleScreens !== 'undefined' ? KhaytSimpleScreens : null);
  const isSimple = () => typeof settings !== 'undefined' && settings && settings.mode === 'simple';
  const esc = (s) => escapeHtml(String(s == null ? '' : s));
  /** 9,624.21 — grouped, two places, Western digits (as fmtCount pins them). */
  const money2 = (n) => (+n || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  /** 18,920 — a tile figure, whole units. */
  const money0 = (n) => Math.round(+n || 0).toLocaleString('en-US');
  const plural = (n, one, many, vars) => t(n === 1 ? one : many, { n, ...(vars || {}) });

  function dayMonth(day) {
    try {
      return new Date(`${day}T00:00:00`).toLocaleDateString(localeTag(), { day: 'numeric', month: 'short' });
    } catch (_) { return String(day || ''); }
  }
  function monthName(ym, withYear) {
    try {
      return new Date(`${ym}-01T00:00:00`).toLocaleDateString(localeTag(), withYear ? { month: 'long', year: 'numeric' } : { month: 'long' });
    } catch (_) { return String(ym || ''); }
  }

  /* ── Card 3 · Loyalty: on/off and up to three tiers ───────────────── */

  function saveTiers(next) {
    settings.loyaltyTiers = KhaytLoyalty.cleanTiers(next);
    saveAll();
    // Both editors are drawn from the same list; Professional's re-renders this one.
    if (typeof renderLoyaltyTiersSettings === 'function') renderLoyaltyTiersSettings();
    else renderSimpleLoyalty();
  }

  /** Set while one row's edit is saved, so the save does not redraw the card. */
  let _holdSimple = false;

  function renderSimpleLoyalty() {
    if (_holdSimple) return;
    const host = document.getElementById('loyaltySimple');
    if (!host || !S()) return;
    const on = !!settings.loyaltyEnabled;
    const view = S().loyaltyView(settings.loyaltyTiers);
    const row = (r) => r.readOnly
      ? `<tr class="sm-loy-row is-readonly" data-idx="${r.index}">
          <th scope="row">${esc(r.name)}</th>
          <td>${esc(t('sm.loy_after', { n: r.minOrders }))}</td>
          <td>${esc(r.discountPct)} %</td>
          <td class="sm-loy-act"><span class="sm-loy-ro">${esc(t('sm.loy_readonly'))}</span></td>
        </tr>`
      : `<tr class="sm-loy-row" data-idx="${r.index}">
          <th scope="row"><input type="text" class="sm-loy-in sm-loy-name" value="${esc(r.name)}" aria-label="${esc(t('sm.loy_col_tier'))}" maxlength="40"></th>
          <td><span class="sm-loy-after"><input type="number" class="sm-loy-in sm-loy-orders" value="${r.minOrders}" min="0" step="1" inputmode="numeric" aria-label="${esc(t('sm.loy_col_after'))}"> <span>${esc(t('sm.loy_orders_unit'))}</span></span></td>
          <td><span class="sm-loy-after"><input type="number" class="sm-loy-in sm-loy-disc" value="${r.discountPct}" min="0" max="100" step="0.5" inputmode="decimal" aria-label="${esc(t('sm.loy_col_discount'))}"> <span>%</span></span></td>
          <td class="sm-loy-act"><button type="button" class="btn ghost small sm-link" data-act="loy-remove">${esc(t('sm.loy_remove'))}</button></td>
        </tr>`;
    host.innerHTML = `
      <div class="sm-head">
        <div class="sm-head-text">
          <h3 class="sm-title" id="loyaltySimpleTitle">${esc(t('sm.loy_title'))}</h3>
          <p class="sm-sub">${esc(t('sm.loy_sub'))}</p>
        </div>
        <button type="button" class="sm-pill-switch" role="switch" aria-checked="${on}" aria-labelledby="loyaltySimpleTitle" data-act="loy-toggle">${esc(t(on ? 'sm.loy_on' : 'sm.loy_off'))}</button>
      </div>
      ${view.count ? `<div class="sm-box"><table class="sm-loy-table">
        <thead><tr>
          <th scope="col">${esc(t('sm.loy_col_tier'))}</th>
          <th scope="col">${esc(t('sm.loy_col_after'))}</th>
          <th scope="col">${esc(t('sm.loy_col_discount'))}</th>
          <th scope="col"><span class="sm-vh">${esc(t('common.actions'))}</span></th>
        </tr></thead>
        <tbody>${view.rows.map(row).join('')}</tbody>
      </table></div>` : `<p class="sm-empty">${esc(t('sm.loy_empty'))}</p>`}
      <div class="sm-foot">
        <span class="sm-sub" id="loyaltySimpleCount">${esc(view.count > view.max ? t('sm.loy_count_over', { n: view.count }) : t('sm.loy_count', { n: view.count, max: view.max }))}</span>
        <button type="button" class="btn small sm-pill-btn" data-act="loy-add"${view.canAdd ? '' : ' disabled'}>${esc(t('sm.loy_add'))}</button>
      </div>`;

    host.querySelector('[data-act="loy-toggle"]').addEventListener('click', () => {
      settings.loyaltyEnabled = !settings.loyaltyEnabled;
      // The pane's own Save reads this box, so it must agree.
      const box = document.getElementById('set_loyaltyEnabled');
      if (box) box.checked = settings.loyaltyEnabled;
      saveAll();
      renderSimpleLoyalty();
      host.querySelector('[data-act="loy-toggle"]')?.focus();
    });
    host.querySelector('[data-act="loy-add"]').addEventListener('click', () => {
      const tiers = settings.loyaltyTiers || [];
      saveTiers(S().addTier(tiers, t('sm.loy_new_name', { n: tiers.length + 1 })));
      document.querySelector('#loyaltySimple tbody tr:last-child .sm-loy-name')?.select();
    });
    host.querySelectorAll('tr.sm-loy-row:not(.is-readonly)').forEach((tr) => {
      const idx = +tr.dataset.idx;
      tr.querySelector('[data-act="loy-remove"]').addEventListener('click', () => {
        saveTiers(S().removeTier(settings.loyaltyTiers || [], idx));
      });
      // An edit saves where it stands: the row is not redrawn under the cursor
      // (Tab from the name to the discount keeps its place); only what the
      // save changed — a trimmed name, a clamped number — is written back.
      const commit = () => {
        _holdSimple = true;
        try {
          saveTiers(S().editTier(settings.loyaltyTiers || [], idx, {
            name: tr.querySelector('.sm-loy-name').value,
            minOrders: tr.querySelector('.sm-loy-orders').value,
            discountPct: tr.querySelector('.sm-loy-disc').value,
          }));
        } finally { _holdSimple = false; }
        const saved = (settings.loyaltyTiers || [])[idx];
        if (!saved) { renderSimpleLoyalty(); return; }
        const put = (sel, v) => { const el = tr.querySelector(sel); if (el && el.value !== String(v)) el.value = v; };
        put('.sm-loy-name', saved.name);
        put('.sm-loy-orders', saved.minOrders);
        put('.sm-loy-disc', saved.discountPct);
      };
      tr.querySelectorAll('input').forEach((inp) => inp.addEventListener('change', commit));
    });
  }

  /* ── Card 4 · Expenses: a short list ──────────────────────────────── */

  function openSimpleExpense() {
    const cats = (typeof EXP_CATEGORIES !== 'undefined' ? EXP_CATEGORIES : ['other']);
    const profile = (typeof KhaytTax !== 'undefined') ? KhaytTax.profileFromSettings(settings) : null;
    const reclaims = !!(profile && profile.rates && profile.rates.length);
    const today = localDateStr();
    openFormModal({
      title: t('sm.exp_add'),
      sizeLg: false,
      saveLabel: t('sm.exp_add'),
      bodyHtml: `
        <label for="smExpAmount">${esc(t('exp.amount'))} (${esc(currencySymbol())})</label>
        <input type="number" id="smExpAmount" min="0" step="0.01" inputmode="decimal" placeholder="0.00" required>
        <label for="smExpNote" style="margin-top:12px;">${esc(t('sm.exp_what'))}</label>
        <input type="text" id="smExpNote" maxlength="120">
        <label for="smExpCategory" style="margin-top:12px;">${esc(t('exp.category'))}</label>
        <select id="smExpCategory">${cats.map((c) => `<option value="${esc(c)}">${esc(expCatLabel(c))}</option>`).join('')}</select>
        <label for="smExpDate" style="margin-top:12px;">${esc(t('exp.date'))}</label>
        <input type="date" id="smExpDate" value="${esc(today)}" max="${esc(today)}">
        ${reclaims ? `<label for="smExpVat" style="margin-top:12px;">${esc(t('exp.vat_paid'))}</label>
        <input type="number" id="smExpVat" min="0" step="0.01" inputmode="decimal" placeholder="0.00">
        <div class="hint">${esc(t('exp.vat_paid_hint'))}</div>` : ''}`,
      onSave(modal) {
        const made = KhaytExpenseBook.newExpense({
          amount: modal.querySelector('#smExpAmount').value,
          vatAmount: modal.querySelector('#smExpVat')?.value,
          date: modal.querySelector('#smExpDate').value,
          category: modal.querySelector('#smExpCategory').value,
          note: modal.querySelector('#smExpNote').value,
        }, { id: uid('EXP'), today: localDateStr() });
        if (made.refused) { toast(t('exp.amount_required'), 'error'); return false; }
        expenses.unshift(made.expense);
        saveAll();
        renderExpenses();
        toast(t('exp.added'), 'success');
        return true;
      },
    });
  }

  function renderSimpleExpenses() {
    const host = document.getElementById('expSimple');
    if (!host || !S()) return;
    const view = S().expensesThisMonth(expenses, localDateStr());
    host.innerHTML = `
      <div class="sm-card">
        <div class="sm-head">
          <div class="sm-head-text">
            <h2 class="sm-title sm-title-lg">${esc(t('tab.expenses'))}</h2>
            <p class="sm-sub" id="expSimpleTotal">${esc(t('sm.exp_month', { month: monthName(view.month), total: fmtPrice(view.total).replace(fmtMoney(view.total), money2(view.total)) }))}</p>
          </div>
          <button type="button" class="btn primary sm-pill-btn" id="btnSimpleAddExpense">${esc(t('sm.exp_add'))}</button>
        </div>
        ${view.count ? `<ul class="sm-box sm-list" id="expSimpleList">${view.rows.map((e) => `
          <li class="sm-list-row" data-expense-id="${esc(e.id)}">
            <div class="sm-list-text">
              <span class="sm-list-name">${esc(e.note || expCatLabel(e.category))}</span>
              <span class="sm-list-meta">${esc(dayMonth(e.date))} · ${esc(expCatLabel(e.category))}</span>
            </div>
            <span class="sm-num">${esc(money2(e.amount))}</span>
            <button type="button" class="btn ghost small sm-row-del" data-act="sm-exp-del" aria-label="${esc(t('common.delete'))}" title="${esc(t('common.delete'))}">×</button>
          </li>`).join('')}</ul>`
          : `<p class="sm-empty">${esc(t('sm.exp_empty'))}</p>`}
      </div>`;
    host.querySelector('#btnSimpleAddExpense').addEventListener('click', openSimpleExpense);
    host.querySelectorAll('[data-act="sm-exp-del"]').forEach((b) => {
      b.addEventListener('click', () => deleteExpense(b.closest('[data-expense-id]').dataset.expenseId));
    });
  }

  /* ── Card 5 · Money: one page ─────────────────────────────────────── */

  /** Open the orders log on the jobs behind a figure. */
  function openJobs({ status = '', pay = '', range = 'all', clientId = '' } = {}) {
    if (typeof clearLogFilters === 'function') clearLogFilters();
    logStatusFilter = status;
    logPayFilter = pay;
    logRangeFilter = range;
    logClientFilter = clientId;
    const set = (id, v) => { const el = document.getElementById(id); if (el) el.value = v; };
    set('logStatusFilter', status);
    set('logPayFilter', pay);
    set('logRangeFilter', range);
    switchTab('logs-tab');
    set('logClientFilter', clientId);
    if (typeof renderLogs === 'function') renderLogs();
  }

  function renderMoneyPage(wrap) {
    if (!wrap || !S()) return;
    const today = localDateStr();
    const m = S().moneySummary({
      orders: printLog, expenses,
      clients: typeof clients !== 'undefined' ? clients : [],
      products: typeof products !== 'undefined' ? products : [],
    }, {
      settings, today, now: new Date(),
      currencies: (typeof KhaytCurrencies !== 'undefined' && KhaytCurrencies.CURRENCIES) || undefined,
      language: (typeof i18n !== 'undefined' && i18n.current) || 'en',
      revenueOf: orderNetRevenueBase,
    });
    const tile = (id, label, value, sub, opts) => {
      const o = opts || {};
      const inner = `<span class="sm-tile-label">${esc(label)}</span>
        <span class="sm-tile-value">${esc(value)}</span>
        <span class="sm-tile-sub${o.warn ? ' is-warn' : ''}">${esc(sub)}</span>`;
      return o.act
        ? `<button type="button" class="sm-tile" id="${id}" data-act="${o.act}">${inner}</button>`
        : `<div class="sm-tile" id="${id}">${inner}</div>`;
    };
    let vatTile = '';
    if (m.vat) {
      const label = t(/^\d{4}-Q/.test(m.vat.period) ? 'sm.money_vat_q' : 'sm.money_vat_m', { tax: m.vat.taxName });
      const period = typeof vatPeriodLabel === 'function' ? vatPeriodLabel(m.vat.period) : m.vat.period;
      const sub = m.vat.deadline ? t('sm.money_vat_by', { period, date: dayMonth(m.vat.deadline) }) : period;
      vatTile = tile('moneyVat', label, money0(m.vat.due), sub);
    }
    const list = (id, head, rows, empty) => `
      <section class="sm-money-list" aria-labelledby="${id}H">
        <h3 class="sm-eyebrow" id="${id}H">${esc(head)}</h3>
        ${rows.length ? `<ul id="${id}">${rows.join('')}</ul>` : `<p class="sm-empty">${esc(empty)}</p>`}
      </section>`;
    const line = (name, value, act, attrs) => act
      ? `<li><button type="button" class="sm-line" data-act="${act}" ${attrs || ''}><span>${esc(name)}</span><span class="sm-num">${esc(value)}</span></button></li>`
      : `<li><span class="sm-line"><span>${esc(name)}</span><span class="sm-num">${esc(value)}</span></span></li>`;

    wrap.innerHTML = `
      <div class="sm-card sm-money" id="moneyPage">
        <h2 class="sm-title sm-title-lg">${esc(t('sm.money_title'))}</h2>
        <p class="sm-sub">${esc(monthName(m.month, true))}</p>
        <div class="sm-tiles">
          ${tile('moneyEarned', t('sm.money_earned'), money0(m.earned.total), plural(m.earned.jobs, 'sm.money_from_jobs_one', 'sm.money_from_jobs'), { act: 'money-earned' })}
          ${tile('moneyOwed', t('sm.money_owed'), money0(m.owed.total), m.owed.overdue ? plural(m.owed.overdue, 'sm.money_overdue_one', 'sm.money_overdue') : t('sm.money_none_overdue'), { act: 'money-owed', warn: m.owed.overdue > 0 })}
          ${tile('moneySpent', t('sm.money_spent'), money0(m.spent.total), plural(m.spent.count, 'sm.money_expenses_one', 'sm.money_expenses'), { act: 'money-spent' })}
          ${vatTile}
        </div>
        <div class="sm-money-lists">
          ${list('moneyWhoOwes', t('sm.money_who_owes'), m.whoOwes.map((r) => line(r.name, money2(r.owed), r.clientId ? 'money-client-owes' : '', r.clientId ? `data-client="${esc(r.clientId)}"` : '')), t('sm.money_nobody_owes'))}
          ${list('moneyBest', t('sm.money_best'), m.bestCustomers.map((r) => line(r.name, money0(r.revenue), 'money-client-year', `data-client="${esc(r.clientId)}"`)), t('sm.money_no_sales'))}
        </div>
        ${list('moneyTop', t('sm.money_top'), m.topProducts.map((r) => line(r.name, plural(r.count, 'sm.money_jobs_one', 'sm.money_jobs'))), t('sm.money_no_products'))}
      </div>`;

    wrap.querySelector('#moneyPage').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-act]');
      if (!b) return;
      const act = b.dataset.act;
      if (act === 'money-earned') openJobs({ status: 'completed', range: 'month' });
      else if (act === 'money-owed') openJobs({ pay: 'unpaid' });
      else if (act === 'money-spent') switchTab('expenses-tab');
      else if (act === 'money-client-owes') openJobs({ clientId: b.dataset.client });
      else if (act === 'money-client-year') openJobs({ status: 'completed', range: 'year', clientId: b.dataset.client });
    });
  }

  /** Simple's name for the Analytics tab is Money (SIMPLE_MAP `money`). */
  function syncMoneyNavLabel() {
    const label = document.querySelector('.tab-btn[data-tab="analytics-tab"] .nav-label');
    if (!label) return;
    const key = isSimple() ? 'sm.money_title' : 'tab.analytics';
    label.setAttribute('data-i18n', key);
    label.textContent = t(key);
  }

  Object.assign(window, { renderSimpleLoyalty, renderSimpleExpenses, renderMoneyPage, syncMoneyNavLabel });
})();
