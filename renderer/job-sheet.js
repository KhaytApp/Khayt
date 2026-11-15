/**
 * The job edit sheet (S1 · desktop M4): Job · Parts · Price, with the total
 * pinned at the foot. Figma 7Iqw0GcrLLRW7CLDEhTa1P: sheet 75:583, the
 * keep-or-new price question 95:461, the refusal line 95:596.
 *
 * EVERY SAVE IS ONE CALL TO `lib/order-edit.js applyJobEdit`: customer, name,
 * parts, details, a typed total — all or nothing, with the same refusals the
 * Mac and the iPhone give. Before Save the same call runs on a COPY on every
 * change, so the total at the foot and the refusal line are the rule's own
 * answer, not this file's arithmetic.
 *
 * A part is costed the way every other part in Khayt is: `lib/print-rates.js
 * withRates` (the shop's rates, the machine's wear and power) under the part,
 * then `lib/calculator-cost.js computePartBaseCost`. A part whose cost fields
 * did not change keeps the cost it was frozen at — `applyParts` sees to that.
 *
 * What the sheet does not hold yet (shipping, extra lines, rush fee, files,
 * photos, payments, instalments…) stays in the existing job editor, one click
 * away under the price.
 *
 * Opened from the job page's Edit.
 */
(function (global) {
  'use strict';

  const ED = () => global.KhaytOrderEdit;
  const PR = () => global.KhaytPrintRates;
  const CC = () => global.KhaytCalculatorCost;
  const Money = () => global.KhaytOrderMoney;

  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  // The book's arrays are top-level `let`s in the renderer, not window properties.
  const list = (name) => {
    try {
      const v = { inventory: () => inventory, machines: () => machines, clients: () => clients, printLog: () => printLog }[name]();
      return Array.isArray(v) ? v : [];
    } catch (_) { return []; }
  };
  const hrs = (h) => { const x = Math.max(0, +h || 0); return x ? `${Math.floor(x)}h ${Math.round((x % 1) * 60)}m` : ''; };

  /** The spool a filament is costed off: its SIZE, not what is left of it (see populateFilamentDropdown). */
  function filamentFields(id) {
    const item = list('inventory').find((i) => i.id === id);
    if (!item) return null;
    return {
      filamentId: item.id,
      material: item.material || '',
      spoolCost: typeof spoolCostBasis === 'function' ? spoolCostBasis(item) : Math.max(0, +item.cost || 0),
      spoolWeight: Math.max(1, +item.spoolWeight || 1000),
    };
  }

  /** A part costed today, at the rates it is costed at everywhere else. */
  function costed(part, order) {
    const machine = list('machines').find((m) => m.id === (part.machineId || order.machineId));
    const rated = PR() ? PR().withRates(part, { settings, machine }) : Object.assign({}, part);
    const unit = CC() ? CC().computePartBaseCost(rated, { inventory: list('inventory'), settings }) : 0;
    rated.unitCost = +unit.toFixed(4);
    rated.baseCost = +(unit * Math.max(1, Math.round(+rated.qty || 1))).toFixed(2);
    return rated;
  }

  function openJobSheet(orderId) {
    const order = list('printLog').find((o) => o.id === orderId);
    if (!order || !ED() || typeof openFormModal !== 'function') return;
    const lock = ED().partsLock(order);
    const custLock = order.clientId ? ED().customerLocked(order) : null;
    const st = {
      parts: (order.parts || []).map((p) => JSON.parse(JSON.stringify(p))),
      touched: false,
      editing: -1,
      keepPrice: undefined,
    };
    const ref = typeof jobRef === 'function' ? jobRef(order) : order.id;
    const level = ED().priorityOf ? ED().priorityOf(order) : (order.priorityLevel || 'normal');
    const field = (label, inner, cls) => `<label class="js-field ${cls || ''}"><span>${escapeHtml(label)}</span>${inner}</label>`;
    const clientOpts = [`<option value="">${escapeHtml(t('js.no_customer'))}</option>`]
      .concat(list('clients').map((c) => `<option value="${escapeHtml(c.id)}"${c.id === order.clientId ? ' selected' : ''}>${escapeHtml(localName(c) || c.id)}</option>`)).join('');
    const filOpts = list('inventory').map((i) => `<option value="${escapeHtml(i.id)}">${escapeHtml(i.material || i.id)}</option>`).join('');
    const marg = ED().marginOf(order);

    const bodyHtml = `<div class="job-sheet">
      <div class="js-sub">${escapeHtml(ref)}${order.project ? ' · ' + escapeHtml(order.project) : ''}</div>
      <h4 class="js-sec">${escapeHtml(t('js.sec_job'))}</h4>
      ${field(t('js.name'), `<input type="text" data-js="project" value="${escapeHtml(order.project || '')}">`)}
      <div class="js-row">
        ${field(t('js.customer'), `<select data-js="clientId"${custLock ? ' disabled' : ''}>${clientOpts}</select>
          ${custLock ? `<small class="js-hint">${escapeHtml(typeof oeCustomerReasonText === 'function' ? oeCustomerReasonText(custLock) : '')}</small>` : ''}`)}
        ${field(t('js.due'), `<input type="date" data-js="dueDate" value="${escapeHtml(order.dueDate || '')}">`)}
      </div>
      <div class="js-field"><span>${escapeHtml(t('js.priority'))}</span>
        <div class="js-seg" role="radiogroup" aria-label="${escapeHtml(t('js.priority'))}">
          ${['normal', 'high', 'urgent'].map((l) => `<button type="button" role="radio" data-js-pr="${l}" aria-checked="${l === level}" class="${l === level ? 'on' : ''}">${escapeHtml(t('js.pr_' + l))}</button>`).join('')}
        </div></div>
      ${field(t('js.notes'), `<input type="text" data-js="notes" value="${escapeHtml(order.notes || '')}">`)}
      <h4 class="js-sec" data-js="partsHead"></h4>
      <div class="js-parts" data-js="parts"></div>
      ${lock.edit ? `<div class="js-add" data-js="addRow">
        ${field(t('js.part'), `<input type="text" data-js="pName" placeholder="${escapeHtml(t('js.name'))}">`)}
        ${field(t('js.filament'), `<select data-js="pFil">${filOpts}</select>`)}
        ${field(t('js.grams'), `<input type="number" min="0" step="any" data-js="pGrams" value="0">`)}
        ${field(t('js.hours'), `<input type="number" min="0" step="any" data-js="pHours" value="0">`)}
        ${field(t('js.qty'), `<input type="number" min="1" step="1" data-js="pQty" value="1">`)}
        <button type="button" class="btn" data-js="pAdd">${escapeHtml(t('js.add_part'))}</button>
      </div>` : `<p class="js-hint">${escapeHtml(t('js.parts_locked'))}</p>`}
      <h4 class="js-sec">${escapeHtml(t('js.sec_price'))}</h4>
      <div class="js-row">
        <div class="js-field"><span>${escapeHtml(t('js.markup'))}</span><div class="js-static" data-js="markup">${escapeHtml(marg === null ? t('jp.margin_typed') : marg + ' %')}</div></div>
        ${field(t('js.discount'), `<input type="number" min="0" max="100" step="any" data-js="discountPct" value="${escapeHtml(String(+order.discountPct || 0))}">`)}
        ${field(t('js.set_price'), `<input type="number" min="0" step="any" data-js="price" placeholder="${escapeHtml(t('js.auto'))}">`)}
      </div>
      <button type="button" class="linkish js-more" data-js="more">› ${escapeHtml(t('js.more'))}</button>
    </div>`;

    let modal = null;
    const q = (k) => modal.querySelector(`[data-js="${k}"]`);
    const priority = () => modal.querySelector('[data-js-pr].on')?.dataset.jsPr || level;

    /** What is changing, named only when it changed (applyJobEdit's contract). */
    function nextOf() {
      const n = {};
      const proj = q('project').value.trim();
      if (proj !== (order.project || '')) n.project = proj;
      const cid = q('clientId').value || null;
      if (!custLock && cid !== (order.clientId || null)) n.clientId = cid;
      const due = q('dueDate').value || null;
      if (due !== (order.dueDate || null)) n.dueDate = due;
      if (priority() !== level) n.priorityLevel = priority();
      const notes = q('notes').value;
      if (notes !== (order.notes || '')) n.notes = notes;
      const disc = Math.min(100, Math.max(0, num(q('discountPct').value)));
      if (disc !== (+order.discountPct || 0)) n.discountPct = disc;
      if (st.touched) n.parts = st.parts;
      const typed = q('price').value.trim();
      if (typed !== '') n.price = Math.max(0, num(typed));
      return n;
    }
    const ctxOf = (extra) => Object.assign({
      now: Date.now(), id: uid('edit'), priceId: uid('edit'), settings, clients: list('clients'), nameOf: localName,
      ids: st.parts.filter((p) => !p.id).map(() => uid('PRT')),
    }, extra || {});
    /** The rule's answer on a copy: the job as it would be, or why not. */
    function dryRun(extra) {
      const trial = JSON.parse(JSON.stringify(order));
      const verdict = ED().applyJobEdit(trial, nextOf(), ctxOf(Object.assign({ keepPrice: st.keepPrice }, extra || {})));
      return { verdict, trial };
    }
    const billed = (o) => (Money() && Money().orderGrossRaw ? Money().orderGrossRaw(o, { settings }) : +o.price || 0);
    const priceText = (n) => (typeof fmtOrderPrice === 'function' ? fmtOrderPrice(n, order) : fmtMoney(n));
    function reasonText(v) {
      if (v.reason === 'paid_exceeds_price') return t('oe.paid_exceeds_price', { paid: priceText(+order.paidAmount || 0) });
      if (v.step === 'customer') return typeof oeCustomerReasonText === 'function' ? oeCustomerReasonText(v.reason) : t('js.refused_other');
      if (['name_only', 'delivered_part', 'no_parts'].includes(v.reason)) return t('js.refused_' + v.reason);
      if (['zatca', 'voided', 'credited', 'cancelled'].includes(v.reason)) return t('js.parts_locked');
      return t('js.refused_other');
    }

    function drawParts() {
      q('partsHead').textContent = t('js.sec_parts', { n: st.parts.length });
      q('parts').innerHTML = st.parts.length ? st.parts.map((p, i) => {
        const g = +p.printWeight || 0;
        const sub = [`×${Math.max(1, +p.qty || 1)}`, p.material || '', g ? `${Math.round(g)} g` : '', hrs(p.printTime)].filter(Boolean).join(' · ');
        const delivered = p.delivered === true;
        return `<div class="js-part${st.editing === i ? ' is-editing' : ''}" data-i="${i}">
          <div><div class="js-part-name">${escapeHtml(p.name || '—')}</div><div class="js-hint">${escapeHtml(sub)}</div></div>
          <div class="js-part-acts">
            ${lock.edit && !delivered ? `<button type="button" class="linkish" data-js-edit="${i}">${escapeHtml(t('js.edit_part'))}</button>` : ''}
            ${lock.addRemove && !delivered ? `<button type="button" class="linkish" data-js-rm="${i}">${escapeHtml(t('js.remove_part'))}</button>` : ''}
          </div></div>`;
      }).join('') : `<p class="js-hint">${escapeHtml(t('jp.no_parts'))}</p>`;
      const row = q('addRow');
      if (row) {
        // A finished job: a part's name only, and no new part.
        const nameOnly = lock.nameOnly;
        row.hidden = !lock.addRemove && st.editing === -1;
        for (const k of ['pFil', 'pGrams', 'pHours', 'pQty']) q(k).disabled = nameOnly;
        q('pAdd').textContent = t(st.editing === -1 ? 'js.add_part' : 'js.update_part');
      }
    }

    function refresh() {
      const { verdict, trial } = dryRun();
      const line = modal.parentElement.querySelector('.js-refused') || (() => {
        const p = document.createElement('p');
        p.className = 'oe-refused js-refused';
        p.setAttribute('role', 'alert');
        modal.insertBefore(p, modal.querySelector('.modal-footer'));
        return p;
      })();
      line.textContent = verdict.ok ? '' : reasonText(verdict);
      line.hidden = verdict.ok;
      modal.querySelector('[data-act="save"]').disabled = !verdict.ok;
      modal.querySelector('[data-js="total"]').textContent = priceText(billed(verdict.ok ? trial : order));
    }

    function loadRow(i) {
      const p = st.parts[i];
      st.editing = i;
      q('pName').value = p.name || '';
      if (p.filamentId && list('inventory').some((x) => x.id === p.filamentId)) q('pFil').value = p.filamentId;
      q('pGrams').value = String(+p.printWeight || 0);
      q('pHours').value = String(+p.printTime || 0);
      q('pQty').value = String(Math.max(1, +p.qty || 1));
      drawParts();
      q('pName').focus();
    }

    function takeRow() {
      const name = q('pName').value.trim() || t('calc.part.name_ph');
      const grams = Math.max(0, num(q('pGrams').value));
      const hours = Math.max(0, num(q('pHours').value));
      const qty = Math.max(1, Math.round(num(q('pQty').value) || 1));
      const filId = q('pFil').value;
      if (st.editing === -1) {
        const fil = filamentFields(filId) || {};
        st.parts.push(costed(Object.assign({ name, printWeight: grams, printTime: hours, qty }, fil), order));
      } else {
        const old = st.parts[st.editing];
        let p = Object.assign({}, old, { name });
        if (!lock.nameOnly) {
          const filChanged = filId && filId !== old.filamentId;
          Object.assign(p, { printWeight: grams, printTime: hours, qty }, filChanged ? filamentFields(filId) : {});
          const moved = filChanged || grams !== (+old.printWeight || 0) || hours !== (+old.printTime || 0) || qty !== Math.max(1, +old.qty || 1);
          if (moved) p = costed(p, order);
        }
        st.parts[st.editing] = p;
      }
      st.touched = true;
      st.editing = -1;
      q('pName').value = ''; q('pGrams').value = '0'; q('pHours').value = '0'; q('pQty').value = '1';
      drawParts();
      refresh();
    }

    /** The customer has seen the price (Figma 95:461): keep it, or use the new one. Resolves true/false, or null when closed. */
    function askKeep(was, now) {
      return new Promise((resolve) => {
        const overlay = appendStackedModal(`<div class="modal js-ask" role="dialog" aria-modal="true" aria-labelledby="jsAskTitle">
          <h3 id="jsAskTitle">${escapeHtml(t('js.ask_title'))}</h3>
          <div class="js-sub">${escapeHtml(ref)}${order.project ? ' · ' + escapeHtml(order.project) : ''}</div>
          <p>${escapeHtml(t('js.ask_body', { was: priceText(was), now: priceText(now) }))}</p>
          <div class="js-foot"><div><div class="js-hint">${escapeHtml(t('js.ask_saw'))}</div><div class="js-total">${escapeHtml(priceText(was))}</div></div>
            <div class="btn-row"><button type="button" class="btn" data-ask="keep">${escapeHtml(t('js.keep', { amount: priceText(was) }))}</button>
            <button type="button" class="btn primary" data-ask="new">${escapeHtml(t('js.use', { amount: priceText(now) }))}</button></div></div>
        </div>`, { zIndex: 10060 });
        const done = (v) => {
          document.removeEventListener('keydown', esc, true);
          overlay.remove();
          resolve(v);
        };
        const esc = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(null); } };
        document.addEventListener('keydown', esc, true);
        overlay.querySelector('[data-ask="keep"]').addEventListener('click', () => done(true));
        overlay.querySelector('[data-ask="new"]').addEventListener('click', () => done(false));
        overlay.addEventListener('click', (e) => { if (e.target === overlay) done(null); });
      });
    }

    openFormModal({
      title: t('js.title'),
      bodyHtml,
      onMount(m) {
        modal = m;
        modal.classList.add('job-sheet-modal');
        const footer = modal.querySelector('.modal-footer');
        footer.insertAdjacentHTML('afterbegin', `<div class="js-totalbox"><div class="js-hint">${escapeHtml(t('js.total'))}</div><div class="js-total" data-js="total"></div></div>`);
        drawParts();
        modal.addEventListener('input', (e) => { if (!e.target.closest('[data-js="addRow"]')) refresh(); });
        modal.addEventListener('change', (e) => { if (!e.target.closest('[data-js="addRow"]')) refresh(); });
        modal.addEventListener('click', (e) => {
          const pr = e.target.closest('[data-js-pr]');
          if (pr) {
            modal.querySelectorAll('[data-js-pr]').forEach((b) => { const on = b === pr; b.classList.toggle('on', on); b.setAttribute('aria-checked', String(on)); });
            refresh();
            return;
          }
          const ed = e.target.closest('[data-js-edit]');
          if (ed) { loadRow(+ed.dataset.jsEdit); return; }
          const rm = e.target.closest('[data-js-rm]');
          if (rm) {
            st.parts.splice(+rm.dataset.jsRm, 1);
            st.touched = true; st.editing = -1;
            drawParts(); refresh();
            return;
          }
          if (e.target.closest('[data-js="pAdd"]')) { takeRow(); return; }
          if (e.target.closest('[data-js="more"]')) { openOrderEditor(order.id); }
        });
        refresh();
      },
      async onSave() {
        st.keepPrice = undefined;
        // A price the customer has seen does not move under them silently.
        if (st.touched && lock.askPrice && q('price').value.trim() === '') {
          const { verdict, trial } = dryRun({ keepPrice: false });
          if (verdict.ok && Math.abs((+trial.price || 0) - (+order.price || 0)) > 0.005) {
            const keep = await askKeep(+order.price || 0, +trial.price || 0);
            if (keep === null) return false;
            st.keepPrice = keep;
          }
        }
        const verdict = ED().applyJobEdit(order, nextOf(), ctxOf({ keepPrice: st.keepPrice }));
        if (!verdict.ok) { refresh(); return false; }
        if (verdict.changed) {
          saveAll();
          if (typeof renderLogs === 'function') renderLogs();
          if (typeof renderDashboard === 'function') renderDashboard();
          toast(t('common.save'), 'success');
        }
        return true;
      },
    });
  }

  Object.assign(global, { openJobSheet });
})(typeof window !== 'undefined' ? window : globalThis);
