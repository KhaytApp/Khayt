/**
 * The payment plan dialog (S1, old-editor retirement step 6; Figma 108:1593,
 * 108:1688, rules 108:1783). Opened from the job page's Money card.
 *
 * MONEY. The plan is the schedule; this file does no arithmetic of its own:
 *   - saving is lib/payment-plan.js applyPlan, which never touches paidAmount,
 *     refuses a plan over what is owed, and locks paid rows;
 *   - "Three monthly payments" is monthlyPlan over what is OWED (owedNow);
 *   - a row is paid only by Record payment: recordRowPayment, which records
 *     the money through lib/order-payment.js recordPayment (its clamp, its
 *     status) and hands back recordPayment's effects, run as the payment
 *     dialog runs them (runPaymentEffects).
 * A row ticked paid in an older book is shown as what it is, "marked paid (no
 * payment recorded)", and stays paid and locked (Dev Hub, Nov 18).
 */
(function (global) {
  'use strict';

  const PP = () => global.KhaytPaymentPlan;
  const METHODS = ['cash', 'mada', 'transfer', 'stcpay', 'applepay', 'visa', 'other'];
  const byId = (id) => (typeof printLog !== 'undefined' ? printLog.find((o) => o && o.id === id) : null) || null;
  const ctxOf = () => ({ settings, today: localDateStr() });
  const REASONS = ['over_owed', 'paid_row_locked', 'paid_needs_payment', 'bad_amount', 'over_billed', 'already_paid', 'zatca', 'voided', 'credited', 'cancelled'];
  // t() answers the KEY for a missing one, so `t(k) || x` never falls back: name the known reasons.
  const reasonText = (r) => t(REASONS.includes(r.reason) ? 'ppd.refused.' + r.reason : 'js.refused_other', { over: fmt(r.over || 0) });
  let fmt = (n) => String(n);

  function openPaymentPlanDialog(orderId) {
    const order = byId(orderId);
    if (!order || !PP() || typeof openFormModal !== 'function') return;
    fmt = (n) => (typeof fmtOrderPrice === 'function' ? fmtOrderPrice(n, order) : fmtMoney(n));
    // The rows as the dialog holds them; written only by Save (applyPlan).
    let rows = (order.instalments || []).filter(Boolean).map((r) => Object.assign({}, r));
    let modal = null;

    const stateLine = (r) => {
      const st = PP().rowState(r);
      if (st === 'recorded') return t('ppd.paid_recorded', { date: r.paidAt || '', method: r.method ? t('pay.method.' + r.method) : '' });
      if (st === 'legacy') return t('ppd.paid_legacy', { date: r.paidAt || '' });
      return t('ppd.not_paid');
    };

    function trial() {
      const copy = JSON.parse(JSON.stringify(order));
      return PP().applyPlan(copy, rows, ctxOf());
    }

    function draw() {
      const list = modal.querySelector('[data-pp="rows"]');
      list.innerHTML = rows.length ? rows.map((r, i) => {
        const locked = !!r.paid;
        return `<div class="js-part pp-row${locked ? ' is-paid' : ''}" data-i="${i}">
          <div class="pp-fields">
            <div class="js-part-name">${i + 1} · ${locked ? escapeHtml(t('ppd.due', { date: r.dueDate || '—' })) : ''}</div>
            ${locked ? '' : `<div class="js-row">
              <label class="js-field"><span>${escapeHtml(t('ppd.amount'))}</span><input type="number" min="0" step="0.01" data-pp-amt="${i}" value="${escapeHtml(String(r.amount || 0))}"></label>
              <label class="js-field"><span>${escapeHtml(t('ppd.due_date'))}</span><input type="date" data-pp-due="${i}" value="${escapeHtml(r.dueDate || '')}"></label>
              <label class="js-field"><span>${escapeHtml(t('inst.note'))}</span><input type="text" data-pp-note="${i}" value="${escapeHtml(r.note || '')}"></label>
            </div>`}
            <div class="js-hint">${escapeHtml(stateLine(r))}</div>
          </div>
          <div class="js-part-acts">
            ${locked ? `<span class="js-amt">${escapeHtml(fmt(+r.amount || 0))}</span>` : `
              <button type="button" class="linkish" data-pp="record" data-i="${i}">${escapeHtml(t('ppd.record'))}</button>
              <button type="button" class="linkish" data-pp="remove" data-i="${i}">${escapeHtml(t('jpc.remove'))}</button>`}
          </div></div>`;
      }).join('') : `<p class="js-hint">${escapeHtml(t('ppd.empty'))}</p>`;
      summary();
    }

    function summary() {
      const r = trial();
      const open = PP().round2(rows.filter((x) => !x.paid).reduce((s, x) => s + (+x.amount || 0), 0));
      const line = modal.querySelector('[data-pp="summary"]');
      line.textContent = r.ok ? t('ppd.adds_up', { open: fmt(open), owed: fmt(PP().owedNow(order, ctxOf())) }) : reasonText(r);
      line.classList.toggle('is-refused', !r.ok);
      modal.querySelector('[data-act="save"]').disabled = !r.ok;
      modal.querySelector('[data-pp="left"]').textContent = fmt(open);
    }

    /** Collect one row: the plan is saved first (applyPlan), then the payment is recorded (recordRowPayment). */
    async function record(i) {
      const row = rows[i];
      if (!row) return;
      const method = await askMethod(row);
      if (!method) return;
      const saved = PP().applyPlan(order, rows, ctxOf());
      if (!saved.ok) { toast(reasonText(saved), 'error', 6000); return; }
      const r = PP().recordRowPayment(order, row.id, { method: method.method, paidAt: method.paidAt }, ctxOf());
      if (!r.ok) { toast(reasonText(r), 'error', 6000); return; }
      if (typeof runPaymentEffects === 'function') runPaymentEffects(order, r.effects); else saveAll();
      rows = (order.instalments || []).map((x) => Object.assign({}, x));
      draw();
    }

    /** How and when this row was paid. Resolves { method, paidAt } or null. */
    function askMethod(row) {
      return new Promise((resolve) => {
        const overlay = appendStackedModal(`<div class="modal js-ask" role="dialog" aria-modal="true" aria-labelledby="ppRecTitle">
          <h3 id="ppRecTitle">${escapeHtml(t('ppd.record_title', { amount: fmt(+row.amount || 0) }))}</h3>
          <p class="js-hint">${escapeHtml(t('ppd.record_hint'))}</p>
          <div class="js-row">
            <label class="js-field"><span>${escapeHtml(t('ppd.method'))}</span><select data-pp="method">${METHODS.map((m) => `<option value="${m}">${escapeHtml(t('pay.method.' + m))}</option>`).join('')}</select></label>
            <label class="js-field"><span>${escapeHtml(t('ppd.date'))}</span><input type="date" data-pp="paidAt" value="${escapeHtml(localDateStr())}"></label>
          </div>
          <div class="btn-row"><button type="button" class="btn ghost" data-ask="cancel">${escapeHtml(t('common.cancel'))}</button>
            <button type="button" class="btn primary" data-ask="ok">${escapeHtml(t('ppd.record'))}</button></div>
        </div>`, { zIndex: 10060 });
        const done = (v) => { document.removeEventListener('keydown', esc, true); overlay.remove(); resolve(v); };
        const esc = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(null); } };
        document.addEventListener('keydown', esc, true);
        overlay.querySelector('[data-ask="cancel"]').addEventListener('click', () => done(null));
        overlay.querySelector('[data-ask="ok"]').addEventListener('click', () => done({
          method: overlay.querySelector('[data-pp="method"]').value,
          paidAt: overlay.querySelector('[data-pp="paidAt"]').value || localDateStr(),
        }));
      });
    }

    openFormModal({
      title: t('ppd.title'),
      sizeLg: false,
      bodyHtml: `<div class="job-sheet pp-dialog">
        <div class="js-sub">${escapeHtml(typeof jobRef === 'function' ? jobRef(order) : order.id)}${order.project ? ' · ' + escapeHtml(order.project) : ''}</div>
        <div class="js-parts" data-pp="rows"></div>
        <p class="js-hint pp-summary" data-pp="summary" role="status"></p>
        <div class="jp-actions">
          <button type="button" class="btn" data-pp="monthly">${escapeHtml(t('ppd.monthly'))}</button>
          <button type="button" class="btn" data-pp="add">${escapeHtml(t('ppd.add'))}</button>
        </div></div>`,
      onMount(m) {
        modal = m;
        modal.querySelector('.modal-footer').insertAdjacentHTML('afterbegin',
          `<div class="js-totalbox"><div class="js-hint">${escapeHtml(t('ppd.left'))}</div><div class="js-total" data-pp="left"></div></div>`);
        draw();
        modal.addEventListener('input', (e) => {
          const el = e.target;
          if (el.dataset.ppAmt !== undefined) rows[+el.dataset.ppAmt].amount = el.value === '' ? 0 : Number(el.value);
          else if (el.dataset.ppDue !== undefined) rows[+el.dataset.ppDue].dueDate = el.value;
          else if (el.dataset.ppNote !== undefined) rows[+el.dataset.ppNote].note = el.value;
          else return;
          summary();
        });
        modal.addEventListener('click', async (e) => {
          const b = e.target.closest('[data-pp]');
          if (!b || b.tagName !== 'BUTTON') return;
          const i = +b.dataset.i;
          if (b.dataset.pp === 'add') { rows.push({ id: uid('INS'), amount: 0, dueDate: '', note: '', paid: false, paidAt: null }); draw(); return; }
          if (b.dataset.pp === 'remove') { rows.splice(i, 1); draw(); return; }
          if (b.dataset.pp === 'record') { record(i); return; }
          if (b.dataset.pp === 'monthly') {
            const owed = PP().owedNow(order, ctxOf());
            if (owed <= 0) { toast(t((+order.price || 0) <= 0 ? 'inst.need_price' : 'inst.nothing_owed'), 'error'); return; }
            // Paid rows stay; the unpaid ones are replaced, after asking.
            if (rows.some((x) => !x.paid) && !(await confirmModal(t('inst.replace_q'), { danger: true }))) return;
            const plan = PP().monthlyPlan({ owed });
            rows = rows.filter((x) => x.paid).concat(plan.map((s) => ({ id: uid('INS'), amount: s.amount, dueDate: s.dueDate, note: '', paid: false, paidAt: null })));
            draw();
          }
        });
      },
      onSave() {
        const r = PP().applyPlan(order, rows, ctxOf());
        if (!r.ok) { summary(); return false; }
        if (r.changed) saveAll();
        return true;
      },
    });
  }

  global.openPaymentPlanDialog = openPaymentPlanDialog;
})(typeof window !== 'undefined' ? window : globalThis);
