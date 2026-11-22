'use strict';
/**
 * Bed Ready's own queue transitions.
 *
 * The production queue renders status controls in both views — kanban.js and queue-list.js
 * both emit `data-act="status"`, and wire-events.js handles the click by calling
 * `updateStatus(id, to)`. That function lives in order-flows.js, which is business-only and
 * Bed Ready does not ship, so bedready-shim.js declared it a no-op to stop the boot-time
 * ReferenceError.
 *
 * Which left a queue that looks like it works. The buttons render, the click lands, the
 * handler runs, and `function () { return ''; }` returns. Nothing moves, nothing errors,
 * nothing says why. A maker app whose production queue cannot move a job from printing to
 * done is missing the thing the screen is for.
 *
 * So Bed Ready gets a real one. It USED to be a second implementation of the
 * transitions — close to Khayt's and not the same, which is how two apps come to
 * disagree about what finishing a job means. It missed the cost basis a completion
 * fixes, the material flags a re-opened job has to lose before it can deduct
 * again, and the due date a held job gets back; that last one was written down
 * here as impossible, because the function that did it lived in order-flows.js.
 *
 * It is a HOST now. lib/order-status.js decides what happens and asks for the
 * effects; this file performs the ones a workshop has and ignores the rest —
 * which is the whole point of the effects being a list rather than a sequence of
 * calls. What is performed here:
 *
 *   inventory      deductFilamentForOrder / deductPackagingConsumables (inventory.js) —
 *                  finishing a print is what actually empties the spool
 *   live timer     timerStart / printingStartedAt, which kanban.js already renders a badge
 *                  from and nothing in Bed Ready was setting
 *   activity log   logActivity (app-helpers.js)
 *   the undo       a snapshot taken before the rules run, restored whole
 *
 * The same was true of every OTHER button on the card. kanban.js renders hold, QC pass,
 * QC fail, mark-delivered, timeline, print-label and capture-failure-photo without a
 * `biz` gate — correctly, since none of them is commercial — and all seven handlers
 * lived in order-flows.js too. So the second half of this module is those, each routed
 * through updateStatus() wherever a column changes so the WIP limits, the timer, the
 * stock deduction and the undo toast are inherited once rather than rebuilt seven times.
 *
 * Deliberately absent, because they are business or depend on it: loyalty tiers, invoicing,
 * ZATCA, portals, webhooks, Telegram, status-page export, the QC inspector roster and the
 * scrap-or-reprint RMA branch. Each arrives as an effect and falls through the default
 * case, which is where somebody decides what a workshop does about a new one.
 *
 * Loaded AFTER bedready-shim.js and only by bedready.html, so it replaces the shim's no-op.
 * The shim assigns only when a name is undefined; this assigns unconditionally, on purpose.
 */
(function (global) {
  // t() returns the KEY when a string is missing, and a key is truthy — so the usual
  // `t(k) || fallback` never falls back. It also returns the raw template when called
  // without the params a string interpolates, which is how "Order {id} marked as
  // delivered" reaches a toast with the braces still in it. Both count as missing here.
  const T = (k, fb) => {
    try {
      const s = (typeof t === 'function') ? t(k) : '';
      return (s && s !== k && !/\{\w+\}/.test(s)) ? s : fb;
    } catch (_) { return fb; }
  };
  const say = (msg, kind, ms, opts) => { try { if (typeof toast === 'function') toast(msg, kind, ms, opts); } catch (_) {} };
  const orders = () => (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
  const conf = () => (typeof settings !== 'undefined' && settings) ? settings : {};

  /** The shared QC-failure rules, if the page loaded them. */
  function qcFailureRules() {
    if (qcFailureRules.cached) return qcFailureRules.cached;
    qcFailureRules.cached = (typeof globalThis !== 'undefined' && globalThis.KhaytQcFailure) || null;
    return qcFailureRules.cached;
  }

  /** The shared status rules, however this page happens to have loaded them. */
  function rules() {
    if (rules.cached) return rules.cached;
    rules.cached = (typeof globalThis !== 'undefined' && globalThis.KhaytOrderStatus) || null;
    return rules.cached;
  }

  /** Redraw whichever queue view is on screen. */
  function repaint() {
    if (typeof renderKanban === 'function') { try { renderKanban(); } catch (_) {} }
    if (typeof renderQueueList === 'function') { try { renderQueueList(); } catch (_) {} }
    if (typeof renderDashboard === 'function') { try { renderDashboard(); } catch (_) {} }
  }

  /**
   * Move a job to a new column.
   * @param {string} id         order id
   * @param {string} newStatus  pending | on_hold | printing | post | qc | completed
   */
  function updateStatus(id, newStatus, { holdReason, qc } = {}) {
    const order = orders().find((o) => o && o.id === id);
    if (!order || !newStatus || order.status === newStatus) return;
    const Rules = rules();
    if (!Rules) return;   // the page did not load lib/order-status.js — say nothing, do nothing

    const decision = Rules.gate(order, newStatus, { orders: orders(), settings: conf() });
    if (decision.warn) {
      const p = decision.warn.params;
      say(T('wip.limit_reached', `WIP limit (${p.n}) reached for "${p.col}"`), 'warning', 4000);
    }
    if (!decision.ok) {
      const b = decision.block, p = b.params || {};
      if (b.code === 'production_paused') {
        say(T('prod.paused_block', 'Production is paused — resume it before starting a print.'), 'warning');
      } else if (b.code === 'wip_blocked') {
        say(T('wip.limit_blocked', `WIP limit (${p.n}) reached for "${p.col}" — finish something first.`),
            'error', 4000);
      } else {
        say(b.code, 'error', 4000);
      }
      return;
    }

    const undoIdx = orders().indexOf(order);
    let undoSnap = null;
    try { undoSnap = structuredClone(order); } catch (_) { undoSnap = null; }

    // Reopening a finished print gives its filament back; the Undo below puts
    // back the stock the move changed as well as the job (lib/stock-undo.js),
    // which is what makes giving it back safe.
    const inv = (typeof inventory !== 'undefined' ? inventory : []);
    const cons = (typeof consumables !== 'undefined' && Array.isArray(consumables)) ? consumables : [];
    const stock = (typeof KhaytStockUndo !== 'undefined') ? KhaytStockUndo.capture({ inventory: inv, consumables: cons }) : null;
    const ctx = { now: Date.now(), inventory: inv, consumables: cons, returnMaterial: !!stock };
    if (holdReason !== undefined) ctx.holdReason = holdReason;
    if (qc !== undefined) ctx.qc = qc;
    const out = Rules.apply(order, newStatus, ctx);

    for (const n of out.notices) {
      if (n.code === 'due_extended') {
        say(T('ord.due_extended', `Due date extended by ${n.params.days} day(s): now ${n.params.date}`),
            'info', 4000);
      } else if (n.code === 'filament_returned') {
        say(T('ord.filament_returned', `${n.params.weight} g of filament put back on the shelf`), 'info', 4000);
      }
    }

    for (const e of out.effects) {
      switch (e.type) {
        case 'deduct_filament':
          // Finishing a print is the moment the spool is actually lighter. Both
          // helpers are no-ops for an order carrying no parts, so a bare queue
          // entry costs nothing.
          if (typeof deductFilamentForOrder === 'function') { try { deductFilamentForOrder(order); } catch (_) {} }
          break;
        case 'deduct_packaging':
          if (typeof deductPackagingConsumables === 'function') { try { deductPackagingConsumables(order); } catch (_) {} }
          break;
        case 'activity_log':
          if (typeof logActivity === 'function') { try { logActivity('status', e.text, order.id); } catch (_) {} }
          break;
        case 'save':
          if (typeof saveAll === 'function') saveAll();
          break;
        case 'render':
          repaint();
          break;
        case 'toast_updated':
        case 'toast_updated_undoable':
          say(T('toast.status_updated', 'Status updated'), 'success', 5000,
            (undoIdx >= 0 && undoSnap && e.type === 'toast_updated_undoable') ? {
              undo: () => {
                if (stock) stock.restore();
                const list = orders();
                if (list[undoIdx] && list[undoIdx].id === undoSnap.id) list[undoIdx] = undoSnap;
                if (typeof saveAll === 'function') saveAll();
                repaint();
              },
            } : undefined);
          break;
        default:
          // Everything else a status change asks for is commercial and Bed Ready
          // has none of it: the loyalty tier, the customer's status page, the
          // survey token, the email, the Telegram message, the webhooks, the
          // portal refresh. Ignored on purpose rather than by omission — a
          // shared rule that grows a new effect will land here, and here is
          // where somebody decides what a workshop does about it.
          break;
      }
    }
    // What the move changed on the shelf, fixed now for the Undo above.
    if (stock) stock.seal();

    // The job is completed either way. Offering the printer's own figures happens
    // AFTER, never as a gate: a dismissed dialog must not leave the card in the
    // previous column. Silent when nothing was measured — see bedready-actuals.js.
    if (newStatus === 'completed' && typeof brOfferActuals === 'function') {
      try { brOfferActuals(order); } catch (_) { /* never block a completion on this */ }
    }
  }

  /* ============================================================
     The card's own buttons.

     kanban.js renders these on every card in enthusiast mode — they are not
     `biz`-gated, because holding a job, inspecting it and marking it handed over
     are workshop actions, not commercial ones. Their handlers all lived in
     order-flows.js, so in Bed Ready all seven rendered, clicked, and did nothing.

     Each one below routes through updateStatus() wherever a column changes, so
     the WIP limits, the production-paused block, the live timer, the inventory
     deduction, the activity log, the actuals prompt and the undo toast are
     inherited rather than reimplemented seven times.
     ============================================================ */

  const esc = (s) => (typeof escapeHtml === 'function') ? escapeHtml(String(s == null ? '' : s)) : String(s == null ? '' : s);
  const find = (id) => orders().find((o) => o && o.id === id);

  /** Pause a job, with the reason written on the card. */
  function holdOrder(id) {
    const order = find(id);
    if (!order || typeof openFormModal !== 'function') return;
    openFormModal({
      title: T('ord.hold_btn', 'Put on hold'),
      sizeLg: false,
      saveLabel: T('ord.hold_btn', 'Put on hold'),
      bodyHtml: `
        <label>${esc(T('ord.hold_reason', 'Why is it on hold?'))}</label>
        <input type="text" id="brHoldReason" style="width:100%;" placeholder="${esc(T('common.optional', 'Optional'))}">`,
      onMount(modal) { setTimeout(() => modal.querySelector('#brHoldReason')?.focus(), 40); },
      onSave(modal) {
        // The reason and the moment are the shared rules' business now — which
        // is what makes the due date come back right when the job resumes.
        updateStatus(id, 'on_hold', {
          holdReason: String(modal.querySelector('#brHoldReason')?.value || '').trim(),
        });
        return true;
      },
    });
  }

  /**
   * Passed inspection → done.
   *
   * The QC record travels with the transition, so a completion, its stock
   * deduction and its inspection record all land in the same save. The business
   * version asks for an inspector from `operators[]`; Bed Ready is one person at
   * one bench, so it asks only what a maker would actually write down.
   */
  function qcPassOrder(id) {
    const order = find(id);
    if (!order || typeof openFormModal !== 'function') return;
    openFormModal({
      title: T('ord.qc_pass', 'QC pass'),
      sizeLg: false,
      saveLabel: T('ord.qc_pass', 'QC pass'),
      bodyHtml: `
        <label>${esc(T('ord.qc_notes', 'Notes'))}</label>
        <textarea id="brQcNotes" rows="3" style="resize:vertical;" placeholder="${esc(T('common.optional', 'Optional'))}"></textarea>`,
      onMount(modal) { setTimeout(() => modal.querySelector('#brQcNotes')?.focus(), 40); },
      onSave(modal) {
        // The QC record travels WITH the move now rather than being written
        // just before it, so one set of rules stamps it and every app that
        // reads qcStatus sees the same shape.
        updateStatus(id, 'completed', {
          qc: {
            outcome: 'pass',
            notes: String(modal.querySelector('#brQcNotes')?.value || '').trim(),
          },
        });
        return true;
      },
    });
  }

  /**
   * Failed inspection → back to the queue, with the filament booked as waste.
   *
   * A failed print has already eaten its spool, and Bed Ready has a waste log
   * exactly for that. The business version can also scrap the job or spin off a
   * linked reprint against an RMA; here the job simply goes round again, which is
   * what a maker does with a warped part.
   */
  function qcFailOrder(id) {
    const order = find(id);
    if (!order || typeof openFormModal !== 'function') return;
    // The canonical set waste.js already labels and filters by. Inventing a category
    // here would put a value in wasteLog that the waste screen cannot name.
    const FAILURE_TYPES = ['bed_adhesion', 'nozzle_jam', 'warping', 'stringing',
      'operator_error', 'design_issue', 'power_failure', 'material_quality', 'other'];
    const FALLBACK = {
      bed_adhesion: 'Bed adhesion', nozzle_jam: 'Nozzle jam', warping: 'Warping',
      stringing: 'Stringing', operator_error: 'Operator error', design_issue: 'Design issue',
      power_failure: 'Power failure', material_quality: 'Material quality', other: 'Other',
    };
    openFormModal({
      title: T('ord.qc_fail', 'QC fail'),
      sizeLg: false,
      saveLabel: T('ord.qc_fail', 'QC fail'),
      bodyHtml: `
        <label>${esc(T('waste.failure_type', 'What went wrong?'))}</label>
        <select id="brQcFailType" style="margin-bottom:10px;">
          ${FAILURE_TYPES.map((k) => `<option value="${k}"${k === 'other' ? ' selected' : ''}>${esc(T('waste.ft.' + k, FALLBACK[k]))}</option>`).join('')}
        </select>
        <label>${esc(T('waste.reason', 'Notes'))}</label>
        <input type="text" id="brQcFailReason" style="width:100%;" placeholder="${esc(T('common.optional', 'Optional'))}">
        <label style="margin-top:12px;">${esc(T('waste.weight', 'Filament wasted'))} (g)</label>
        <input type="number" id="brQcFailWeight" min="0" step="1" value="" placeholder="0">`,
      onMount(modal) { setTimeout(() => modal.querySelector('#brQcFailType')?.focus(), 40); },
      onSave(modal) {
        const failureType = modal.querySelector('#brQcFailType')?.value || 'other';
        const reason = String(modal.querySelector('#brQcFailReason')?.value || '').trim();
        const weight = Math.max(0, (typeof num === 'function' ? num(modal.querySelector('#brQcFailWeight')?.value, 0) : 0));

        // The waste row, the defect and the fields on the order are all
        // lib/qc-failure.js's now. This used to write them here, and its
        // defect carried no severity and no photoRef — a Bed Ready failure
        // answered "how bad was it" with undefined, for ever.
        const Rules = qcFailureRules();
        if (Rules) {
          Rules.record(order, { failureType, reason, weight }, {
            now: Date.now(),
            inventory: (typeof inventory !== 'undefined' ? inventory : []),
            wasteLog: (typeof wasteLog !== 'undefined' ? wasteLog : null),
            wasteId: (typeof uid === 'function') ? uid('WASTE') : null,
            defaultReason: T('ord.qc_fail', 'QC fail'),
          });
        }

        updateStatus(id, 'pending');
        if (typeof renderWaste === 'function') { try { renderWaste(); } catch (_) {} }
        if (typeof renderInventory === 'function') { try { renderInventory(); } catch (_) {} }
        return true;
      },
    });
  }

  /**
   * Handed over. Deliberately does NOT move the status: kanban.js builds its
   * Delivered column from `status === 'completed' && deliveredAt` (kanban.js:430),
   * so setting the status here would empty the column the button feeds.
   */
  function markDelivered(id) {
    const order = find(id);
    const Rules = rules();
    if (!order || !Rules) return;
    const out = Rules.markDelivered(order, { now: Date.now() });
    if (!out.ok) return;   // not finished yet; the button is not offered there
    for (const e of out.effects) {
      if (e.type === 'activity_log' && typeof logActivity === 'function') {
        try { logActivity('status', e.text, order.id); } catch (_) {}
      } else if (e.type === 'save' && typeof saveAll === 'function') {
        saveAll();
      } else if (e.type === 'render') {
        repaint();
      }
    }
    say(T('queue.delivered_toast', 'Marked as delivered'), 'success');
  }

  /** How long the job spent in each column. Read-only. */
  function openOrderTimeline(id) {
    const order = find(id);
    if (!order) return;
    const hist = Array.isArray(order.statusHistory) ? order.statusHistory : [];
    if (!hist.length) { say(T('ord.timeline_empty', 'No history for this job yet.'), 'info'); return; }
    if (typeof openFormModal !== 'function') return;

    const COLOURS = {
      pending: '#6b7280', on_hold: '#ef4444', printing: '#22c55e',
      post: '#f59e0b', qc: '#3b82f6', completed: '#10b981', delivered: '#10b981',
    };
    const human = (ms) => {
      const h = ms / 3600000;
      if (h < 1) return `${Math.round(ms / 60000)}m`;
      if (h < 24) return `${h.toFixed(1)}h`;
      const d = Math.floor(h / 24); const r = Math.round(h % 24);
      return r > 0 ? `${d}d ${r}h` : `${d}d`;
    };

    const now = Date.now();
    const rows = hist.map((entry, i) => {
      const start = new Date(entry.at).getTime();
      const end = (i + 1 < hist.length) ? new Date(hist[i + 1].at).getTime() : now;
      const last = i === hist.length - 1;
      const colour = COLOURS[entry.status] || '#6b7280';
      return `
        <div class="timeline-step${last ? ' timeline-last' : ''}">
          <div class="timeline-node" style="background:${colour};box-shadow:0 0 0 3px ${colour}33;"></div>
          ${last ? '' : '<div class="timeline-line"></div>'}
          <div class="timeline-content">
            <span class="timeline-status" style="color:${colour};">${esc(T('queue.' + entry.status, entry.status))}</span>
            <span class="timeline-time">${esc(new Date(entry.at).toLocaleString())}</span>
            <span class="timeline-dur"${last ? ' style="color:var(--text-muted);font-style:italic;"' : ''}>${last ? esc(T('ord.timeline_current', '(current)')) : '⏱ ' + esc(human(end - start))}</span>
          </div>
        </div>`;
    }).join('');

    const total = new Date(hist[hist.length - 1].at).getTime() - new Date(hist[0].at).getTime();
    openFormModal({
      title: `${T('ord.timeline_title', 'Timeline')} — ${order.project || order.id}`,
      sizeLg: false,
      noSave: true,
      bodyHtml: `
        <div style="margin-bottom:12px;font-size:12.5px;color:var(--text-muted);">
          ${esc(order.id)} · ${esc(T('ord.timeline_total', 'Total'))}: <strong>${esc(human(total))}</strong>
        </div>
        <div class="timeline-wrap">${rows}</div>`,
    });
  }

  /**
   * The card's second label button.
   *
   * kanban.js renders two: `order-label` → printOrderLabels (labels.js, which Bed
   * Ready ships and which works) and `print-label` → generateOrderLabel, which
   * lived in the business exporter. Rather than build a second label pipeline for
   * the same card, this points the dead one at the one that works.
   */
  function generateOrderLabel(id) {
    if (typeof printOrderLabels !== 'function') {
      say(T('lbl.unavailable', 'Label printing is unavailable.'), 'error');
      return;
    }
    try { printOrderLabels(id); } catch (_) { say(T('lbl.failed', 'Could not build the label.'), 'error'); }
  }

  /**
   * Attach a photo of what went wrong to a held job.
   *
   * Nothing about this is commercial — it is the picture of the spaghetti. Uses
   * the same main-process helpers as the rest of the photo handling, and only
   * records a path once one has actually been written.
   */
  async function captureFailurePhoto(id) {
    const order = find(id);
    if (!order) return;
    const api = (typeof window !== 'undefined') ? window.hubAPI : null;

    let picked = null;
    if (api && api.pickFile) {
      picked = await api.pickFile({ filters: [{ name: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp'] }] })
        .catch(() => null);
    }
    if (!picked) {
      picked = await new Promise((resolve) => {
        const input = document.createElement('input');
        input.type = 'file';
        input.accept = 'image/jpeg,image/png,image/webp';
        input.style.display = 'none';
        document.body.appendChild(input);
        input.onchange = () => { const f = input.files && input.files[0]; input.remove(); resolve(f || null); };
        input.oncancel = () => { input.remove(); resolve(null); };
        input.click();
      });
    }
    if (!picked) return; // cancelled — not a failure

    try {
      if (typeof picked === 'string' && api && api.copyFileToVault) {
        order.failurePhotoPath = await api.copyFileToVault(picked, order.id);
      } else if (picked instanceof File && api && api.saveOrderPhoto) {
        const dataUrl = await new Promise((resolve, reject) => {
          const r = new FileReader();
          r.onload = () => resolve(r.result);
          r.onerror = () => reject(r.error);
          r.readAsDataURL(picked);
        });
        await api.saveOrderPhoto(order.id, 0, dataUrl);
        order.failurePhotoPath = `failure-${order.id}-${Date.now()}.jpg`;
      } else {
        say(T('ord.photo_unavailable', 'Photo storage is unavailable.'), 'error');
        return;
      }
    } catch (e) {
      // Never stamp a path for a photo that was not written — the card would then
      // point at a file that does not exist, for good.
      say(T('ord.photo_failed', 'Could not save the photo.'), 'error');
      return;
    }

    if (typeof saveAll === 'function') saveAll();
    repaint();
    say(T('ord.photo_saved', 'Failure photo saved'), 'success');
  }

  // Unconditional: bedready-shim.js has already put no-ops here, and these replace them.
  global.updateStatus = updateStatus;
  global.holdOrder = holdOrder;
  global.qcPassOrder = qcPassOrder;
  global.qcFailOrder = qcFailOrder;
  global.markDelivered = markDelivered;
  global.openOrderTimeline = openOrderTimeline;
  global.generateOrderLabel = generateOrderLabel;
  global.captureFailurePhoto = captureFailurePhoto;
  global.KhaytBedReadyQueue = {
    updateStatus, holdOrder, qcPassOrder, qcFailOrder,
    markDelivered, openOrderTimeline, generateOrderLabel, captureFailurePhoto,
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
