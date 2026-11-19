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
 * Opened from the job page's Edit, and — with nothing in it — as the NEW JOB
 * sheet (Jobs › New job): the same three sections, the markup typed rather
 * than read. Whether it can be taken and the live total are the shared rules
 * `lib/order-new.js canTake` and `previewTotal` (no number allocated); the job
 * is `newOrder`'s, priced by the same arithmetic, and recorded through
 * `recordNewJob`, the one way the desktop records a new job.
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
    // A product's part (and one edited from it) keeps `orderLevelCosts`, so it
    // is costed without the labour and packaging the ORDER carries (money
    // review of #2581, HIGH: a qty 1→2 took 164.04 to 379.33). A part added by
    // hand follows the one shared rule (KhaytOrderMoney.addedPartMark): its
    // OWN labour (Turki, Nov 19). Marked BEFORE it is costed.
    const Mo = global.KhaytOrderMoney;
    if (part.orderLevelCosts === true || (Mo && Mo.addedPartMark && Mo.addedPartMark(order))) rated.orderLevelCosts = true;
    else delete rated.orderLevelCosts;
    const unit = CC() ? CC().computePartBaseCost(rated, { inventory: list('inventory'), settings }) : 0;
    rated.unitCost = +unit.toFixed(4);
    rated.baseCost = +(unit * Math.max(1, Math.round(+rated.qty || 1))).toFixed(2);
    return rated;
  }

  const NEW = () => global.KhaytOrderNew;
  const bytes = (n) => { const b = new Uint8Array(n); crypto.getRandomValues(b); return b; };
  /** The markup the calculator would use now: its own field, as typed there. */
  const calcMarkup = () => {
    const el = document.getElementById('margin');
    const v = el ? +el.value : NaN;
    return Number.isFinite(v) && v >= 0 ? v : 30;
  };

  /**
   * One sheet for New and Edit (Figma 75:583). `orderId` edits that job;
   * none opens a NEW job (`opts.clientId` to start it for a customer).
   */
  function openJobSheet(orderId, opts) {
    const isNew = !orderId;
    const order = isNew
      ? { id: null, project: '', clientId: (opts && opts.clientId) || null, dueDate: '', notes: '', parts: [], discountPct: 0 }
      : list('printLog').find((o) => o.id === orderId);
    if (!order || !ED() || typeof openFormModal !== 'function' || (isNew && !NEW())) return;
    // A new job has nothing to protect yet: every part may come and go.
    const lock = isNew ? { code: null, edit: true, addRemove: true, nameOnly: false, askPrice: false } : ED().partsLock(order, { clients: list('clients') });
    const custLock = !isNew && order.clientId ? ED().customerLocked(order) : null;
    const st = {
      parts: (order.parts || []).map((p) => JSON.parse(JSON.stringify(p))),
      touched: false,
      editing: -1,
      keepPrice: undefined,
      // The job's extra charges as the sheet holds them; sent only once touched.
      lines: (order.extraLines || []).map((l) => Object.assign({}, l)),
      linesTouched: false,
      lineEdit: -1,
      // "Keep" on a price the customer has seen, when shipping, a charge or
      // the discount moved it: the old total, typed, through the shared rule.
      keepTotal: undefined,
    };
    // A job whose invoice has left the shop: its money does not move
    // (applyJobEdit refuses it; the sheet does not offer it).
    const frozen = !isNew && ['zatca', 'voided', 'credited', 'cancelled'].includes(lock.code);
    const dis = frozen ? ' disabled' : '';
    const ref = isNew ? '' : (typeof jobRef === 'function' ? jobRef(order) : order.id);
    const level = isNew ? 'normal' : (ED().priorityOf ? ED().priorityOf(order) : (order.priorityLevel || 'normal'));
    const field = (label, inner, cls) => `<label class="js-field ${cls || ''}"><span>${escapeHtml(label)}</span>${inner}</label>`;
    const clientOpts = [`<option value="">${escapeHtml(t('js.no_customer'))}</option>`]
      .concat(list('clients').map((c) => `<option value="${escapeHtml(c.id)}"${c.id === order.clientId ? ' selected' : ''}>${escapeHtml(localName(c) || c.id)}</option>`)).join('');
    // The colour the customer asked for, per part (Figma 102:1447): the shop's
    // filament colours suggested, as the old editor's list was.
    const colourOpts = [...new Set(Object.values((settings && settings.filamentColours) || {}).flat().filter(Boolean))]
      .map((c) => `<option value="${escapeHtml(String(c))}">`).join('');
    const filOpts = list('inventory').map((i) => `<option value="${escapeHtml(i.id)}">${escapeHtml(i.material || i.id)}</option>`).join('');
    const marg = isNew ? null : ED().marginOf(order);
    // Job details (Figma 100:1527): the shop's own fields, tags, the two notes.
    const shopFields = ((settings && settings.customFields) || []).filter((sf) => sf && sf.id);
    const tagsOf = (o) => (Array.isArray(o.tags) ? o.tags : []);
    const detailsOpen = !!(order.internalNotes || order.invoiceNotes || tagsOf(order).length
      || shopFields.some((sf) => (order.customData || {})[sf.id]));
    // Not business moves revenue in or out of the books: the shared rule
    // refuses it once a tax invoice is issued, or on a frozen job.
    // (The rule's own answer: lib/order-edit.js nonBusinessLock.)
    const nbLock = isNew ? null : ED().nonBusinessLock(order, { clients: list('clients') });

    const bodyHtml = `<div class="job-sheet">
      ${isNew ? '' : `<div class="js-sub">${escapeHtml(ref)}${order.project ? ' · ' + escapeHtml(order.project) : ''}</div>`}
      <h4 class="js-sec">${escapeHtml(t('js.sec_job'))}</h4>
      ${field(t('js.name'), `<input type="text" data-js="project" value="${escapeHtml(order.project || '')}">`)}
      <div class="js-row">
        ${field(t('js.customer'), `<select data-js="clientId"${custLock ? ' disabled' : ''}>${clientOpts}</select>
          ${custLock ? `<small class="js-hint">${escapeHtml(typeof oeCustomerReasonText === 'function' ? oeCustomerReasonText(custLock) : '')}</small>` : ''}`)}
        ${field(t('js.due'), `<input type="date" data-js="dueDate" value="${escapeHtml(order.dueDate || '')}">`)}
      </div>
      <p class="js-hint" data-js="dueHint" hidden>${escapeHtml(t('js.due_suggested'))}</p>
      <div data-js="capacity"></div>
      <div class="js-field"><span>${escapeHtml(t('js.priority'))}</span>
        <div class="js-seg" role="radiogroup" aria-label="${escapeHtml(t('js.priority'))}">
          ${['normal', 'high', 'urgent'].map((l) => `<button type="button" role="radio" data-js-pr="${l}" aria-checked="${l === level}" class="${l === level ? 'on' : ''}">${escapeHtml(t('js.pr_' + l))}</button>`).join('')}
        </div></div>
      ${field(t('js.notes'), `<input type="text" data-js="notes" value="${escapeHtml(order.notes || '')}">`)}
      <details class="js-details" data-js="details" data-simple-pro${detailsOpen ? ' open' : ''}>
        <summary class="linkish">${escapeHtml(t('js.details'))}</summary>
        ${field(t('js.internal_notes'), `<textarea rows="2" data-js="internalNotes">${escapeHtml(order.internalNotes || '')}</textarea>`)}
        ${field(t('js.invoice_notes'), `<textarea rows="2" data-js="invoiceNotes">${escapeHtml(order.invoiceNotes || '')}</textarea><small class="js-hint">${escapeHtml(t('js.invoice_notes_hint'))}</small>`)}
        ${field(t('js.tags'), `<input type="text" data-js="tags" value="${escapeHtml(tagsOf(order).join(', '))}" placeholder="${escapeHtml(t('tag.ph'))}">`)}
        ${shopFields.length ? `<div class="js-hint">${escapeHtml(t('js.shop_fields'))}</div>
        <div class="js-row">${shopFields.map((sf) => field(sf.label || sf.id, `<input type="text" data-js-cf="${escapeHtml(sf.id)}" value="${escapeHtml(String((order.customData || {})[sf.id] || ''))}">`)).join('')}</div>` : ''}
      </details>
      <label class="js-check" data-simple-pro><input type="checkbox" data-js="nonBusiness"${order.nonBusiness === true ? ' checked' : ''}${nbLock ? ' disabled' : ''}>
        <span>${escapeHtml(t('oe.non_business'))}</span></label>
      <small class="js-hint" data-simple-pro>${escapeHtml(nbLock ? t(nbLock === 'invoice_issued' ? 'js.nb_invoice' : 'js.nb_locked') : t('oe.non_business_hint'))}</small>
      <h4 class="js-sec" data-js="partsHead"></h4>
      <div class="js-parts" data-js="parts"></div>
      ${lock.edit ? `<div class="js-add" data-js="addRow">
        ${field(t('js.part'), `<input type="text" data-js="pName" placeholder="${escapeHtml(t('js.name'))}">`)}
        ${field(t('js.filament'), `<select data-js="pFil">${filOpts}</select>`)}
        ${field(t('ord.part_colour'), `<input type="text" data-js="pColour" list="jsColourDL">`)}
        <datalist id="jsColourDL">${colourOpts}</datalist>
        ${field(t('js.grams'), `<input type="number" min="0" step="any" data-js="pGrams" value="0">`)}
        ${field(t('js.hours'), `<input type="number" min="0" step="any" data-js="pHours" value="0">`)}
        ${field(t('js.qty'), `<input type="number" min="1" step="1" data-js="pQty" value="1">`)}
        <button type="button" class="btn" data-js="pAdd">${escapeHtml(t('js.add_part'))}</button>
      </div>` : `<p class="js-hint">${escapeHtml(t('js.parts_locked'))}</p>`}
      <h4 class="js-sec">${escapeHtml(t('js.sec_price'))}</h4>
      <div class="js-row">
        ${isNew
          ? field(t('js.markup'), `<input type="number" min="0" step="any" data-js="margin" value="${escapeHtml(String(calcMarkup()))}">`)
          : field(t('js.markup'), `<input type="number" min="0" step="any" data-js="margin" value="${marg === null ? '' : escapeHtml(String(marg))}"${marg === null ? ` placeholder="${escapeHtml(t('jp.margin_typed'))}"` : ''}${dis}>`)}
        ${field(t('js.discount'), `<input type="number" min="0" max="100" step="any" data-js="discountPct" value="${escapeHtml(String(+order.discountPct || 0))}"${dis}>`)}
        ${field(t('js.set_price'), `<input type="number" min="0" step="any" data-js="price" placeholder="${escapeHtml(t('js.auto'))}"${dis}>`)}
      </div>
      <div class="js-row">
        ${field(t('js.shipping'), `<input type="number" min="0" step="any" data-js="shippingCost" value="${escapeHtml(String(+order.shippingCost || 0))}"${dis}>`)}
        <span class="js-field" aria-hidden="true"></span><span class="js-field" aria-hidden="true"></span>
      </div>
      <div data-js="loyalty"></div>
      <div class="js-hint">${escapeHtml(t('js.extra_charges'))}</div>
      <div class="js-parts" data-js="lines"></div>
      ${frozen ? `<p class="js-hint">${escapeHtml(t('js.price_frozen'))}</p>` : `<div><button type="button" class="btn" data-js="lineAdd">${escapeHtml(t('js.add_charge'))}</button></div>`}
      ${isNew || frozen ? '' : `<button type="button" class="linkish" data-js="reprice">↻ ${escapeHtml(t('js.reprice'))}</button>`}
      ${isNew ? '' : `<button type="button" class="linkish js-more" data-js="more">› ${escapeHtml(t('js.more'))}</button>`}
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
      Object.assign(n, detailsOf(order));
      const disc = Math.min(100, Math.max(0, num(q('discountPct').value)));
      if (disc !== (+order.discountPct || 0)) n.discountPct = disc;
      if (st.touched) n.parts = st.parts;
      // A new markup goes to the rule as typed: it refuses a bad one itself.
      const mk = q('margin').value.trim();
      if (mk !== '' && (marg === null || Math.abs(Number(mk) - marg) >= 0.005)) n.marginPct = Number(mk);
      const ship = Math.max(0, num(q('shippingCost').value));
      if (Math.abs(ship - (+order.shippingCost || 0)) > 0.005) n.shippingCost = ship;
      if (st.linesTouched) n.extraLines = linesOut();
      const typed = q('price').value.trim();
      if (typed !== '') n.price = Math.max(0, num(typed));
      else if (st.keepTotal !== undefined) n.price = st.keepTotal;
      return n;
    }
    /** The Details fields and Not business, named only when they differ from `base` (applyDetails' contract). */
    function detailsOf(base) {
      const n = {};
      for (const k of ['internalNotes', 'invoiceNotes']) {
        const v = q(k).value;
        if (v !== (base[k] || '')) n[k] = v;
      }
      const tags = q('tags').value.split(',').map((x) => x.trim()).filter(Boolean);
      if (tags.join(',') !== tagsOf(base).join(',')) n.tags = tags;
      const cd = {};
      modal.querySelectorAll('[data-js-cf]').forEach((el) => {
        if (el.value.trim() !== String((base.customData || {})[el.dataset.jsCf] || '')) cd[el.dataset.jsCf] = el.value;
      });
      if (Object.keys(cd).length) n.customData = cd;
      const nb = q('nonBusiness').checked;
      if (nb !== (base.nonBusiness === true)) n.nonBusiness = nb;
      return n;
    }
    /** The machine's queue clears after the due date: the date, or null (the old editor's check, never blocking). */
    function capacityClash() {
      const due = q('dueDate').value;
      if (isNew || !order.machineId || !due || typeof estimateMachineQueueClearDate !== 'function') return null;
      const clear = estimateMachineQueueClearDate(order.machineId, order.id);
      if (!(clear instanceof Date) || !(clear > new Date(due + 'T23:59:59'))) return null;
      const m = list('machines').find((x) => x.id === order.machineId);
      return { when: clear.toLocaleDateString(localeTag()), machine: (m && m.name) || '' };
    }
    function drawCapacity() {
      const c = capacityClash();
      const msg = c ? t('js.capacity_note', { machine: c.machine, date: c.when }) : '';
      q('capacity').innerHTML = c ? `<div class="js-part js-warn" role="status"><div><div class="js-part-name">${escapeHtml(msg)}</div>
        <div class="js-hint">${escapeHtml(t('js.capacity_hint'))}</div></div></div>` : '';
      // Repeated beside Save while it applies, so it is seen at save time too.
      const foot = q('capFoot');
      if (foot) { foot.textContent = msg; foot.hidden = !c; }
    }
    /** The charges to send: a line with no label and no amount is not one. */
    function linesOut() {
      return st.lines.filter((l) => String(l.label || '').trim() || +l.amount > 0 || (l.pct != null && l.pct !== ''))
        .map((l) => Object.assign({}, l, { label: String(l.label || '').trim() }));
    }
    /** Whether shipping, a charge or the discount moves the job's money (the shared rule's test). */
    function termsMove() {
      const n = nextOf();
      const d = {};
      for (const k of ['discountPct', 'shippingCost', 'extraLines']) if (Object.prototype.hasOwnProperty.call(n, k)) d[k] = n[k];
      return Object.keys(d).length > 0 && ED().moneyMoves(order, d);
    }
    /** A new job's input to lib/order-new.js newOrder, as the sheet holds it. */
    function inputOf(asQuote) {
      const typed = q('price').value.trim();
      return {
        parts: st.parts,
        project: q('project').value.trim(),
        clientId: q('clientId').value || null,
        dueDate: q('dueDate').value || undefined,
        notes: q('notes').value,
        margin: Math.max(0, num(q('margin').value)),
        discountPct: Math.min(100, Math.max(0, num(q('discountPct').value))),
        shippingCost: Math.max(0, num(q('shippingCost').value)),
        extraLines: linesOut(),
        priceOverride: typed === '' ? null : Math.max(0, num(typed)),
        overheadPerHour: typeof shopOverheadPerHour === 'function' ? shopOverheadPerHour() : 0,
        priorityLevel: priority(),
        asQuote: !!asQuote,
      };
    }
    /** The job itself: newOrder allocates its number from the shop's counters. */
    function newJob(asQuote) {
      const N = NEW();
      return N.newOrder(inputOf(asQuote), {
        settings,
        orders: list('printLog'),
        clients: list('clients'),
        now: new Date(),
        tokens: { tracking: bytes(N.TOKEN_BYTES), quoteApproval: bytes(N.TOKEN_BYTES), id: bytes(4) },
      });
    }
    const ctxOf = (extra) => Object.assign({
      now: Date.now(), id: uid('edit'), priceId: uid('edit'), settings, clients: list('clients'), nameOf: localName,
      ids: st.parts.filter((p) => !p.id).map(() => uid('PRT')),
    }, extra || {});
    /** The rule's answer on a copy: the job as it would be, or why not. */
    function dryRun(extra) {
      if (isNew) {
        // The shared rules: whether it can be taken, and the total newOrder
        // would record — with no number allocated (lib/order-new.js).
        const input = inputOf(false);
        const ready = NEW().canTake(input);
        if (!ready.ok) return { verdict: { ok: false, reason: ready.reason, step: 'parts' }, trial: order };
        const shown = NEW().previewTotal(input, { settings, clients: list('clients') });
        return { verdict: { ok: true }, trial: { price: shown.total, currency: shown.currency, priceSource: shown.quote.priceSource } };
      }
      const trial = JSON.parse(JSON.stringify(order));
      const verdict = ED().applyJobEdit(trial, nextOf(), ctxOf(Object.assign({ keepPrice: st.keepPrice, priceSeenOk: true }, extra || {})));
      return { verdict, trial };
    }
    const billed = (o) => (Money() && Money().orderGrossRaw ? Money().orderGrossRaw(o, { settings }) : +o.price || 0);
    const priceText = (n) => (typeof fmtOrderPrice === 'function' ? fmtOrderPrice(n, order) : fmtMoney(n));
    function reasonText(v) {
      if (v.reason === 'paid_exceeds_price') return t('oe.paid_exceeds_price', { paid: priceText(+order.paidAmount || 0) });
      if (v.step === 'markup' && ['price_fixed', 'bad_markup', 'ask_price'].includes(v.reason)) {
        return t({ price_fixed: 'js.markup_fixed', bad_markup: 'js.markup_bad', ask_price: 'js.markup_q' }[v.reason]);
      }
      if (v.step === 'business') return t(v.reason === 'invoice_issued' ? 'js.nb_invoice' : 'js.nb_locked');
      if (v.step === 'customer') return typeof oeCustomerReasonText === 'function' ? oeCustomerReasonText(v.reason) : t('js.refused_other');
      if (['name_only', 'delivered_part', 'no_parts'].includes(v.reason)) return t('js.refused_' + v.reason);
      if (['zatca', 'voided', 'credited', 'cancelled'].includes(v.reason)) return t('js.parts_locked');
      return t('js.refused_other');
    }

    function drawParts() {
      q('partsHead').textContent = t('js.sec_parts', { n: st.parts.length });
      q('parts').innerHTML = st.parts.length ? st.parts.map((p, i) => {
        const g = +p.printWeight || 0;
        const colour = String(p.colour || '').trim();
        const sub = [`×${Math.max(1, +p.qty || 1)}`, p.material || '', colour ? t('js.colour_line', { colour }) : t('js.colour_unset'), g ? `${Math.round(g)} g` : '', hrs(p.printTime)].filter(Boolean).join(' · ');
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

    /** The extra charges (Figma 98:1269): each with Edit and Remove, one open at a time. */
    function drawLines() {
      const host = q('lines');
      host.innerHTML = st.lines.map((l, i) => {
        const pct = l.pct != null && l.pct !== '';
        if (st.lineEdit === i) {
          return `<div class="js-part is-editing" data-li="${i}"><div class="js-row js-grow">
            ${field(t('js.charge_label'), `<input type="text" data-js-ll="${i}" value="${escapeHtml(l.label || '')}">`)}
            ${field(t('js.charge_amount'), `<input type="number" min="0" step="any" data-js-la="${i}" value="${escapeHtml(String(+l.amount || 0))}">`)}
          </div><div class="js-part-acts"><button type="button" class="linkish" data-js-ldone="${i}">${escapeHtml(t('js.charge_done'))}</button></div></div>`;
        }
        return `<div class="js-part" data-li="${i}">
          <div><div class="js-part-name">${escapeHtml(l.label || '—')}</div>
            <div class="js-hint">${escapeHtml(pct ? t('js.charge_pct', { pct: String(+l.pct) }) : t('js.charge_fixed'))}</div></div>
          <div class="js-part-acts"><span class="js-amt" data-js-lamt="${i}">${escapeHtml(priceText(+l.amount || 0))}</span>
            ${frozen ? '' : `<button type="button" class="linkish" data-js-ledit="${i}">${escapeHtml(t('js.edit_part'))}</button>
            <button type="button" class="linkish" data-js-lrm="${i}">${escapeHtml(t('js.remove_part'))}</button>`}</div></div>`;
      }).join('');
    }
    /** What each percentage line comes to at the price the rule worked out (no math here). */
    function showLineAmounts(job) {
      const resolved = Array.isArray(job.extraLines) ? job.extraLines : [];
      st.lines.forEach((l, i) => {
        const el = modal.querySelector(`[data-js-lamt="${i}"]`);
        if (!el || l.pct == null || l.pct === '') return;
        const r = (l.id && resolved.find((x) => x && x.id === l.id)) || (st.linesTouched ? null : resolved[i]);
        el.textContent = priceText(r ? +r.amount || 0 : +l.amount || 0);
      });
    }
    /** The customer's loyalty tier, offered as the discount (the old editor's offer). */
    function drawLoyalty() {
      const host = q('loyalty');
      const cid = q('clientId').value;
      const tier = !frozen && cid && settings && settings.loyaltyEnabled && typeof getClientTier === 'function' ? getClientTier(cid) : null;
      const pct = tier ? +tier.discountPct || 0 : 0;
      const offer = pct > 0 && Math.abs(num(q('discountPct').value) - pct) > 0.0001;
      host.innerHTML = offer ? `<div class="js-part"><div><div class="js-part-name">${escapeHtml(t('js.loyalty_offer', { tier: tier.name || '', pct: String(pct) }))}</div>
        <div class="js-hint">${escapeHtml(t('js.loyalty_hint', { pct: String(pct) }))}</div></div>
        <div class="js-part-acts"><button type="button" class="linkish" data-js-loyal="${pct}">${escapeHtml(t('js.loyalty_apply', { pct: String(pct) }))}</button></div></div>` : '';
    }

    function refresh() {
      const { verdict, trial } = dryRun();
      drawCapacity();
      drawLoyalty();
      showLineAmounts(verdict.ok ? trial : order);
      const line = modal.parentElement.querySelector('.js-refused') || (() => {
        const p = document.createElement('p');
        p.className = 'oe-refused js-refused';
        p.setAttribute('role', 'alert');
        modal.insertBefore(p, modal.querySelector('.modal-footer'));
        return p;
      })();
      // An empty new job is not refused, it is just not ready: Save waits.
      const quiet = verdict.ok || (isNew && verdict.reason === 'no_parts');
      line.textContent = quiet ? '' : reasonText(verdict);
      line.hidden = quiet;
      modal.querySelector('[data-act="save"]').disabled = !verdict.ok;
      if (q('asQuote')) q('asQuote').disabled = !verdict.ok;
      modal.querySelector('[data-js="total"]').textContent = priceText(billed(verdict.ok ? trial : order));
      // A typed price (Keep, or a total typed here) is fixed: the rule leaves
      // it where it is when the parts change, and the sheet says so.
      q('fixed').hidden = (verdict.ok ? trial : order).priceSource !== 'override';
    }

    function loadRow(i) {
      const p = st.parts[i];
      st.editing = i;
      q('pName').value = p.name || '';
      if (p.filamentId && list('inventory').some((x) => x.id === p.filamentId)) q('pFil').value = p.filamentId;
      q('pColour').value = p.colour || '';
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
      const colour = q('pColour').value.trim();
      if (st.editing === -1) {
        const fil = filamentFields(filId) || {};
        st.parts.push(costed(Object.assign({ name, printWeight: grams, printTime: hours, qty }, fil, colour ? { colour } : {}), order));
      } else {
        const old = st.parts[st.editing];
        let p = Object.assign({}, old, { name });
        // Colour is not money: it moves on a finished job too, and never re-costs.
        // Cleared with an empty value: the rule merges each part over its old
        // copy (applyParts), so a colour left out would come back.
        if (colour) p.colour = colour; else if (old.colour) p.colour = '';
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
      q('pName').value = ''; q('pColour').value = ''; q('pGrams').value = '0'; q('pHours').value = '0'; q('pQty').value = '1';
      drawParts();
      refresh();
    }

    /** The customer has seen the price (Figma 95:461): keep it, or use the new one. Resolves true/false, or null when closed. */
    function askKeep(was, now, bodyKey) {
      return new Promise((resolve) => {
        const overlay = appendStackedModal(`<div class="modal js-ask" role="dialog" aria-modal="true" aria-labelledby="jsAskTitle">
          <h3 id="jsAskTitle">${escapeHtml(t('js.ask_title'))}</h3>
          <div class="js-sub">${escapeHtml(ref)}${order.project ? ' · ' + escapeHtml(order.project) : ''}</div>
          <p>${escapeHtml(t(bodyKey || 'js.ask_body', { was: priceText(was), now: priceText(now) }))}</p>
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

    /** The customer has seen the price and the markup changes it: change it, or not. Resolves true, or null when closed. */
    function askMarkup(was, now) {
      return new Promise((resolve) => {
        const overlay = appendStackedModal(`<div class="modal js-ask" role="dialog" aria-modal="true" aria-labelledby="jsMkTitle">
          <h3 id="jsMkTitle">${escapeHtml(t('js.markup_change'))}</h3>
          <div class="js-sub">${escapeHtml(ref)}${order.project ? ' · ' + escapeHtml(order.project) : ''}</div>
          <p>${escapeHtml(t('js.markup_q'))}</p>
          <div class="js-foot"><div><div class="js-hint">${escapeHtml(t('js.ask_saw'))}</div><div class="js-total">${escapeHtml(priceText(was))}</div></div>
            <div class="btn-row"><button type="button" class="btn" data-ask="cancel">${escapeHtml(t('common.cancel'))}</button>
            <button type="button" class="btn primary" data-ask="change">${escapeHtml(t('js.use', { amount: priceText(now) }))}</button></div></div>
        </div>`, { zIndex: 10060 });
        const done = (v) => {
          document.removeEventListener('keydown', esc, true);
          overlay.remove();
          resolve(v);
        };
        const esc = (e) => { if (e.key === 'Escape') { e.stopPropagation(); done(null); } };
        document.addEventListener('keydown', esc, true);
        overlay.querySelector('[data-ask="cancel"]').addEventListener('click', () => done(null));
        overlay.querySelector('[data-ask="change"]').addEventListener('click', () => done(true));
        overlay.addEventListener('click', (e) => { if (e.target === overlay) done(null); });
      });
    }

    /**
     * Price the job again from its parts, as a new job would be priced
     * (lib/order-edit.js repriceFromParts, through applyJobEdit's locks).
     * The figure is worked out on a copy and shown was → now first; that
     * question is the seen-price question, so the save passes priceSeenOk.
     */
    async function reprice() {
      const ctx = ctxOf({ priceSeenOk: true, overheadPerHour: typeof shopOverheadPerHour === 'function' ? shopOverheadPerHour() : undefined });
      const mk = q('margin').value.trim();
      const req = mk !== '' && Number.isFinite(Number(mk)) ? { marginPct: Number(mk) } : {};
      const trial = JSON.parse(JSON.stringify(order));
      let dry = ED().applyJobEdit(trial, { reprice: req }, ctx);
      const line = modal.parentElement.querySelector('.js-refused');
      // An issued milestone proforma asks for more than the new price: asked,
      // never refused silently (money review of #2576).
      if (!dry.ok && dry.reason === 'milestones_issued') {
        const issued = (order.milestoneInvoices || []).filter((m) => m && m.issuedAt).reduce((sum, m) => sum + (+m.amount || 0), 0);
        if (!(await confirmModal(t('js.reprice_ms', { issued: priceText(issued) }), { okText: t('js.reprice_ok') }))) return;
        ctx.milestonesOk = true;
        // The refused dry run wrote nothing, so the copy is still as opened.
        dry = ED().applyJobEdit(trial, { reprice: req }, ctx);
      }
      if (!dry.ok) { if (line) { line.textContent = reasonText(dry); line.hidden = false; } return; }
      const was = +order.price || 0;
      const now = +trial.price || 0;
      if (Math.abs(now - was) < 0.005 && order.priceSource !== 'override') { toast(t('js.reprice_same'), 'info'); return; }
      if (!(await confirmModal(t('js.reprice_q', { was: priceText(was), now: priceText(now), pct: String(dry.marginPct) }), { okText: t('js.reprice_ok') }))) return;
      const r = ED().applyJobEdit(order, { reprice: req }, ctx);
      if (!r.ok) { if (line) { line.textContent = reasonText(r); line.hidden = false; } return; }
      if (r.changed) saveAll();
      modal.querySelector('.modal-footer [data-act="cancel"]')?.click();
    }

    /** Take the job (or save it as a quote): newOrder, then the desktop's one way of recording a new job. */
    function create(asQuote) {
      if (!NEW().canTake(inputOf(asQuote)).ok) { refresh(); return false; }
      const entry = newJob(asQuote);
      // The Details and Not business, written by the shared rule (applyDetails)
      // on the new job before it is recorded: nothing written by the sheet.
      const details = detailsOf({});
      if (Object.keys(details).length) ED().applyDetails(entry, details, { now: Date.now(), id: uid('edit'), settings });
      if (typeof recordNewJob === 'function') recordNewJob(entry, asQuote);
      else { list('printLog').unshift(entry); saveAll(); }
      if (typeof openJobPage === 'function') setTimeout(() => openJobPage(entry.id), 0);
      return true;
    }

    openFormModal({
      title: t(isNew ? 'js.title_new' : 'js.title'),
      saveLabel: isNew ? t('js.create_job') : undefined,
      bodyHtml,
      onMount(m) {
        modal = m;
        modal.classList.add('job-sheet-modal');
        const footer = modal.querySelector('.modal-footer');
        footer.insertAdjacentHTML('afterbegin', `<div class="js-totalbox"><div class="js-hint">${escapeHtml(t('js.total'))}</div><div class="js-total" data-js="total"></div><div class="js-hint js-fixed" data-js="fixed" hidden>${escapeHtml(t('js.price_fixed'))}</div><div class="js-hint js-capfoot" data-js="capFoot" role="status" hidden></div></div>`);
        if (isNew) {
          const asQuote = document.createElement('button');
          asQuote.type = 'button';
          asQuote.className = 'btn';
          asQuote.dataset.js = 'asQuote';
          asQuote.textContent = t('js.save_quote');
          modal.querySelector('[data-act="save"]').before(asQuote);
          asQuote.addEventListener('click', () => {
            if (create(true)) modal.querySelector('.modal-footer [data-act="cancel"]').click();
          });
        }
        drawParts();
        // A due date from the queue, for a job that has none (the old
        // editor's estimate, now suggestDueDate): typing one clears the note.
        if (!q('dueDate').value && typeof suggestDueDate === 'function') {
          q('dueDate').value = suggestDueDate();
          q('dueHint').hidden = false;
          q('dueDate').addEventListener('input', () => { q('dueHint').hidden = true; }, { once: true });
        }
        drawLines();
        const syncLine = (el) => {
          if (el.dataset.jsLl !== undefined) { st.lines[+el.dataset.jsLl].label = el.value; st.linesTouched = true; }
          if (el.dataset.jsLa !== undefined) {
            const l = st.lines[+el.dataset.jsLa];
            l.amount = Math.max(0, num(el.value));
            // A figure typed over a percentage line makes it a fixed one: the
            // two would disagree otherwise (the old editor's rule).
            delete l.pct;
            st.linesTouched = true;
          }
        };
        modal.addEventListener('input', (e) => { syncLine(e.target); if (!e.target.closest('[data-js="addRow"]')) refresh(); });
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
          const focusLine = () => modal.querySelector(`[data-js-ll="${st.lineEdit}"]`)?.focus();
          if (e.target.closest('[data-js="lineAdd"]')) {
            st.lines.push({ id: uid('EL'), label: '', amount: 0 });
            st.lineEdit = st.lines.length - 1; st.linesTouched = true;
            drawLines(); refresh(); focusLine();
            return;
          }
          const le = e.target.closest('[data-js-ledit]');
          if (le) { st.lineEdit = +le.dataset.jsLedit; drawLines(); refresh(); focusLine(); return; }
          if (e.target.closest('[data-js-ldone]')) { st.lineEdit = -1; drawLines(); refresh(); return; }
          const lr = e.target.closest('[data-js-lrm]');
          if (lr) { st.lines.splice(+lr.dataset.jsLrm, 1); st.lineEdit = -1; st.linesTouched = true; drawLines(); refresh(); return; }
          const ly = e.target.closest('[data-js-loyal]');
          if (ly) { q('discountPct').value = ly.dataset.jsLoyal; refresh(); return; }
          if (e.target.closest('[data-js="reprice"]')) { reprice(); return; }
          if (e.target.closest('[data-js="more"]')) { openOrderEditor(order.id); }
        });
        refresh();
      },
      async onSave() {
        if (isNew) return create(false);
        st.keepPrice = undefined;
        st.keepTotal = undefined;
        const typedTotal = q('price').value.trim() !== '';
        // A total typed here is a new price on purpose, so a markup changed
        // with it needs no question either. Without this the save was
        // refused 'ask_price' while refresh() (seen-ok) showed no reason,
        // and Save did nothing (pre-release review, Nov 16).
        let seenOk = typedTotal;
        // A price the customer has seen does not move under them silently.
        if (lock.askPrice && !typedTotal && Object.prototype.hasOwnProperty.call(nextOf(), 'marginPct')) {
          // A new markup is a new price on purpose: one question covers it,
          // parts changes included (the Mac asks the same, #2494).
          const { verdict, trial } = dryRun({ keepPrice: false });
          if (verdict.ok && Math.abs((+trial.price || 0) - (+order.price || 0)) > 0.005) {
            if (!(await askMarkup(+order.price || 0, +trial.price || 0))) return false;
          }
          st.keepPrice = false;
          seenOk = true;
        } else if (lock.askPrice && !typedTotal && (st.touched || termsMove())) {
          // New parts, or shipping, a charge or the discount changed: the
          // customer has seen the price, so the shop chooses (Figma 95:461).
          // Keep, when the terms moved it, is the old total typed through the
          // shared rule, which settles it last.
          const { verdict, trial } = dryRun({ keepPrice: false });
          if (verdict.ok && Math.abs((+trial.price || 0) - (+order.price || 0)) > 0.005) {
            const keep = await askKeep(+order.price || 0, +trial.price || 0, st.touched ? 'js.ask_body' : 'js.ask_body_terms');
            if (keep === null) return false;
            if (st.touched) st.keepPrice = keep;
            if (keep && termsMove()) st.keepTotal = +order.price || 0;
          }
        }
        const verdict = ED().applyJobEdit(order, nextOf(), ctxOf({ keepPrice: st.keepPrice, priceSeenOk: seenOk }));
        if (!verdict.ok) {
          refresh();
          // Say why THIS save was refused, even where the dry run (asked as
          // if the price had been seen) found nothing to refuse.
          const line = modal.parentElement.querySelector('.js-refused');
          if (line) { line.textContent = reasonText(verdict); line.hidden = false; }
          return false;
        }
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

  /** The New Job sheet: the same sheet, with nothing in it yet. */
  function openNewJobSheet(opts) { openJobSheet(null, opts); }

  document.addEventListener('click', (e) => {
    if (e.target.closest('#btnNewJobSheet')) openNewJobSheet();
  });

  Object.assign(global, { openJobSheet, openNewJobSheet });
})(typeof window !== 'undefined' ? window : globalThis);
