/**
 * Order lifecycle: create from build, edit, status, QC, payment, labels, split.
 */
(function (global) {

/* ============================================================
   QC / reprint / RMA — pure helpers (DOM-free, unit-tested)
   See docs/KHAYT-3.0-QC-SPEC.md. These are the correctness core;
   the modals below are thin wrappers around them.
   ============================================================ */

// Pending linkage stamped onto the NEXT order created via logPrint (set by
// createLinkedReprint, consumed + cleared in logPrint via applyReprintMeta).
let pendingReprintMeta = null;

// Explicit qcStatus, derived on read when the field is absent (back-compat with
// pre-QC orders that only carry qcPassedAt/qcFailedAt).
function qcStatusOf(order) {
  // The shared rule, so this file and `lib/qc-metrics.js` cannot come to
  // disagree about what "passed" means.
  const m = (typeof globalThis !== 'undefined' && globalThis.KhaytQcMetrics)
    ? globalThis.KhaytQcMetrics
    : require('../lib/qc-metrics.js');
  return m.qcStatusOf(order);
}

// Up-to-two-letter initials for an inspector, for the compact QC badge.
function inspectorInitials(operatorId, ops) {
  const list = ops || (typeof operators !== 'undefined' ? operators : []);
  const op = (list || []).find(o => o && o.id === operatorId);
  if (!op || !op.name) return '';
  return op.name.trim().split(/\s+/).map(w => w[0] || '').slice(0, 2).join('').toUpperCase();
}

// The first order in a reprint→reprint chain (for SLA / first-pass-yield roll-up).
function reprintChainRoot(order) {
  if (!order) return null;
  return order.reprintChain || (order.reprintOf ? null : order.id) || order.id;
}

// Stamp reprint linkage onto a freshly-created order and back-reference the
// original. NEVER touches the original's materialDeducted — the failed job's
// filament is already gone (deducted at completion, booked in wasteLog); the
// reprint deducts its OWN filament when it later passes QC. shop-cost reprints
// carry no charge; billable reprints keep their calculator price.
function applyReprintMeta(newOrder, meta, log) {
  if (!newOrder || !meta) return newOrder;
  newOrder.reprintOf = meta.of || null;
  newOrder.reprintReason = meta.reason || 'manual';
  newOrder.reprintCost = meta.cost || 'billable';
  newOrder.reprintChain = meta.chain || meta.of || newOrder.id;
  if (meta.cost === 'shop') {
    newOrder.price = 0;
    newOrder.priceBeforeDiscount = null;
    newOrder.reprintNoCharge = true;
    newOrder.paymentStatus = 'paid';
    newOrder.paidAmount = 0;
  }
  const orig = (log || []).find(o => o && o.id === meta.of);
  if (orig) {
    if (!Array.isArray(orig.reprintedInto)) orig.reprintedInto = [];
    if (!orig.reprintedInto.includes(newOrder.id)) orig.reprintedInto.push(newOrder.id);
    // RMA reprint: link the warranty record to the replacement order.
    if (meta.reason === 'rma' && orig.rma && !orig.rma.reprintId) orig.rma.reprintId = newOrder.id;
  }
  return newOrder;
}

// QC / warranty analytics live in `lib/qc-metrics.js` now — the Mac app cannot
// load this file, and the arithmetic is the same question in both. Re-exported
// because every caller here has always reached it through this module.
//
// One behaviour changed with the move: `passRate` and `firstPassYield` are NULL
// for a shop that has inspected nothing, where they used to be 0 — which
// rendered as "0% pass", i.e. everything failed, about a shop that had simply
// not started.
const QcMetrics = (typeof globalThis !== 'undefined' && globalThis.KhaytQcMetrics)
  ? globalThis.KhaytQcMetrics
  : require('../lib/qc-metrics.js');
function computeQcMetrics(orders) { return QcMetrics.qcMetrics(orders); }

// Auto-suggest whether a delivered order's RMA is inside its warranty window.
function computeWithinWarranty(deliveredAt, warrantyDays, nowMs) {
  if (!deliveredAt) return false;
  const days = (typeof warrantyDays === 'number' && warrantyDays >= 0) ? warrantyDays : 30;
  const delivered = new Date(deliveredAt).getTime();
  if (!Number.isFinite(delivered)) return false;
  const now = typeof nowMs === 'number' ? nowMs : Date.now();
  return (now - delivered) <= days * 86400000;
}

/** The new-order rules, however this file happens to be loaded. */
function NewOrderRules() {
  if (NewOrderRules.cached) return NewOrderRules.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytOrderNew) {
    NewOrderRules.cached = globalThis.KhaytOrderNew;
    return NewOrderRules.cached;
  }
  try { NewOrderRules.cached = require('../lib/order-new.js'); }
  catch (e) { NewOrderRules.cached = null; }
  return NewOrderRules.cached;
}

function logPrint(asQuote = false) {
  if (currentBuild.length === 0) {
    const before = currentBuild.length;
    addPart();
    if (currentBuild.length === before) return;
  }

  // WHAT A NEW JOB IS lives in lib/order-new.js. It used to be written here,
  // inline, reading twenty form controls — which is why only this window could
  // create one, and why the native Mac app could not replace Electron for a
  // shop that still had to open Electron to take an order.
  //
  // The form is still this file's. The record is not.
  const bytes = (n) => { const b = new Uint8Array(n); crypto.getRandomValues(b); return b; };
  const N = NewOrderRules();
  const entry = N.newOrder({
    parts: currentBuild,
    project: $('#clientInput').value.trim(),
    clientId: currentClientId || null,
    clientRef: ($('#calcClientRef')?.value || '').trim() || null,
    productId: currentBuildFromProductId || null,
    machineId: $('#machineAssign')?.value || null,
    currency: ($('#calcCurrency')?.value || '') || undefined,
    margin: clampPositive($('#margin').value),
    discountPct: Math.min(100, Math.max(0, num($('#discountPct').value, 0))),
    shippingCost: Math.max(0, num($('#shippingCost')?.value, 0)),
    depositAmount: Math.max(0, num($('#depositAmount')?.value, 0)),
    rushEnabled: !!$('#calcRushFee')?.checked,
    extraLines: currentExtraLines,
    components: (typeof currentComponents !== 'undefined' && Array.isArray(currentComponents))
      ? currentComponents : [],
    assemblyQty: (typeof currentAssemblyQty !== 'undefined') ? currentAssemblyQty : 1,
    asQuote,
  }, {
    settings,
    orders: printLog,
    now: new Date(),
    tokens: { tracking: bytes(N.TOKEN_BYTES), quoteApproval: bytes(N.TOKEN_BYTES) },
  });
  // The counters it advanced are the shop's, and an allocation nobody wrote
  // down hands the same invoice number to the next job.
  saveAll();
  printLog.unshift(entry);
  // Names the rest of this function still reads.
  const finalPrice = entry.price;
  const id = entry.id;
  const project = entry.project;
  const totalPrintTime = entry.printTime;

  // Linked reprint: stamp reprintOf/reason/cost/chain onto this new order and
  // back-reference the original (never re-deducts the original's material).
  if (pendingReprintMeta && !asQuote) {
    applyReprintMeta(printLog[0], pendingReprintMeta, printLog);
  }
  pendingReprintMeta = null;

  if (typeof logActivity === 'function') logActivity(asQuote ? 'quote_created' : 'order_created', `${id}${project ? ' · ' + project : ''}`, id);
  saveAll();

  currentBuild = [];
  currentBuildFromProductId = null;
  currentClientId = null;
  currentExtraLines = [];
  if (typeof currentComponents !== 'undefined') currentComponents = [];
  if (typeof currentAssemblyQty !== 'undefined') currentAssemblyQty = 1;
  localStorage.removeItem(K.CURRENT_BUILD);
  renderBuild();
  renderExtraLines();
  $('#clientInput').value = '';
  if ($('#calcClientRef')) $('#calcClientRef').value = '';
  if ($('#calcCurrency')) $('#calcCurrency').value = '';
  $('#discountPct').value = '0';
  if ($('#shippingCost')) $('#shippingCost').value = '0';
  if ($('#depositAmount')) $('#depositAmount').value = '0';
  /* THE RUSH FEE IS PART OF ONE JOB, NOT A SETTING.
   *
   * Every other money field on this screen is cleared here and this one was
   * not — nothing in the app ever unchecked it. So logging a single rush job
   * left +25% on the calculator for ever: the next quote, and the one after
   * that, until somebody happened to look at the checkbox. On a 1,000 subtotal
   * that is 250 over-charged, per quote, silently. */
  const rush = $('#calcRushFee');
  if (rush) rush.checked = false;
  const tierStrip = $('#priceTiersStrip');
  if (tierStrip) tierStrip.style.display = 'none';

  toast(asQuote ? t('quote.saved') : t('calc.quote.saved'), 'success');
  renderLogs();
  renderKanban();
  renderAnalytics();
  renderDashboard();
  // Round 12 — Webhook: order_created
  const newOrder = printLog[0];
  if (newOrder) {
    fireWebhook('order_created', { orderId: newOrder.id, project: newOrder.project, status: newOrder.status, price: newOrder.price });
    fireOrderWebhook('created', newOrder);
    if (asQuote) autoSendEmailNotification(newOrder, 'quote');
  }
}

/* ============================================================
   Quote workflow — approve, reject, share
   ============================================================ */

/**
 * Tell each setup an order used how the job went.
 *
 * This is the payoff of linking a part to a model: lib/print-setups.js learns
 * which settings work without the shop logging anything by hand, because
 * finishing the order already said so.
 */
function recordSetupOutcomes(order, ok) {
  const OL = (typeof KhaytOrderFileLink !== 'undefined') ? KhaytOrderFileLink : null;
  const PS = (typeof KhaytPrintSetups !== 'undefined') ? KhaytPrintSetups : null;
  if (!OL || !PS || typeof printFiles === 'undefined') return 0;
  let touched = 0;
  for (const out of OL.outcomesForOrder(order, ok)) {
    const rec = (printFiles || []).find((f) => f && f.id === out.printFileId);
    if (!rec || !Array.isArray(rec.setups)) continue;
    const at = rec.setups.findIndex((su) => su && su.id === out.setupId);
    if (at === -1) continue;
    rec.setups[at] = PS.recordOutcome(rec.setups[at], out.ok, new Date().toISOString());
    touched += 1;
  }
  if (touched) {
    try { document.dispatchEvent(new CustomEvent('khayt:printfiles-changed')); } catch (e) { /* non-fatal */ }
  }
  return touched;
}

/* ============================================================
   Actual-vs-estimated — prompt on job completion
   ============================================================ */
function promptActuals(order, onConfirm) {
  const estWeight = order.parts
    ? order.parts.reduce((s, p) => s + (+p.printWeight || 0) * (p.qty || 1), 0)
    : 0;
  // Ask the printer first. This dialog used to pre-fill BOTH fields from the
  // estimate, so a shop glancing at it and hitting confirm wrote the estimate
  // back under a second name — and the variance report then said "spot on" for a
  // job that ran two hours over. A measurement is offered when there is one, and
  // each field says which it is.
  // Ask for THIS job's figures, not simply the last thing that finished. The
  // cache now remembers several completions per machine, so a job that ended
  // while three more ran is still recoverable — but only if we can name it. The
  // printer knows a job by its filename, so an order that recorded one gets an
  // exact match; an order that did not falls back to the most recent, which is
  // what this always did.
  const entry = (typeof machineStatusCache === 'object' && order.machineId)
    ? machineStatusCache?.[order.machineId]
    : null;
  const wantFile = (order.parts || []).map((p) => p && p.fileRef).find(Boolean) || '';
  const PC = typeof KhaytPollCache !== 'undefined' ? KhaytPollCache : null;
  const completion = PC && PC.findCompletion
    ? PC.findCompletion(entry, { filename: wantFile })
    : (entry ? entry.lastCompleted : null);
  const pre = KhaytPrinterActuals.prefillActuals({
    estimate: { printTime: order.printTime, weightG: estWeight },
    completion,
    now: Date.now(),
  });

  const initTime   = order.actualPrintTime ?? pre.timeH ?? order.printTime;
  const initWeight = order.actualWeight    ?? (pre.weightG != null ? Math.round(pre.weightG * 10) / 10 : Math.round(estWeight));
  // Once the shop has entered these by hand, that is their answer — do not
  // relabel their typing as something the printer measured.
  const timeIsMeasured   = order.actualPrintTime == null && pre.timeMeasured;
  const weightIsMeasured = order.actualWeight    == null && pre.weightMeasured;

  const tag = (measured) => measured
    ? `<span style="color:var(--ok,#159d68);font-weight:600;">${escapeHtml(t('act.measured'))}</span>`
    : escapeHtml(t('act.est'));

  openFormModal({
    title:     t('act.title'),
    saveLabel: t('act.confirm'),
    sizeLg:    false,
    bodyHtml: `
      <p style="font-size:13px;color:var(--text-dim);margin-bottom:14px;">${escapeHtml(t('act.hint'))}</p>
      ${(timeIsMeasured || weightIsMeasured)
        ? `<p style="font-size:12px;margin:-6px 0 14px;padding:8px 10px;border-radius:var(--radius);background:var(--bg-elev);">${escapeHtml(
            // Name the JOB, not just the adapter. "moonraker" tells the shop
            // which instrument read the figures; it does not tell them which
            // print. A completion stays offerable for 24h, and a shop running
            // five-hour jobs back to back will have started another one long
            // before that — so the numbers on screen can belong to the previous
            // print while carrying a green "Measured" label. Wrong actuals do
            // not just mis-cost one order: estimate-calibration learns from
            // them. prefillActuals has always returned this filename and
            // nothing displayed it.
            pre.filename
              ? t('act.from_printer_file', { source: pre.source || t('act.your_printer'), file: pre.filename })
              : t('act.from_printer', { source: pre.source || t('act.your_printer') }))}</p>`
        : ''}
      <div class="inline-pair">
        <div>
          <label>${escapeHtml(t('act.print_time'))} (${escapeHtml(t('common.hours'))})</label>
          <input type="number" id="actTime" value="${initTime}" min="0" step="0.1">
          <div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${tag(timeIsMeasured)} · ${escapeHtml(t('act.est'))}: ${order.printTime} ${escapeHtml(t('common.hours'))}</div>
        </div>
        <div>
          <label>${escapeHtml(t('act.weight'))} (${escapeHtml(t('common.grams'))})</label>
          <input type="number" id="actWeight" value="${initWeight}" min="0" step="1">
          <div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${tag(weightIsMeasured)} · ${escapeHtml(t('act.est'))}: ${estWeight.toFixed(0)} ${escapeHtml(t('common.grams'))}</div>
        </div>
      </div>`,
    onSave(modal) {
      const tv = num(modal.querySelector('#actTime').value,   order.printTime);
      const wv = num(modal.querySelector('#actWeight').value, 0);
      order.actualPrintTime = +tv.toFixed(2);
      order.actualWeight    = +wv.toFixed(1);
      // Remember whether these came off a printer or off a keyboard. Without it
      // a margin report cannot tell a measurement from a shop's best guess, and
      // that difference is the entire point of collecting them.
      const unchanged = (a, b) => Math.abs(a - b) < 0.005;
      order.actualsSource = {
        time:   timeIsMeasured   && unchanged(order.actualPrintTime, initTime)   ? (pre.source || 'printer') : 'manual',
        weight: weightIsMeasured && unchanged(order.actualWeight, initWeight)    ? (pre.source || 'printer') : 'manual',
        at: new Date().toISOString(),
      };
      // Close the loop: a finished job teaches the settings that ran it. One
      // outcome per distinct setup, so a four-part order using one setup does
      // not make it look four times as proven.
      recordSetupOutcomes(order, true);
      onConfirm();
      return true;
    }
  });
}

/* THE RULES OF A STATUS CHANGE LIVE IN lib/order-status.js.
 *
 * They used to live here, tangled with printLog, settings, toast() and four
 * render() calls, which is why the Mac app's board can show where the work is
 * piling up but could not let you move a card: the only place that knew what
 * moving a card means was a renderer it does not run.
 *
 * What stayed here is everything that is not a rule — asking for the actuals,
 * showing the toast, offering the undo, and performing the effects the module
 * asks for. The module decides WHAT happens; this file is still the only place
 * that knows how to do it in an Electron window.
 */

/** The module, however this file happens to be loaded.
 *
 *  The cache hangs off the function rather than a `let` beside it, so a caller
 *  defined above this line cannot reach it inside its temporal dead zone. */
function StatusRules() {
  if (StatusRules.cached) return StatusRules.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytOrderStatus) {
    StatusRules.cached = globalThis.KhaytOrderStatus;
    return StatusRules.cached;
  }
  try { StatusRules.cached = require('../lib/order-status.js'); } catch (e) { StatusRules.cached = null; }
  return StatusRules.cached;
}

/* Round 12 — fire completion webhooks + ensure a survey token exists.
   Call exactly once per completion. surveyToken generation is idempotent; the
   webhooks are NOT, so call this once per completion path only. */
function fireOrderCompletionEvents(order) {
  fireWebhook('status_changed', { orderId: order.id, project: order.project, newStatus: 'completed', client: order.client });
  fireOrderWebhook('status', order);
  fireWebhook('order_delivered', { orderId: order.id, project: order.project, client: order.client });
  if (!order.surveyToken) {
    ensureSurveyToken(order);
    saveAll();
  }
}

function ensureSurveyToken(order) {
  const bytes = new Uint8Array(StatusRules().SURVEY_TOKEN_BYTES);
  crypto.getRandomValues(bytes);
  order.surveyToken = StatusRules().makeSurveyToken(bytes);
}

/** Clear on-hold state when an order leaves on_hold, extending the due date by
 *  the days it waited.
 *
 *  The rule is the module's; what stays here is the toast and the name, which
 *  is part of this file's exported surface and is pinned by
 *  test/order-flows.test.js. */
function resumeFromHold(order, prevStatus, newStatus) {
  const notices = [];
  StatusRules().resumeFromHold(order, prevStatus, newStatus, Date.now(), notices);
  showStatusNotices(notices);
}

/** The module names its messages; this file knows the shop's language. */
function showStatusNotices(notices) {
  for (const n of notices || []) {
    if (n.code === 'due_extended') {
      toast(t('ord.due_extended', { days: n.params.days, date: n.params.date }), 'info', 4000);
    }
  }
}

/** Say why a move was refused, or warn that it is a squeeze. */
function reportStatusGate(decision) {
  const w = decision.warn;
  if (w) {
    toast(t('wip.limit_reached', { col: w.params.col, n: w.params.n })
      || `⚠ WIP limit (${w.params.n}) reached for "${w.params.col}" column`, 'warning', 4000);
  }
  const b = decision.block;
  if (!b) return;
  if (b.code === 'production_paused') {
    toast(t('prod.paused_block'), 'warning');
  } else if (b.code === 'wip_blocked') {
    toast(t('wip.limit_blocked', { col: b.params.col, n: b.params.n })
      || `WIP limit reached — cannot move to "${b.params.col}"`, 'error', 4000);
  } else if (b.code === 'assembly_not_assembled') {
    toast(t('asm.gate_not_assembled')
      || 'All parts passed QC — mark the assembly as assembled to complete this order.', 'warning', 5000);
  } else if (b.code === 'assembly_parts') {
    toast(t('asm.gate_parts', { parts: b.params.parts })
      || `Waiting on ${b.params.count} part(s): ${b.params.parts}`, 'warning', 5000);
  }
}

/**
 * Perform the effects lib/order-status.js asked for, in the order it asked.
 *
 * `undo` is offered only where the module says the move is undoable — a
 * completion is not, because it has already deducted filament and packaging
 * that putting the row back would not return to the shelf.
 */
function runStatusEffects(order, effects, { prevTier, undo, toastText } = {}) {
  for (const e of effects) {
    switch (e.type) {
      case 'activity_log':
        if (typeof logActivity === 'function') logActivity('status', e.text, order.id);
        break;
      case 'deduct_filament': deductFilamentForOrder(order); break;
      case 'deduct_packaging': deductPackagingConsumables(order); break;
      case 'save': saveAll(); break;
      case 'tier_check': {
        const newTier = getClientTier(order.clientId);
        if (newTier && (!prevTier || prevTier.name !== newTier.name)) {
          const client = clients.find(c => c.id === order.clientId);
          const cName = client ? localName(client) : '';
          toast(`${cName ? cName + ' ' : ''}${t('cl.new_tier') || 'reached'} ${newTier.name} tier! 🎉`, 'success', 5000);
        }
        break;
      }
      case 'render':
        renderKanban(); renderLogs(); renderAnalytics();
        if (e.dashboard) renderDashboard();
        break;
      case 'toast_updated': toast(toastText || t('toast.status_updated'), 'success'); break;
      case 'toast_delivered': toast(toastText || t('toast.status_updated'), 'success'); break;
      case 'toast_updated_undoable':
        toast(toastText || t('toast.status_updated'), 'success', 5000, undo ? { undo } : {});
        break;
      case 'export_status_page': autoExportStatusPage(order); break;
      case 'email': autoSendEmailNotification(order, e.status); break;
      case 'telegram': sendTelegramForOrder(order, e.status); break;
      case 'webhook':
        fireWebhook(e.event, e.event === 'order_delivered'
          ? { orderId: order.id, project: order.project, client: order.client }
          : { orderId: order.id, project: order.project, newStatus: e.newStatus, client: order.client });
        break;
      case 'order_webhook': fireOrderWebhook(e.event, order); break;
      case 'ensure_survey_token': ensureSurveyToken(order); saveAll(); break;
      case 'republish_portal':
        if (typeof republishPortalIfPublished === 'function') republishPortalIfPublished(order.id);
        break;
      default:
        console.warn('[order-status] no handler for effect', e.type);
    }
  }
}

function updateStatus(id, newStatus) {
  const order = printLog.find(o => o.id === id);
  if (!order) return;

  const decision = StatusRules().gate(order, newStatus, { orders: printLog, settings });
  reportStatusGate(decision);
  if (!decision.ok) return;

  // Completing a job is the moment the shop learns what it really cost, so it
  // is also the moment worth asking for the actual time and grams.
  if (decision.needsActuals) {
    promptActuals(order, () => {
      // The OLD tier has to be read before the job is finished — afterwards
      // there is nothing to compare the new one against.
      const prevTier = order.clientId ? getClientTier(order.clientId) : null;
      const out = StatusRules().apply(order, newStatus, { now: Date.now(), inventory });
      showStatusNotices(out.notices);
      runStatusEffects(order, out.effects, { prevTier });
    });
    return;
  }

  const _undoIdx = printLog.indexOf(order);
  const _undoSnap = structuredClone(order);
  const out = StatusRules().apply(order, newStatus, { now: Date.now(), inventory });
  showStatusNotices(out.notices);
  runStatusEffects(order, out.effects, {
    undo: _undoIdx >= 0 ? () => {
      printLog[_undoIdx] = _undoSnap;
      saveAll();
      renderKanban(); renderLogs(); renderAnalytics();
      if (typeof renderDashboard === 'function') renderDashboard();
    } : null,
  });
}

/**
 * Put a job on hold, with a reason.
 *
 * This used to set the four fields itself and never call `updateStatus`, which
 * meant a hold skipped everything a status change does. Three of those mattered:
 *
 *   - the print timer kept running, so a job held for a week reported a week of
 *     machine time nobody spent on it;
 *   - `settings.telegram.notifyOnHold` never fired, from the one button in the
 *     app that puts a job on hold;
 *   - nothing was written to the team's activity log, so the one status change
 *     a shop most often has to explain later was the one with no record.
 *
 * It goes through the rules now like every other move. The reason and the
 * moment are the module's business too — see `apply()`.
 */
function holdOrder(id) {
  const order = printLog.find(o => o.id === id);
  if (!order) return;
  openFormModal({
    title: t('ord.hold_btn'),
    sizeLg: false,
    saveLabel: t('ord.hold_btn'),
    bodyHtml: `
      <label>${escapeHtml(t('ord.hold_reason'))}</label>
      <input type="text" id="holdReasonInput" placeholder="${escapeHtml(t('ord.hold_reason'))}" style="width:100%;">
    `,
    onMount(modal) { setTimeout(() => modal.querySelector('#holdReasonInput')?.focus(), 40); },
    onSave(modal) {
      const holdReason = modal.querySelector('#holdReasonInput').value.trim();
      const decision = StatusRules().gate(order, 'on_hold', { orders: printLog, settings });
      reportStatusGate(decision);
      if (!decision.ok) return true;   // the dialog closes; the job did not move

      const _undoIdx = printLog.indexOf(order);
      const _undoSnap = structuredClone(order);
      const out = StatusRules().apply(order, 'on_hold', {
        now: Date.now(), inventory, holdReason,
      });
      showStatusNotices(out.notices);
      runStatusEffects(order, out.effects, {
        undo: _undoIdx >= 0 ? () => {
          printLog[_undoIdx] = _undoSnap;
          saveAll();
          renderKanban(); renderLogs(); renderAnalytics();
          if (typeof renderDashboard === 'function') renderDashboard();
        } : null,
        // "On hold" says what happened; "Status updated" does not, and this is
        // the one move a shop starts from a dialog rather than a column.
        toastText: t('ord.on_hold'),
      });
      return true;
    },
  });
}

/* ============================================================
   Feature 2 (this batch): QC pass / fail handlers
   ============================================================ */
// Inspector <select> markup (reuses operators[]), shown only when there are
// operators. Required-marker + validation are driven by settings.qc.requireInspector.
function qcInspectorFieldHtml(selectedId) {
  const qc = (settings && settings.qc) || {};
  const list = (typeof operators !== 'undefined' ? operators : []).filter(o => o && o.active !== false);
  if (!list.length) return '';
  const req = qc.requireInspector ? ' <span style="color:var(--danger,#c23b42);">*</span>' : '';
  return `
    <label style="margin-top:4px;">${escapeHtml(t('qc.inspector') || 'Inspector')}${req}</label>
    <select id="qcInspector" style="margin-bottom:10px;">
      <option value="">${escapeHtml(t('qc.inspector_none') || '—')}</option>
      ${list.map(o => `<option value="${escapeHtml(o.id)}"${selectedId === o.id ? ' selected' : ''}>${escapeHtml(o.name)}${o.role ? ' · ' + escapeHtml(o.role) : ''}</option>`).join('')}
    </select>`;
}

/**
 * Passed inspection → done.
 *
 * This used to write the completion itself — status, completedAt, history,
 * both deductions, the cost basis, the webhooks — which made it a second
 * implementation of the one in `updateStatus`, and it had drifted: a job
 * completed through QC never sent the Telegram message that a job completed
 * through the column button does, and never reached the activity log.
 *
 * It goes through the shared rules now and passes the QC record along with the
 * move. What stays here is the inspector roster (a shop thing, not a rule), the
 * QC-specific toast, and the ORDER of the actuals prompt.
 *
 * THE PROMPT COMES AFTER, AND THAT IS THE POINT. `updateStatus` asks for the
 * actuals first and completes on confirmation; here the job is already known to
 * be finished, so it is completed and deducted immediately and the figures are
 * asked for afterwards. Cancelling the dialog then cannot leave a completed
 * order with nothing deducted.
 */
function qcPassOrder(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const qcCfg = (settings && settings.qc) || {};
  openFormModal({
    title: t('ord.qc_pass'),
    sizeLg: false,
    saveLabel: t('ord.qc_pass'),
    bodyHtml: `
      ${qcInspectorFieldHtml(order.inspector)}
      <label>${escapeHtml(t('ord.qc_notes'))}</label>
      <textarea id="qcNotesInput" rows="3" style="resize:vertical;" placeholder="${escapeHtml(t('common.optional'))}"></textarea>`,
    onMount(modal) { setTimeout(() => modal.querySelector('#qcInspector, #qcNotesInput')?.focus(), 40); },
    onSave(modal) {
      const notes = modal.querySelector('#qcNotesInput').value.trim();
      const inspector = modal.querySelector('#qcInspector')?.value || null;
      if (qcCfg.enabled && qcCfg.requireInspector && !inspector) {
        toast(t('qc.inspector_required') || 'Select an inspector', 'warning');
        return false;
      }

      const decision = StatusRules().gate(order, 'completed', { orders: printLog, settings });
      reportStatusGate(decision);
      if (!decision.ok) return true;   // the dialog closes; the job did not move

      const prevTier = order.clientId ? getClientTier(order.clientId) : null;
      const out = StatusRules().apply(order, 'completed', {
        now: Date.now(), inventory,
        qc: { outcome: 'pass', notes, inspector },
      });
      showStatusNotices(out.notices);
      runStatusEffects(order, out.effects, {
        prevTier,
        toastText: t('ord.qc_passed'),
      });

      // Asked for once the QC dialog is out of the way. Everything above is
      // already saved, so a cancelled prompt costs the shop nothing.
      setTimeout(() => promptActuals(order, () => {
        deductFilamentForOrder(order);
        deductPackagingConsumables(order);
        saveAll();
        renderAnalytics(); renderDashboard();
        if (order.clientId) autoExportStatusPage(order);
      }), 0);
      return true;
    },
  });
}

// Record a QC failure on the order: waste row (unchanged accounting), qcStatus,
// a defect entry, inspector + timestamp. Pure of any post-decision routing.
/** Record a QC failure on the order: waste row, qcStatus, a defect entry,
 *  inspector + timestamp. The rule is lib/qc-failure.js's, so Bed Ready's
 *  failures carry the same fields — its defects had no severity at all. */
function recordQcFailure(order, failure) {
  return QcFailureRules().record(order, failure, {
    now: Date.now(),
    inventory,
    wasteLog,
    wasteId: uid('WASTE'),
    defaultReason: t('ord.qc_fail'),
    // The failed print's filament comes off the shelf, so the rule needs what
    // the shelf rules need: which branch the job belongs to, and the low-stock
    // threshold to warn against.
    settings: typeof settings !== 'undefined' ? settings : {},
    machines: typeof machines !== 'undefined' ? machines : [],
    today: typeof localDateStr === 'function' ? localDateStr() : '',
  });
}

/**
 * The grams the printer measured for a job that did not finish, if any.
 *
 * The reading is whatever the poller last captured for that job's machine;
 * `lib/printer-actuals.js` decides whether it is a measurement or a slicer's
 * prediction wearing its clothes, which is a distinction three of the five
 * supported printers get wrong in their own APIs.
 */
function measuredWasteFor(order) {
  try {
    const PA = (typeof globalThis !== 'undefined' && globalThis.KhaytPrinterActuals)
      || require('../lib/printer-actuals.js');
    if (!PA || !order || !order.machineId) return null;
    // The poll cache, which both entry points fill from the same IPC. Read
    // here rather than through Bed Ready's helper, because Khayt's window does
    // not load that file — and a guarded read of a global that is never there
    // is a feature that is silently absent.
    const cache = (typeof machineStatusCache === 'object' && machineStatusCache) || null;
    const completion = (cache && cache[order.machineId] && cache[order.machineId].lastCompleted) || null;
    if (!completion) return null;
    const weightG = (order.parts || []).reduce(
      (s, p) => s + (+p.printWeight || 0) * (+p.qty || 1), 0);
    return PA.measuredSoFar({
      estimate: { printTime: +order.printTime || 0, weightG },
      completion,
      now: Date.now(),
    });
  } catch (e) {
    return null;
  }
}

/** The QC-failure rules, however this file happens to be loaded. */
function QcFailureRules() {
  if (QcFailureRules.cached) return QcFailureRules.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytQcFailure) {
    QcFailureRules.cached = globalThis.KhaytQcFailure;
    return QcFailureRules.cached;
  }
  try { QcFailureRules.cached = require('../lib/qc-failure.js'); }
  catch (e) { QcFailureRules.cached = null; }
  return QcFailureRules.cached;
}

function qcFailOrder(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const qcCfg = (settings && settings.qc) || {};
  /* WHAT THE PRINTER SAYS IT GOT THROUGH.
   *
   * A print that stopped halfway did not use what it was quoted, and the
   * printer is the only thing that knows how far it got. Pre-filled where a
   * printer measured it, and left EMPTY where none did — offering the estimate
   * as the default for a failure invites a shop to confirm a figure that is
   * certainly too big, and the grams come off the shelf now.
   */
  const measured = measuredWasteFor(order);
  openFormModal({
    title: t('ord.qc_fail'),
    sizeLg: false,
    saveLabel: t('ord.qc_fail'),
    bodyHtml: `
      ${qcInspectorFieldHtml(order.inspector)}
      <label>${escapeHtml(t('waste.failure_type') || 'Failure type')}</label>
      <select id="qcFailType" style="margin-bottom:10px;">
        <option value="bed_adhesion">${escapeHtml(t('waste.ft.bed_adhesion'))}</option>
        <option value="nozzle_jam">${escapeHtml(t('waste.ft.nozzle_jam'))}</option>
        <option value="warping">${escapeHtml(t('waste.ft.warping'))}</option>
        <option value="stringing">${escapeHtml(t('waste.ft.stringing'))}</option>
        <option value="operator_error">${escapeHtml(t('waste.ft.operator_error'))}</option>
        <option value="design_issue">${escapeHtml(t('waste.ft.design_issue'))}</option>
        <option value="power_failure">${escapeHtml(t('waste.ft.power_failure'))}</option>
        <option value="material_quality">${escapeHtml(t('waste.ft.material_quality'))}</option>
        <option value="other" selected>${escapeHtml(t('waste.ft.other'))}</option>
      </select>
      <label>${escapeHtml(t('qc.severity') || 'Severity')}</label>
      <select id="qcFailSeverity" style="margin-bottom:10px;">
        <option value="major" selected>${escapeHtml(t('qc.sev.major') || 'Major')}</option>
        <option value="minor">${escapeHtml(t('qc.sev.minor') || 'Minor')}</option>
      </select>
      <label>${escapeHtml(t('waste.reason'))}</label>
      <input type="text" id="qcFailReason" placeholder="${escapeHtml(t('waste.reason_ph'))}" style="width:100%;">
      <label style="margin-top:12px;">${escapeHtml(t('waste.weight'))} (g)</label>
      <input type="number" id="qcFailWeight" min="0" step="1" value="${measured ? measured.grams : ''}" placeholder="0">
      ${measured
        ? `<div style="font-size:11px;color:var(--text-muted);margin-top:3px;">${escapeHtml(
            t('qc.weight_measured', { source: measured.source || 'printer' })
            || `Measured by ${measured.source || 'your printer'} — what it got through before it stopped.`)}</div>`
        : `<div style="font-size:11px;color:var(--text-muted);margin-top:3px;">${escapeHtml(
            t('qc.weight_typed')
            || 'Nothing measured this print, so type what it got through. The filament comes off the shelf.')}</div>`}`,
    onMount(modal) { setTimeout(() => modal.querySelector('#qcFailType')?.focus(), 40); },
    onSave(modal) {
      const failureType = modal.querySelector('#qcFailType').value;
      const severity = modal.querySelector('#qcFailSeverity')?.value || 'major';
      const reason = modal.querySelector('#qcFailReason').value.trim();
      const weight = Math.max(0, num(modal.querySelector('#qcFailWeight').value, 0));
      const inspector = modal.querySelector('#qcInspector')?.value || null;
      if (qcCfg.enabled && qcCfg.requireInspector && !inspector) {
        toast(t('qc.inspector_required') || 'Select an inspector', 'warning');
        return false;
      }
      recordQcFailure(order, { failureType, severity, reason, weight, inspector });
      if (typeof fireQcWebhook === 'function') fireQcWebhook('qc_failed', order);

      if (!qcCfg.enabled) {
        // QC opt-out: preserve today's behaviour — requeue for reprint.
        order.status = 'pending';
        if (!order.statusHistory) order.statusHistory = [];
        order.statusHistory.push({ status: 'pending', at: new Date().toISOString(), note: 'QC failed' });
        if (order.statusHistory.length > 200) order.statusHistory = order.statusHistory.slice(-200);
        saveAll();
        renderKanban(); renderLogs();
        toast(t('ord.qc_failed_requeue'), 'warning');
        return true;
      }

      // QC enabled: the failed job is terminal (its filament is already booked as
      // waste). Offer Scrap (stop here) or Reprint (spin off a linked new order).
      order.scrapped = true;
      if (!order.statusHistory) order.statusHistory = [];
      order.statusHistory.push({ status: 'qc', at: new Date().toISOString(), note: 'QC failed' });
      if (order.statusHistory.length > 200) order.statusHistory = order.statusHistory.slice(-200);
      saveAll();
      renderKanban(); renderLogs(); renderAnalytics();
      toast(t('qc.failed_recorded') || 'QC failure recorded', 'warning');
      setTimeout(() => promptScrapOrReprint(order), 0);
      return true;
    }
  });
}

// After an (opt-in) QC fail: keep the order as a scrapped record, or spin off a
// linked reprint. QC-fail defaults to shop-cost (internal defect); the owner can
// flip it to billable when the customer caused it.
function promptScrapOrReprint(order) {
  openFormModal({
    title: t('qc.after_fail_title') || 'Failed job',
    sizeLg: false,
    saveLabel: t('qc.reprint') || 'Reprint',
    bodyHtml: `
      <p style="font-size:13px;color:var(--text-dim);margin-bottom:12px;">${escapeHtml(t('qc.after_fail_hint') || 'Spin off a linked reprint, or scrap this job. The wasted filament is already booked — a reprint is a fresh order.')}</p>
      <label>${escapeHtml(t('qc.reprint_cost') || 'Who pays for the reprint?')}</label>
      <select id="qcReprintCost">
        <option value="shop" selected>${escapeHtml(t('qc.cost_shop') || 'Shop (no charge — our defect)')}</option>
        <option value="billable">${escapeHtml(t('qc.cost_billable') || 'Customer (billable — spec/file change)')}</option>
      </select>`,
    onSave(modal) {
      const costMode = modal.querySelector('#qcReprintCost')?.value === 'billable' ? 'billable' : 'shop';
      createLinkedReprint(order, 'qc_fail', costMode);
      return true;
    }
  });
}

/* ============================================================
   Feature 3 (new batch): Resin post-processing handlers
   ============================================================ */
function resinLogWash(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  if (!order.resinPost) order.resinPost = {};
  openFormModal({
    title: t('resin.wash'),
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('resin.wash_duration'))}</label>
      <input type="number" id="resinWashMins" value="${order.resinPost.washDurationMins || ''}" min="0" step="1" placeholder="15">
      <label style="margin-top:12px;">${escapeHtml(t('resin.wash_volume'))}</label>
      <input type="number" id="resinWashVol" value="${order.resinPost.washIpaVolumeMl || ''}" min="0" step="10" placeholder="500">`,
    onSave(modal) {
      const mins = Math.max(0, num(modal.querySelector('#resinWashMins').value, 0));
      const vol  = Math.max(0, num(modal.querySelector('#resinWashVol').value, 0));
      order.resinPost.washDurationMins = mins || null;
      order.resinPost.washIpaVolumeMl  = vol  || null;
      // Deduct IPA from consumables if tracked
      if (vol > 0) {
        const ipa = consumables.find(c => c.name && /ipa|isopropyl/i.test(c.name));
        if (ipa && (ipa.stock || 0) > 0) {
          ipa.stock = Math.max(0, (ipa.stock || 0) - vol);
        }
      }
      saveAll();
      renderKanban();
      toast(t('resin.wash') + ' ✓', 'success');
      return true;
    }
  });
}

function resinLogCure(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  if (!order.resinPost) order.resinPost = {};
  openFormModal({
    title: t('resin.cure'),
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('resin.cure_duration'))}</label>
      <input type="number" id="resinCureMins" value="${order.resinPost.cureDurationMins || ''}" min="0" step="1" placeholder="3">
      <label style="margin-top:12px;">${escapeHtml(t('resin.cure_power'))}</label>
      <input type="number" id="resinCurePow" value="${order.resinPost.curePowerW || ''}" min="0" step="1" placeholder="60">`,
    onSave(modal) {
      order.resinPost.cureDurationMins = Math.max(0, num(modal.querySelector('#resinCureMins').value, 0)) || null;
      order.resinPost.curePowerW       = Math.max(0, num(modal.querySelector('#resinCurePow').value, 0)) || null;
      saveAll();
      renderKanban();
      toast(t('resin.cure') + ' ✓', 'success');
      return true;
    }
  });
}

function resinCompletePost(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  if (order.resinPost) order.resinPost.completedAt = new Date().toISOString();
  updateStatus(orderId, 'qc');
}

async function deleteLog(id) {
  const ok = await confirmModal(`${id} — ${t('common.delete')}?`, { danger: true });
  if (!ok) return;
  const idx = printLog.findIndex(o => o.id === id);
  if (idx < 0) return;
  const removed = printLog[idx];
  printLog.splice(idx, 1);
  // Sweep orphaned spool usage-history entries for this order
  for (const spool of inventory) {
    if (spool.usageHistory && spool.usageHistory.some(h => h.orderId === id)) {
      spool.usageHistory = spool.usageHistory.filter(h => h.orderId !== id);
    }
  }
  // Clean up expenses linked to this order
  if (typeof expenses !== 'undefined' && expenses.some(e => e.orderId === id)) {
    expenses = expenses.filter(e => e.orderId !== id);
  }
  saveAll();
  renderKanban(); renderLogs(); renderAnalytics(); renderPortfolio();
  // Toast with Undo — restores at the same position
  toast(t('oe.deleted'), 'success', 5000, {
    undo: () => {
      printLog.splice(idx, 0, removed);
      saveAll();
      renderKanban(); renderLogs(); renderAnalytics(); renderPortfolio();
    }
  });
}

/**
 * Handed over.
 *
 * Deliberately does NOT move the status: the Delivered column is built from
 * `status === 'completed' && deliveredAt`, so setting a status here would empty
 * the column this button feeds. That rule is `StatusRules().stageOf` now, and
 * this is `markDelivered` there — one definition, because the Mac app's board
 * was reading `status` alone and filing every handed-over job under Completed.
 */
function markDelivered(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const out = StatusRules().markDelivered(order, { now: Date.now() });
  if (!out.ok) return;   // not finished yet; the button is not offered there
  runStatusEffects(order, out.effects, { toastText: t('queue.delivered_toast', { id: order.id }) });
}

/* ============================================================
   Assembly production tracking — per-part status, the "Assembled"
   gate, and a per-part reprint. See docs/KHAYT-3.0-BOM-SPEC.md §5.
   ============================================================ */
function openAssemblyModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const A = (typeof KhaytAssembly !== 'undefined') ? KhaytAssembly : null;
  if (!A) { toast(t('asm.unavailable') || 'Assembly tools unavailable', 'error'); return; }
  const parts = Array.isArray(order.parts) ? order.parts : [];
  const statusLabel = (s) => t('asm.st.' + s) || s;

  const rowsHtml = () => parts.map((p, i) => {
    const st = A.partStatusOf(p);
    return `
      <div class="asm-row" data-pi="${i}" style="display:flex;gap:8px;align-items:center;margin-bottom:6px;">
        <span style="flex:1;font-size:13px;">${escapeHtml(p.name || (t('pe.part') || 'Part') + ' ' + (i + 1))}</span>
        <select class="asm-status" style="width:150px;margin:0;">
          ${A.PART_STATUSES.map(s => `<option value="${s}"${st === s ? ' selected' : ''}>${escapeHtml(statusLabel(s))}</option>`).join('')}
        </select>
        ${st === 'qc_fail' ? `<button class="btn ghost small asm-reprint" data-pi="${i}" style="margin:0;" title="${escapeHtml(t('asm.reprint_part') || 'Reprint this part')}" aria-label="${escapeHtml(t('asm.reprint_part') || 'Reprint this part')}"><span aria-hidden="true">🖨</span></button>` : '<span style="width:34px;"></span>'}
      </div>`;
  }).join('');

  const summaryHtml = () => {
    const st = A.deriveAssemblyStatus(order);
    const gate = A.canCompleteAssembly(order);
    const colour = st === 'assembled' ? 'var(--success,#159a6b)' : (st === 'printed' ? 'var(--warning,#d97706)' : 'var(--text-muted)');
    return `<div style="font-size:12.5px;color:${colour};margin-bottom:10px;"><b>${escapeHtml(t('asm.status') || 'Assembly')}: ${escapeHtml(t('asm.rollup.' + st) || st || '—')}</b>${
      gate.ok ? '' : ` — ${escapeHtml(gate.reason === 'not_assembled' ? (t('asm.gate_tick') || 'tick “Assembled” to finish') : (t('asm.gate_waiting') || 'parts still outstanding'))}`}</div>`;
  };

  openFormModal({
    title: t('asm.title') || 'Assembly',
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <div id="asmSummary">${summaryHtml()}</div>
      <div id="asmRows">${rowsHtml()}</div>
      <label style="display:flex;align-items:center;gap:8px;margin-top:14px;font-weight:400;cursor:pointer;">
        <input type="checkbox" id="asmAssembled" style="width:auto;margin:0;" ${order.assembledAt ? 'checked' : ''}>
        <span>${escapeHtml(t('asm.assembled') || 'Assembled — all parts fitted together')}</span>
      </label>
      <p style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('asm.hint') || 'An assembly can only be completed once every part passes QC and it is marked assembled.')}</p>`,
    onMount(modal) {
      const rows = modal.querySelector('#asmRows');
      const refresh = () => {
        rows.innerHTML = rowsHtml();
        modal.querySelector('#asmSummary').innerHTML = summaryHtml();
      };
      rows.addEventListener('change', (e) => {
        const row = e.target.closest('[data-pi]');
        if (!row || !e.target.classList.contains('asm-status')) return;
        const pi = +row.dataset.pi;
        if (parts[pi]) parts[pi].partStatus = e.target.value;
        refresh();
      });
      rows.addEventListener('click', (e) => {
        const btn = e.target.closest('.asm-reprint');
        if (!btn) return;
        const pi = +btn.dataset.pi;
        reprintSinglePart(order, pi);
      });
      modal.querySelector('#asmAssembled')?.addEventListener('change', (e) => {
        order.assembledAt = e.target.checked ? new Date().toISOString() : null;
        modal.querySelector('#asmSummary').innerHTML = summaryHtml();
      });
    },
    onSave() {
      saveAll();
      renderKanban(); renderLogs();
      toast(t('asm.saved') || 'Assembly updated', 'success');
      return true;
    },
  });
}

// Reprint exactly one failed part of an assembly — the siblings are untouched and the
// order does NOT revert wholesale (spec §7). Reuses the linked-reprint machinery.
function reprintSinglePart(order, partIndex) {
  const part = (order.parts || [])[partIndex];
  if (!part) return;
  const single = { ...order, parts: [{ ...part }] };
  createLinkedReprint(single, 'qc_fail', 'shop');
  toast(t('asm.reprint_queued', { name: part.name || '' }) || 'Part queued for reprint', 'success');
}

/* ============================================================
   Shipping & fulfillment — ship a completed order (manual-first).
   See docs/KHAYT-3.0-SHIPPING-SPEC.md.
   ============================================================ */
function pushShippingHistory(order, status, source, note) {
  if (!Array.isArray(order.shippingHistory)) order.shippingHistory = [];
  order.shippingHistory.push({ status, at: new Date().toISOString(), source: source || 'manual', note: note || '' });
  if (order.shippingHistory.length > 100) order.shippingHistory = order.shippingHistory.slice(-100);
}

// Apply a shipping-status change to an order without regressing, mark delivered when
// it reaches 'delivered', and record history. Shared by the manual picker and webhooks.
function applyShippingStatus(order, next, source) {
  const C = (typeof KhaytCarriers !== 'undefined') ? KhaytCarriers : null;
  const advanced = C ? C.advanceShippingStatus(order.shippingStatus, next) : next;
  if (advanced === order.shippingStatus) return false;
  order.shippingStatus = advanced;
  pushShippingHistory(order, advanced, source);
  if (advanced === 'delivered' && order.status === 'completed' && !order.deliveredAt) {
    order.deliveredAt = new Date().toISOString();
  }
  return true;
}

function openShipModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const C = (typeof KhaytCarriers !== 'undefined') ? KhaytCarriers : null;
  if (!C) { toast(t('ship.unavailable') || 'Shipping unavailable', 'error'); return; }
  const carriers = C.configuredCarriers(settings);
  const alreadyShipped = !!order.shippingStatus;
  const lang = (typeof i18n !== 'undefined' && i18n.current === 'ar') ? 'ar' : 'en';
  const carrierLabel = (c) => (c.label && c.label[lang]) || (c.label && c.label.en) || c.id;

  // Address book (reuse client saved addresses if present).
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const addresses = (client && Array.isArray(client.addresses)) ? client.addresses : [];

  const statusOpts = ['label_created', 'in_transit', 'out_for_delivery', 'delivered', 'exception'];

  openFormModal({
    title: alreadyShipped ? (t('ship.manage_title') || 'Shipment') : (t('ship.title') || 'Ship order'),
    sizeLg: false,
    saveLabel: alreadyShipped ? (t('common.save')) : (t('ship.create') || 'Create shipment'),
    bodyHtml: `
      <label>${escapeHtml(t('ship.carrier') || 'Carrier')}</label>
      <select id="shipCarrier" style="margin-bottom:10px;" ${alreadyShipped ? 'disabled' : ''}>
        ${carriers.map(c => `<option value="${escapeHtml(c.id)}"${order.carrier === c.id ? ' selected' : ''}>${escapeHtml(carrierLabel(c))}</option>`).join('')}
      </select>
      <div id="shipServiceRow"></div>
      ${addresses.length ? `
        <label>${escapeHtml(t('ship.address') || 'Delivery address')}</label>
        <select id="shipAddress" style="margin-bottom:8px;">
          <option value="">${escapeHtml(order.deliveryAddress || t('ship.address_none') || '—')}</option>
          ${addresses.map(a => `<option value="${escapeHtml(a.address)}">${escapeHtml(a.label || a.address)}</option>`).join('')}
        </select>` : ''}
      <label>${escapeHtml(t('ship.tracking') || 'Tracking number')}</label>
      <input type="text" id="shipTracking" value="${escapeHtml(order.trackingNumber || '')}" placeholder="${escapeHtml(t('ship.tracking_ph') || 'AWB / waybill')}" autocomplete="off">
      ${alreadyShipped ? `
        <label style="margin-top:12px;">${escapeHtml(t('ship.status') || 'Shipping status')}</label>
        <select id="shipStatus">
          ${statusOpts.map(s => `<option value="${s}"${order.shippingStatus === s ? ' selected' : ''}>${escapeHtml(t('ship.st.' + s) || s)}</option>`).join('')}
        </select>` : ''}
      <p id="shipHint" style="font-size:11.5px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('ship.hint') || 'Works offline — type a carrier + tracking number by hand, or use a configured carrier API.')}</p>`,
    onMount(modal) {
      const carrierSel = modal.querySelector('#shipCarrier');
      const serviceRow = modal.querySelector('#shipServiceRow');
      const renderServices = () => {
        const c = C.getCarrier(carrierSel.value);
        if (!c || !c.services || !c.services.length) { serviceRow.innerHTML = ''; return; }
        serviceRow.innerHTML = `<label>${escapeHtml(t('ship.service') || 'Service')}</label>
          <select id="shipService" style="margin-bottom:10px;">
            ${c.services.map(s => `<option value="${escapeHtml(s.id)}"${order.shippingService === s.id ? ' selected' : ''}>${escapeHtml(s.label)}</option>`).join('')}
          </select>`;
      };
      renderServices();
      if (carrierSel) carrierSel.addEventListener('change', renderServices);
      const addrSel = modal.querySelector('#shipAddress');
      if (addrSel) addrSel.addEventListener('change', () => { if (addrSel.value) order.deliveryAddress = addrSel.value; });
      setTimeout(() => modal.querySelector('#shipTracking')?.focus(), 40);
    },
    async onSave(modal) {
      // Existing shipment → just apply a manual status update.
      if (alreadyShipped) {
        const next = modal.querySelector('#shipStatus')?.value;
        const typedTn = modal.querySelector('#shipTracking')?.value.trim();
        if (typedTn) order.trackingNumber = typedTn;
        if (next) applyShippingStatus(order, next, 'manual');
        saveAll();
        renderKanban(); renderLogs();
        if (typeof republishPortalIfPublished === 'function') republishPortalIfPublished(order.id);
        toast(t('ship.updated') || 'Shipment updated', 'success');
        return true;
      }

      const carrierId = modal.querySelector('#shipCarrier')?.value || 'manual';
      const carrier = C.getCarrier(carrierId);
      const service = modal.querySelector('#shipService')?.value || null;
      let trackingNumber = modal.querySelector('#shipTracking')?.value.trim() || '';
      let labelUrl = null, meta = null, source = 'manual';

      // API path — attempt createShipment; degrade to manual on any failure.
      if (carrierId !== 'manual') {
        const cfg = ((settings.shipping || {})[carrierId]) || {};
        try {
          const r = await carrier.createShipment(order, cfg);
          trackingNumber = r.trackingNumber || trackingNumber;
          labelUrl = r.labelUrl || null;
          meta = r.meta || null;
          source = 'api';
          if (labelUrl) toast(t('ship.label_saved') || 'Label created', 'success');
        } catch (err) {
          // Manual fallback — the modal already has a tracking-number field.
          toast(t('ship.api_fallback') || 'Carrier API unavailable — enter the tracking number manually.', 'warning', 5000);
          if (!trackingNumber) return false; // keep modal open for the user to type one
          source = 'manual';
        }
      }

      order.carrier = carrierId;
      order.trackingNumber = trackingNumber || null;
      order.shippingService = service;
      order.labelUrl = labelUrl;
      order.shipmentMeta = meta;
      order.shippedAt = new Date().toISOString();
      order.shippingStatus = 'label_created';
      // Back-compat: the order editor's free-text courier + Track button read courierName.
      order.courierName = carrier ? ((carrier.label && carrier.label.en) || carrierId) : carrierId;
      pushShippingHistory(order, 'label_created', source);

      if (typeof fireWebhook === 'function') fireWebhook('order_shipped', { orderId: order.id, project: order.project, carrier: carrierId, trackingNumber: order.trackingNumber });
      saveAll();
      renderKanban(); renderLogs();
      if (typeof republishPortalIfPublished === 'function') republishPortalIfPublished(order.id);
      toast(t('ship.created') || 'Shipment created', 'success');
      return true;
    }
  });
}

/* ============================================================
   Payment tracking
   ============================================================ */
function paymentBadge(o) {
  const s = payStatus(o);
  return `<span class="badge pay-${s}">${escapeHtml(t('pay.' + s))}</span>`;
}

function openPaymentModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const fullAmount = +order.price || 0;
  const draft = {
    paymentStatus: order.paymentStatus || 'paid',
    paidAmount:    order.paidAmount || fullAmount,
    paymentMethod: order.paymentMethod || 'cash',
    paidAt:        order.paidAt || localDateStr()
  };

  const methodOptions = ['cash','mada','transfer','stcpay','applepay','visa','other']
    .map(m => `<option value="${m}" ${draft.paymentMethod === m ? 'selected' : ''}>${escapeHtml(t('pay.method.' + m))}</option>`)
    .join('');

  const depositNote = (order.depositAmount || 0) > 0
    ? `<p style="font-size:12px; color:var(--primary); margin:6px 0 0;">💰 ${escapeHtml(t('pay.deposit_on_file', { amt: fmtPrice(order.depositAmount) }))}</p>`
    : '';

  function outstandingAmount() {
    return Math.max(0, fullAmount - (+order.paidAmount || 0) - (+order.giftCardDiscount || 0));
  }

  function paySummaryHtml() {
    const giftCredit = +order.giftCardDiscount || 0;
    const owed = outstandingAmount();
    return `
      ${giftCredit > 0 ? `<p class="pay-gift-credit" style="font-size:12px;color:var(--success);margin:8px 0 0;">🎁 ${escapeHtml(t('pay.gift_card_credit'))}: ${fmtPrice(giftCredit)}</p>` : ''}
      <p class="pay-outstanding" style="font-size:12px;color:var(--text-muted);margin:${giftCredit > 0 ? '4' : '8'}px 0 0;">
        ${escapeHtml(t('pay.outstanding'))}: <strong>${fmtPrice(owed)}</strong>
      </p>`;
  }

  const bodyHtml = `
    <div class="inline-pair">
      <div>
        <label>${escapeHtml(t('pay.amount_paid'))} (${escapeHtml(currencySymbol())})</label>
        <input type="number" data-f="paidAmount" min="0" max="${+order.price || 0}" step="0.01" value="${draft.paidAmount}">
      </div>
      <div>
        <label>${escapeHtml(t('pay.payment_method'))}</label>
        <select data-f="paymentMethod">${methodOptions}</select>
      </div>
    </div>
    <label>${escapeHtml(t('pay.paid_on'))}</label>
    <input type="date" data-f="paidAt" value="${draft.paidAt}" max="${localDateStr()}">
    <div style="display:flex;gap:8px;align-items:flex-end;margin-top:14px;">
      <div style="flex:1;">
        <label>${escapeHtml(t('giftCardCode'))}</label>
        <input type="text" id="_payGiftCode" placeholder="ABC123" autocomplete="off" style="text-transform:uppercase;">
      </div>
      <button type="button" class="btn small ghost" id="_payApplyGift" style="margin-bottom:1px;">${escapeHtml(t('applyGiftCard'))}</button>
    </div>
    <div id="_paySummary">${paySummaryHtml()}</div>
    <p style="font-size:11.5px; color:var(--text-muted); margin:10px 0 0;">
      ${order.id} · ${escapeHtml(order.project)} · ${fmtPrice(fullAmount)}
    </p>
    ${depositNote}
  `;

  openFormModal({
    title: t('pay.modal_title'),
    saveLabel: t('pay.mark_paid'),
    sizeLg: false,
    bodyHtml,
    onMount(modal) {
      modal.querySelectorAll('[data-f]').forEach(input => {
        input.addEventListener('input', () => {
          const rawVal = input.type === 'number' ? num(input.value, 0) : input.value;
          if (input.dataset.f === 'paidAmount') {
            draft.paidAmount = Math.min(Math.max(0, rawVal), +order.price || 0);
          } else {
            draft[input.dataset.f] = rawVal;
          }
        });
      });
      const refreshSummary = () => {
        const el = modal.querySelector('#_paySummary');
        if (el) el.innerHTML = paySummaryHtml();
      };
      modal.querySelector('#_payApplyGift')?.addEventListener('click', () => {
        const code = modal.querySelector('#_payGiftCode')?.value?.trim();
        if (!code) {
          toast(t('giftCardCodeRequired') || 'Enter a code', 'warning');
          return;
        }
        if (typeof applyGiftCard === 'function' && applyGiftCard(orderId, code)) {
          refreshSummary();
          const owed = outstandingAmount();
          if (draft.paidAmount > owed) draft.paidAmount = owed;
          const paidInput = modal.querySelector('[data-f="paidAmount"]');
          if (paidInput) paidInput.value = draft.paidAmount;
          const codeInput = modal.querySelector('#_payGiftCode');
          if (codeInput) codeInput.value = '';
        }
      });
    },
    async onSave() {
      // The status is DERIVED, by the same rule every report reads it with.
      // This used to work it out inline from gift cards alone, so a payment on
      // an order that had been part-credited was written as partial and read
      // back as paid — by the row underneath it.
      const out = PaymentRules().recordPayment(order, {
        amount: draft.paidAmount,
        method: draft.paymentMethod,
        paidAt: draft.paidAt,
      }, { today: localDateStr() });
      runPaymentEffects(order, out.effects);
      return true;
    }
  });
}

function clearPayment(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  runPaymentEffects(order, PaymentRules().clearPayment(order).effects);
}

/** The payment rules, however this file happens to be loaded. */
function PaymentRules() {
  if (PaymentRules.cached) return PaymentRules.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytOrderPayment) {
    PaymentRules.cached = globalThis.KhaytOrderPayment;
    return PaymentRules.cached;
  }
  try { PaymentRules.cached = require('../lib/order-payment.js'); }
  catch (e) { PaymentRules.cached = null; }
  return PaymentRules.cached;
}

/** Perform what a payment asked for, in the order it asked. */
function runPaymentEffects(order, effects) {
  for (const e of effects || []) {
    switch (e.type) {
      case 'save': saveAll(); break;
      case 'render': renderLogs(); renderKanban(); renderAnalytics(); break;
      case 'toast_saved': toast(t('pay.saved'), 'success'); break;
      case 'toast_cleared': toast(t('pay.cleared'), 'success'); break;
      case 'webhook':
        fireWebhook(e.event, {
          orderId: order.id, amount: order.paidAmount,
          paymentStatus: order.paymentStatus, client: order.client,
        });
        break;
      case 'order_webhook': fireOrderWebhook(e.event, order); break;
      case 'email': autoSendEmailNotification(order, e.status); break;
      case 'accounting':
        if (typeof maybePushAccounting === 'function') maybePushAccounting(order);
        break;
      default:
        console.warn('[order-payment] no handler for effect', e.type);
    }
  }
}

/* Builds the extra-lines rows HTML for the order-editor modal */
function renderOeExtraLinesHtml(lines) {
  if (!lines || lines.length === 0) return '';
  return lines.map((line, i) => `
    <div class="extra-line-row" data-oeli="${i}">
      <input type="text" class="oe-el-label" value="${escapeHtml(line.label)}" placeholder="${escapeHtml(t('calc.extra_label_ph'))}" style="flex:1; min-width:0;">
      <input type="number" class="oe-el-amount" value="${line.amount || ''}" min="0" step="0.01" placeholder="0.00" style="width:90px;">
      <button class="btn danger small oe-el-rm" data-oeli="${i}" aria-label="Remove" title="Remove">×</button>
    </div>`).join('');
}

/* ============================================================
   Order editor — notes + print photos
   ============================================================ */
function openOrderEditor(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const draft = {
    notes: order.notes || '',
    internalNotes: order.internalNotes || '',
    invoiceNotes: order.invoiceNotes || '',
    tags: (order.tags || []).slice(),
    dueDate: order.dueDate || '',
    priority: !!order.priority,
    priorityLevel: order.priorityLevel || (order.priority ? 'high' : 'normal'),
    discountPct: order.discountPct || 0,
    shippingCost: order.shippingCost || 0,
    extraLines: (order.extraLines || []).map(l => ({ ...l })),
    printPhotos: (order.printPhotos || []).map(p => ({ ...p })),
    attachedFiles: (order.attachedFiles || []).map(f => ({ ...f })),
    courierName: order.courierName || '',
    trackingNumber: order.trackingNumber || '',
    deliveryAddress: order.deliveryAddress || '',
    instalments: (order.instalments || []).map(ins => ({ ...ins })),
    // Carried both ways with the schedule it describes: without this the draft
    // starts undefined and the save writes undefined back, so the additive
    // paidAmount rule would silently never apply.
    instalmentBase: order.instalmentBase,
    operatorId: order.operatorId || '',
  };
  const pendingFileDeletes = [];
  // newly-uploaded photos to flush to disk on save (full data URLs)
  const pendingFulls = []; // [{ idx, dataUrl }]
  const pendingDeletes = []; // filenames to delete from disk on save

  const photosHtml = () => {
    const cells = draft.printPhotos.map((ph, i) => `
      <div class="order-photo-cell" data-pi="${i}">
        <img src="${safeImageSrc(ph.thumb)}" alt="">
        <button class="rm" data-act="rm-photo" data-pi="${i}" aria-label="Remove" title="Remove">×</button>
      </div>`).join('');
    const adder = `<button type="button" class="order-photo-cell add" data-act="add-photo">${escapeHtml(t('oe.add_photo'))}</button>`;
    return cells + adder;
  };

  const bodyHtml = `
    <div style="display:flex; align-items:center; gap:12px; margin-top:0; margin-bottom:8px;">
      <label style="margin:0; font-size:13px; white-space:nowrap;">${escapeHtml(t('oe.priority'))}</label>
      <select data-f="priorityLevel" style="flex:1; max-width:160px;">
        <option value="normal"${draft.priorityLevel === 'normal' ? ' selected' : ''}>${escapeHtml(t('common.none') || 'Normal')}</option>
        <option value="high"${draft.priorityLevel === 'high' ? ' selected' : ''}>${escapeHtml(t('ord.priority_high'))}</option>
        <option value="urgent"${draft.priorityLevel === 'urgent' ? ' selected' : ''}>${escapeHtml(t('ord.priority_urgent'))}</option>
      </select>
    </div>
    ${operators.length > 0 ? `
    <div style="display:flex; align-items:center; gap:12px; margin-bottom:8px;">
      <label style="margin:0; font-size:13px; white-space:nowrap;">${escapeHtml(t('op.assigned'))}</label>
      <select id="oeOperator" style="flex:1; max-width:220px;">
        <option value="">${escapeHtml(t('op.unassigned'))}</option>
        ${operators.filter(o => o.active !== false).map(o => `<option value="${o.id}"${draft.operatorId === o.id ? ' selected' : ''}>${escapeHtml(o.name)}${o.role ? ' · ' + escapeHtml(o.role) : ''}</option>`).join('')}
      </select>
    </div>` : ''}
    ${(() => {
      // Feature 3: Material compatibility check
      if (!order.machineId || !order.material) return '';
      const mach = machines.find(m => m.id === order.machineId);
      if (!mach || !mach.compatMaterials || mach.compatMaterials.length === 0) return '';
      const isCompat = mach.compatMaterials.some(m => order.material.toLowerCase().includes(m.toLowerCase()));
      if (isCompat) return '';
      return `<div style="background:rgba(245,166,35,0.12);border:1px solid rgba(245,166,35,0.4);border-radius:6px;padding:8px 12px;font-size:12.5px;color:var(--warning);margin-bottom:8px;">
        ⚠ ${escapeHtml(order.material)} ${escapeHtml(t('mach.compat_warn'))} <em>${escapeHtml(mach.name)}</em> (supports: ${escapeHtml(mach.compatMaterials.join(', '))})
      </div>`;
    })()}
    <label style="margin-top:14px;">${escapeHtml(t('oe.due_date'))}</label>
    <input type="date" data-f="dueDate" value="${escapeHtml(draft.dueDate)}" style="max-width:180px;">
    <small id="oe_due_hint" style="color:var(--text-muted);display:none;margin-top:3px;">📅 ${escapeHtml(t('ord.due_suggestion'))}</small>

    <!-- A workshop prints things that are not jobs. Marking one keeps it out of
         the money without pretending it never ran: it still wears the nozzle and
         still occupies the machine. See lib/business-scope.js. -->
    <label style="display:flex;align-items:center;gap:8px;margin-top:14px;font-weight:normal;cursor:pointer;">
      <input type="checkbox" data-f="nonBusiness" ${draft.nonBusiness ? 'checked' : ''} style="width:auto;margin:0;">
      <span>${escapeHtml(t('oe.non_business') || 'Not business — keep out of revenue and reports')}</span>
    </label>
    <small style="color:var(--text-muted);display:block;margin-top:3px;">${escapeHtml(t('oe.non_business_hint') || 'A test, a gift, something for the shop itself. It still counts towards nozzle wear and still occupies the machine.')}</small>

    <div class="inline-pair" style="margin-top:14px;">
      <div>
        <label>${escapeHtml(t('oe.courier'))}</label>
        <input type="text" data-f="courierName" value="${escapeHtml(draft.courierName)}" placeholder="e.g. Aramex, DHL">
      </div>
      <div>
        <label>${escapeHtml(t('oe.tracking_number'))}</label>
        <input type="text" data-f="trackingNumber" value="${escapeHtml(draft.trackingNumber)}" placeholder="…">
      </div>
    </div>
    ${(() => {
      const cl = order.clientId ? clients.find(c => c.id === order.clientId) : null;
      if (cl && cl.addresses && cl.addresses.length > 0) {
        return `<label style="margin-top:10px;">${escapeHtml(t('oe.select_address'))}</label>
        <select id="oeAddressSelect" style="margin-bottom:6px;">
          <option value="">— ${escapeHtml(t('oe.select_address'))} —</option>
          ${cl.addresses.map(a => `<option value="${escapeHtml(a.address || '')}">${escapeHtml(a.label || a.address)}</option>`).join('')}
        </select>`;
      }
      return '';
    })()}
    <label style="margin-top:10px;">${escapeHtml(t('oe.delivery_address'))}</label>
    <textarea data-f="deliveryAddress" rows="2" style="resize:vertical; min-height:48px;" placeholder="…">${escapeHtml(draft.deliveryAddress)}</textarea>

    ${(() => {
      // Feature 8 (new 8-pack): Loyalty tier auto-discount
      if (!order.clientId || !settings.loyaltyEnabled) return '';
      const tier = getClientTier(order.clientId);
      if (!tier || !tier.discountPct) return '';
      return `<div style="padding:8px 12px;background:rgba(43,182,115,0.1);border:1px solid rgba(43,182,115,0.3);border-radius:6px;font-size:12.5px;margin-top:10px;">
        <span class="loyalty-tier-badge tier-${escapeHtml(tier.name.toLowerCase().replace(/\s+/g,''))}">${escapeHtml(tier.name)}</span>
        ${escapeHtml(t('oe.tier_discount') || 'Loyalty discount applied')}: <strong>${tier.discountPct}%</strong>
        <button type="button" id="btnApplyTierDiscount" class="btn small" style="margin-inline-start:8px;">Apply ${tier.discountPct}% discount</button>
      </div>`;
    })()}
    <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:18px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('oe.discount_pct'))} (%)</label>
        <input type="number" data-f="discountPct" value="${draft.discountPct}" min="0" max="100" step="1">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('oe.shipping'))} (${currencySymbol()})</label>
        <input type="number" data-f="shippingCost" value="${draft.shippingCost}" min="0" step="0.01">
      </div>
    </div>

    <div style="margin-top:14px;">
      <label style="margin:0; display:flex; align-items:center; justify-content:space-between;">
        <span>${escapeHtml(t('calc.extra_lines'))}</span>
        <button class="btn ghost small" id="oeAddExtraLine" type="button">${escapeHtml(t('calc.add_extra_line'))}</button>
      </label>
      <div id="oeExtraLinesList" style="margin-top:6px;">${renderOeExtraLinesHtml(draft.extraLines)}</div>
    </div>

    <label style="margin-top:18px;">${escapeHtml(t('oe.notes'))}</label>
    <textarea data-f="notes" rows="3" style="resize:vertical; min-height:60px;" placeholder="${escapeHtml(t('oe.notes_ph'))}">${escapeHtml(draft.notes)}</textarea>

    <label style="margin-top:14px;">${escapeHtml(t('oe.internal_notes'))}</label>
    <p style="font-size:11.5px;color:var(--text-muted);margin:2px 0 5px;">🔒 ${escapeHtml(t('oe.internal_notes_ph'))}</p>
    <textarea data-f="internalNotes" rows="2" style="resize:vertical; min-height:48px; border-color:var(--border-soft); background:rgba(0,0,0,0.03);" placeholder="${escapeHtml(t('oe.internal_notes_ph'))}">${escapeHtml(draft.internalNotes)}</textarea>

    <label style="margin-top:14px;">${escapeHtml(t('oe.invoice_notes'))}</label>
    <p style="font-size:11.5px;color:var(--text-muted);margin:2px 0 5px;">${escapeHtml(t('oe.invoice_notes_hint'))}</p>
    <textarea data-f="invoiceNotes" rows="2" style="resize:vertical; min-height:48px;" placeholder="${escapeHtml(t('oe.invoice_notes_ph'))}">${escapeHtml(draft.invoiceNotes)}</textarea>

    <label style="margin-top:14px;">${escapeHtml(t('tag.label'))}</label>
    <input type="text" data-f="tags" value="${escapeHtml(draft.tags.join(', '))}" placeholder="${escapeHtml(t('tag.ph'))}" style="font-size:13px;">
    <p style="font-size:11.5px;color:var(--text-muted);margin:3px 0 0;">${escapeHtml(t('tag.hint'))}</p>

    <label style="margin-top:18px;">${escapeHtml(t('oe.photos'))}</label>
    <div class="order-photo-strip" id="orderPhotos">${photosHtml()}</div>
    <input type="file" id="orderPhotoInput" accept="image/jpeg,image/png,image/webp" style="display:none;">

    <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0; display:flex; align-items:center; justify-content:space-between;">
        <span>${escapeHtml(t('oe.files'))}</span>
        ${window.hubAPI?.pickAndSaveOrderFile ? `<button id="btnAttachFile" class="btn small" type="button">${escapeHtml(t('oe.attach_file'))}</button>` : ''}
      </label>
      <div id="attachedFilesList">${renderAttachedFiles(draft.attachedFiles || [])}</div>
    </div>

    <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0; display:flex; align-items:center; justify-content:space-between;">
        <span>${escapeHtml(t('ord.vault_files'))}</span>
        ${window.hubAPI?.pickFile ? `<button id="btnAddVaultFile" class="btn small" type="button">📁 ${escapeHtml(t('ord.vault_add'))}</button>` : ''}
      </label>
      <div id="vaultFilesList"></div>
      <div style="font-size:11px;color:var(--text-muted);margin-top:4px;">${escapeHtml(t('ord.status_page_path'))}: userData/status-pages/${escapeHtml(order.id)}.html</div>
    </div>

    ${(() => {
      const hist = order.statusHistory || [];
      if (hist.length === 0) return '';
      const rows = hist.map(h => {
        const d = new Date(h.at);
        const dateStr = d.toLocaleDateString(localeTag(), { day: '2-digit', month: 'short', year: 'numeric' });
        const timeStr = d.toTimeString().slice(0, 5);
        return `<div class="status-timeline-row">
          <span class="badge ${escapeHtml(h.status)}" style="font-size:10px;">${escapeHtml(t('queue.' + h.status))}</span>
          <span class="st-date">${escapeHtml(dateStr)} ${escapeHtml(timeStr)}</span>
        </div>`;
      }).join('');
      return `<div style="margin-top:18px;padding-top:14px;border-top:1px solid var(--border-soft);">
        <label style="margin-top:0;">${escapeHtml(t('oe.status_history'))}</label>
        <div class="status-timeline">${rows}</div>
      </div>`;
    })()}

    <details style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <summary style="cursor:pointer; font-size:12.5px; font-weight:600; color:var(--text-dim); user-select:none; padding:2px 0; margin-bottom:10px;">${escapeHtml(t('oe.actual_timestamps'))}</summary>
      <div class="inline-pair">
        <div>
          <label style="margin-top:0;">${escapeHtml(t('oe.printing_started_at'))}</label>
          <input type="datetime-local" id="oePrintingStartedAt" value="${order.printingStartedAt ? order.printingStartedAt.slice(0,16) : ''}">
        </div>
        <div>
          <label style="margin-top:0;">${escapeHtml(t('oe.completed_at_actual'))}</label>
          <input type="datetime-local" id="oeCompletedAt" value="${order.completedAt ? order.completedAt.slice(0,16) : ''}">
        </div>
      </div>
    </details>

    <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">
        <label style="margin:0; flex:1; font-size:12.5px; font-weight:600;">${escapeHtml(t('inst.title'))}</label>
        <button class="btn ghost small" id="oeGenInstalments" type="button">${escapeHtml(t('inst.generate') || 'Generate plan')}</button>
        <button class="btn ghost small" id="oeAddInstalment" type="button">${escapeHtml(t('inst.add'))}</button>
      </div>
      <div id="oeInstalmentList"></div>
    </div>

    ${(order.parts && order.parts.length > 0) ? `
    <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0; font-weight:600;">${escapeHtml(t('ord.parts_colours'))}</label>
      <p style="font-size:11.5px;color:var(--text-muted);margin:2px 0 8px;">${escapeHtml(t('ord.parts_colours_hint'))}</p>
      <div id="oePartsColourList">
        ${order.parts.map((p, i) => `
        <div style="display:flex;align-items:center;gap:10px;margin-bottom:6px;">
          <span style="font-size:12.5px;color:var(--text-dim);min-width:120px;overflow:hidden;text-overflow:ellipsis;">${escapeHtml(p.name || ('Part ' + (i+1)))}</span>
          <input type="text" class="oe-part-colour" data-pi="${i}" list="oePartColourDL"
            value="${escapeHtml(p.colour || '')}"
            placeholder="${escapeHtml(t('ord.part_colour'))}"
            style="flex:1;">
        </div>`).join('')}
      </div>
      <datalist id="oePartColourDL">
        ${[...new Set(Object.values(settings.filamentColours || {}).flat())].map(c => `<option value="${escapeHtml(c)}">`).join('')}
      </datalist>
    </div>` : ''}

    ${buildProfitabilityHtml(order)}

    <div class="pro-only" style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <div style="display:flex; align-items:center; gap:8px; margin-bottom:6px;">
        <label style="margin:0; flex:1; font-size:12.5px; font-weight:600;">${escapeHtml(t('ord.milestone_invoices'))}${(order.milestoneInvoices && order.milestoneInvoices.length > 0) ? ` <span style="font-size:11px;color:var(--primary);">(${order.milestoneInvoices.length})</span>` : ''}</label>
        <button class="btn ghost small" id="oeOpenMilestones" type="button" data-act="milestone-invoices" data-id="${escapeHtml(order.id)}">${escapeHtml(t('ord.milestone_manage'))}</button>
      </div>
      ${(order.milestoneInvoices || []).length > 0 ? `
      <div style="font-size:12px;color:var(--text-muted);">
        ${order.milestoneInvoices.map(m => `<div style="padding:4px 0; border-bottom:1px solid var(--border-soft);">${escapeHtml(m.label || '')} — ${fmtPrice(m.amount || 0)}${m.paidAt ? ' ✓' : ''}</div>`).join('')}
      </div>` : `<p style="font-size:12px;color:var(--text-muted);margin:0;">${escapeHtml(t('ord.no_milestones'))}</p>`}
    </div>

    ${(settings.customFields || []).length > 0 ? `
    <div style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0; font-weight:600;">${escapeHtml(t('set.custom_fields_title'))}</label>
      ${(settings.customFields || []).map(f => `
        <label style="margin-top:10px;">${escapeHtml(f.label)}</label>
        <input type="text" data-cf="${escapeHtml(f.id)}" value="${escapeHtml((order.customData || {})[f.id] || '')}" placeholder="${escapeHtml(f.label)}">
      `).join('')}
    </div>` : ''}

    <details style="margin-top:18px; padding-top:14px; border-top:1px solid var(--border-soft);">
      <summary style="font-size:12.5px; font-weight:600; cursor:pointer; color:var(--primary);">
        💬 Internal Notes${(order.comments || []).length > 0 ? ` <span style="background:var(--primary);color:#fff;border-radius:10px;padding:1px 7px;font-size:11px;">${(order.comments || []).length}</span>` : ''}
      </summary>
      <div id="orderCommentsSection" style="margin-top:12px;"></div>
    </details>
  `;

  openFormModal({
    title: `${t('oe.title')} — ${order.id}`,
    saveLabel: t('common.save'),
    sizeLg: true,
    bodyHtml,
    onMount(modal) {
      modal.querySelector('#oeOpenMilestones')?.addEventListener('click', () => openMilestoneInvoices(order.id));
      const plSel = modal.querySelector('[data-f="priorityLevel"]');
      if (plSel) plSel.addEventListener('change', (e) => {
        // Both fields, from one answer: a job that is urgent on one screen and
        // ordinary on another is what happens when only one of them moves.
        Object.assign(draft, EditRules().priorityFrom(e.target.value));
      });
      // Feature 3: Auto-suggest due date when field is empty
      requestAnimationFrame(() => {
        const dueDateInput = modal.querySelector('[data-f="dueDate"]');
        if (dueDateInput && !dueDateInput.value) {
          const queueDepth = printLog.filter(o => o.status === 'pending' || o.status === 'printing').length;
          // settings.workingHours is an object ({mon:8,…}); use the numeric helper
          // (raw object * 60 → NaN → setDate(NaN) → toISOString() RangeError).
          const workingHoursPerDay = Math.max(1, avgDailyWorkingHours());
          const recentMins = printLog.filter(o => o.status === 'completed' && o.printTimeMins != null)
            .slice(-20).map(o => o.printTimeMins).filter(Boolean);
          const avgPrintMins = recentMins.length > 0 ? recentMins.reduce((s, v) => s + v, 0) / recentMins.length : 120;
          const totalMinsQueued = queueDepth * avgPrintMins;
          const daysNeeded = Math.max(1, Math.ceil(totalMinsQueued / (workingHoursPerDay * 60)));
          const suggested = new Date(); suggested.setDate(suggested.getDate() + daysNeeded);
          const suggestedStr = localDateStr(suggested);
          dueDateInput.value = suggestedStr;
          dueDateInput.title = 'Auto-suggested based on current queue';
          draft.dueDate = suggestedStr;
          const hint = modal.querySelector('#oe_due_hint');
          if (hint) hint.style.display = 'block';
        }
      });
      /* A checkbox is `checked`, not `value` — a generic [data-f] handler reads
       * "on" when ticked and never writes anything when unticked, so the flag
       * would set and refuse to clear. */
      const nbEl = modal.querySelector('[data-f="nonBusiness"]');
      if (nbEl) nbEl.addEventListener('change', () => { draft.nonBusiness = nbEl.checked ? true : undefined; });
      modal.querySelector('[data-f="dueDate"]').addEventListener('change', (e) => {
        draft.dueDate = e.target.value;
      });
      modal.querySelector('[data-f="courierName"]').addEventListener('input', (e) => {
        draft.courierName = e.target.value;
      });
      modal.querySelector('[data-f="trackingNumber"]').addEventListener('input', (e) => {
        draft.trackingNumber = e.target.value;
      });
      modal.querySelector('[data-f="deliveryAddress"]')?.addEventListener('input', (e) => {
        draft.deliveryAddress = e.target.value;
      });
      // Feature 4: Address book select
      const addrSel = modal.querySelector('#oeAddressSelect');
      if (addrSel) {
        addrSel.addEventListener('change', (e) => {
          const addrField = modal.querySelector('[data-f="deliveryAddress"]');
          if (addrField && e.target.value) {
            addrField.value = e.target.value;
            draft.deliveryAddress = e.target.value;
          }
        });
      }
      // Feature 8 (new 8-pack): Apply loyalty tier discount button
      modal.querySelector('#btnApplyTierDiscount')?.addEventListener('click', () => {
        const tier = getClientTier(order.clientId);
        if (!tier) return;
        const discEl = modal.querySelector('[data-f="discountPct"]');
        if (discEl) {
          discEl.value = tier.discountPct;
          draft.discountPct = +tier.discountPct;
        }
      });

      modal.querySelector('[data-f="discountPct"]').addEventListener('input', (e) => {
        draft.discountPct = Math.min(100, Math.max(0, +e.target.value || 0));
      });
      modal.querySelector('[data-f="shippingCost"]').addEventListener('input', (e) => {
        draft.shippingCost = Math.max(0, +e.target.value || 0);
      });
      modal.querySelector('[data-f="notes"]').addEventListener('input', (e) => {
        draft.notes = e.target.value;
      });
      modal.querySelector('[data-f="internalNotes"]')?.addEventListener('input', (e) => {
        draft.internalNotes = e.target.value;
      });
      modal.querySelector('[data-f="invoiceNotes"]').addEventListener('input', (e) => {
        draft.invoiceNotes = e.target.value;
      });
      modal.querySelector('[data-f="tags"]').addEventListener('input', (e) => {
        draft.tags = parseTags(e.target.value);
      });

      // Operator select
      const opSel = modal.querySelector('#oeOperator');
      if (opSel) opSel.addEventListener('change', (e) => { draft.operatorId = e.target.value; });

      // Vault files (Feature 2)
      const vaultListEl = modal.querySelector('#vaultFilesList');
      async function refreshVaultFiles() {
        if (!vaultListEl || !window.hubAPI?.listVaultFiles) return;
        try {
          const files = await window.hubAPI.listVaultFiles(order.id);
          if (!files || files.length === 0) {
            vaultListEl.innerHTML = `<div style="color:var(--text-muted);font-size:12px;padding:4px 0;">${escapeHtml(t('ord.vault_empty'))}</div>`;
            return;
          }
          vaultListEl.innerHTML = files.map(f => `
            <div class="vault-file-row">
              <span class="vf-name" title="${escapeHtml(f.filename)}">📄 ${escapeHtml(f.filename)}</span>
              <span class="vf-size">${(f.size / 1024).toFixed(1)} KB</span>
              <button class="btn small" data-act-vault="open" data-path="${escapeHtml(f.fullPath)}">${escapeHtml(t('ord.vault_open'))}</button>
              <button class="btn danger small" data-act-vault="del" data-path="${escapeHtml(f.fullPath)}">${escapeHtml(t('ord.vault_delete'))}</button>
            </div>`).join('');
          vaultListEl.querySelectorAll('[data-act-vault="open"]').forEach(btn => {
            btn.addEventListener('click', () => {
              if (window.hubAPI?.openFile) window.hubAPI.openFile(btn.dataset.path);
            });
          });
          vaultListEl.querySelectorAll('[data-act-vault="del"]').forEach(btn => {
            btn.addEventListener('click', async () => {
              if (!window.hubAPI?.deleteVaultFile) return;
              try {
                // Returns false when the unlink actually failed (locked file, permissions).
                const gone = await window.hubAPI.deleteVaultFile(btn.dataset.path);
                if (gone === false) {
                  toast('⚠ ' + (t('ord.vault_delete_failed') || 'Could not delete that file — it may be open in another program'), 'error', 6000);
                  return;
                }
                refreshVaultFiles();
              } catch (e) {
                toast(t('common.error') + ': ' + (e?.message || 'delete failed'), 'error');
              }
            });
          });
        } catch (e) { console.error('vault list error', e); }
      }
      refreshVaultFiles();
      const addVaultBtn = modal.querySelector('#btnAddVaultFile');
      if (addVaultBtn && window.hubAPI?.pickFile && window.hubAPI?.copyFileToVault) {
        addVaultBtn.addEventListener('click', async () => {
          try {
            const srcPath = await window.hubAPI.pickFile({ filters: [{ name: '3D Files', extensions: ['stl','3mf','obj','step','stp','gcode','zip'] }] });
            if (!srcPath) return;
            // copyFileToVault RETURNS { ok:false, error } when the source is outside the
            // allowed directories — it does not throw. Ignoring that reported success for
            // a file that was never attached, which is routine for this audience: models
            // on a NAS, an external drive, or a customer's USB stick.
            const res = await window.hubAPI.copyFileToVault(srcPath, order.id);
            if (!res || res.ok === false) {
              toast('⚠ ' + (res && res.error ? res.error : (t('ord.vault_add_failed') || 'Could not attach that file')), 'error', 6000);
              return;
            }
            refreshVaultFiles();
            toast(`📁 ${t('ord.vault_files')}`, 'success');
          } catch (e) {
            console.error('vault add error', e);
            toast('⚠ ' + (t('ord.vault_add_failed') || 'Could not attach that file'), 'error', 6000);
          }
        });
      }

      // Extra lines
      const oeExtraListEl = modal.querySelector('#oeExtraLinesList');
      const refreshOeLines = () => {
        if (oeExtraListEl) {
          oeExtraListEl.innerHTML = renderOeExtraLinesHtml(draft.extraLines);
          wireOeLines();
        }
      };
      function wireOeLines() {
        oeExtraListEl.querySelectorAll('.oe-el-label').forEach((inp, i) => {
          inp.addEventListener('input', () => { draft.extraLines[i].label = inp.value; });
        });
        oeExtraListEl.querySelectorAll('.oe-el-amount').forEach((inp, i) => {
          inp.addEventListener('input', () => {
            const line = draft.extraLines[i];
            line.amount = Math.max(0, +inp.value || 0);
            // Typing a figure here overrides a percentage this line was logged
            // with. Keeping `pct` would leave the two disagreeing — the invoice
            // showing one number and any re-quote computing another.
            delete line.pct;
          });
        });
        oeExtraListEl.querySelectorAll('.oe-el-rm').forEach(btn => {
          btn.addEventListener('click', () => { draft.extraLines.splice(+btn.dataset.oeli, 1); refreshOeLines(); });
        });
      }
      wireOeLines();
      modal.querySelector('#oeAddExtraLine').addEventListener('click', () => {
        draft.extraLines.push({ id: uid('EL'), label: '', amount: 0 });
        refreshOeLines();
      });

      // Instalments (Feature 8)
      const instListEl = modal.querySelector('#oeInstalmentList');
      function renderInstalments() {
        if (!instListEl) return;
        if (draft.instalments.length === 0) {
          instListEl.innerHTML = `<div style="color:var(--text-muted); font-size:12.5px; padding:4px 0;">${escapeHtml(t('inst.unpaid'))}</div>`;
          return;
        }
        const paidTotal = draft.instalments.filter(ins => ins.paid).reduce((s, ins) => s + (+ins.amount || 0), 0);
        const totalAmt  = draft.instalments.reduce((s, ins) => s + (+ins.amount || 0), 0);
        instListEl.innerHTML = `
          <div style="font-size:11.5px; color:var(--text-muted); margin-bottom:8px;">
            ${escapeHtml(t('inst.progress', { paid: fmtMoney(paidTotal), total: fmtMoney(totalAmt) }))}
          </div>
          ${draft.instalments.map((ins, i) => `
            <div class="instalment-row${ins.paid ? ' paid' : ''}">
              <span class="inst-label">
                <input type="text" class="inst-note-inp" data-ii="${i}" value="${escapeHtml(ins.note || '')}" placeholder="${escapeHtml(t('inst.note'))}" style="width:120px; font-size:12px; border:1px solid var(--border); background:var(--surface-2); border-radius:4px; padding:2px 6px; color:var(--text);">
                ${ins.dueDate ? `<span class="inst-due">${escapeHtml(ins.dueDate)}</span>` : ''}
              </span>
              <input type="number" class="inst-amt-inp" data-ii="${i}" value="${ins.amount || ''}" min="0" step="0.01" style="width:80px; font-size:12px; border:1px solid var(--border); background:var(--surface-2); border-radius:4px; padding:2px 6px; color:var(--text);">
              <input type="date" class="inst-due-inp" data-ii="${i}" value="${escapeHtml(ins.dueDate || '')}" style="font-size:11px; border:1px solid var(--border); background:var(--surface-2); border-radius:4px; padding:2px 4px; color:var(--text);">
              <button class="btn small${ins.paid ? '' : ' success'} inst-pay-btn" data-ii="${i}">${escapeHtml(ins.paid ? t('inst.paid') : t('inst.mark_paid'))}</button>
              <button class="btn danger small inst-rm-btn" data-ii="${i}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
            </div>`).join('')}`;
        instListEl.querySelectorAll('.inst-note-inp').forEach(inp => { inp.addEventListener('input', () => { draft.instalments[+inp.dataset.ii].note = inp.value; }); });
        instListEl.querySelectorAll('.inst-amt-inp').forEach(inp => { inp.addEventListener('input', () => { draft.instalments[+inp.dataset.ii].amount = Math.max(0, +inp.value || 0); }); });
        instListEl.querySelectorAll('.inst-due-inp').forEach(inp => { inp.addEventListener('input', () => { draft.instalments[+inp.dataset.ii].dueDate = inp.value; }); });
        instListEl.querySelectorAll('.inst-pay-btn').forEach(btn => {
          btn.addEventListener('click', () => {
            const ins = draft.instalments[+btn.dataset.ii];
            ins.paid = !ins.paid;
            ins.paidAt = ins.paid ? localDateStr() : null;
            renderInstalments();
          });
        });
        instListEl.querySelectorAll('.inst-rm-btn').forEach(btn => {
          btn.addEventListener('click', () => { draft.instalments.splice(+btn.dataset.ii, 1); renderInstalments(); });
        });
      }
      renderInstalments();
      modal.querySelector('#oeAddInstalment')?.addEventListener('click', () => {
        draft.instalments.push({ id: uid('INS'), amount: 0, note: '', dueDate: '', paid: false, paidAt: null });
        renderInstalments();
      });
      // Auto-generate an evenly-split dated plan (unpaid rows — no money moves;
      // collection stays the existing mark-paid flow). Reuses lib/payment-plan.
      modal.querySelector('#oeGenInstalments')?.addEventListener('click', async () => {
        if (typeof KhaytPaymentPlan === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
        // What is LEFT to pay, not the gross price. A job with a deposit already
        // taken produced a schedule that billed the deposit a second time —
        // SAR 3,000 across three payments on a job with SAR 2,000 outstanding —
        // and the customer was asked for money they had handed over.
        const total = orderOwedRaw(order);
        if (total <= 0) {
          toast((+order.price || 0) <= 0
            ? (t('inst.need_price') || 'Set an order price first')
            : (t('inst.nothing_owed') || 'This order is already paid in full'), 'error');
          return;
        }
        if (draft.instalments.length && !(await confirmModal(t('inst.replace_q') || 'Replace the current installments?', { danger: true }))) return;
        const today = new Date();
        // Clamp to the target month's length: new Date(2026, 1, 31) silently
        // rolls over into March, so an instalment plan generated on the 31st
        // skipped February entirely.
        const _fdY = today.getFullYear(), _fdM = today.getMonth() + 1;
        const _lastDay = new Date(_fdY, _fdM + 1, 0).getDate();
        const firstDue = localDateStr(new Date(_fdY, _fdM, Math.min(today.getDate(), _lastDay)));
        const schedule = KhaytPaymentPlan.buildSchedule({ total, depositAmount: 0, installments: 3, firstDueDate: firstDue, intervalDays: 30 });
        draft.instalments = schedule.map((s, i) => ({ id: uid('INS'), amount: s.amount, dueDate: s.dueDate, note: '', paid: false, paidAt: null }));
        // The cash the order ALREADY held when this plan was built. The save path
        // needs it to add instalment payments to the deposit rather than taking
        // the larger of the two — see the paidAmount rule below. Recorded here
        // because only here is it known that the schedule covers the BALANCE.
        draft.instalmentBase = +order.paidAmount || 0;
        renderInstalments();
        toast(t('inst.generated') || 'Generated a 3-payment plan — edit amounts/dates as needed', 'success', 5000);
      });

      // File attachments
      const attachBtn = modal.querySelector('#btnAttachFile');
      const filesListEl = modal.querySelector('#attachedFilesList');
      const refreshFiles = () => { if (filesListEl) filesListEl.innerHTML = renderAttachedFiles(draft.attachedFiles); };
      if (attachBtn) {
        attachBtn.addEventListener('click', async () => {
          try {
            const result = await window.hubAPI.pickAndSaveOrderFile(order.id);
            if (result) {
              draft.attachedFiles.push(result);
              refreshFiles();
            }
          } catch (e) {
            console.error('attach file error', e);
            toast(t('oe.attach_failed') || 'Could not attach file', 'error');
          }
        });
      }
      if (filesListEl) {
        filesListEl.addEventListener('click', (e) => {
          const openBtn = e.target.closest('[data-act="open-file"]');
          const rmBtn   = e.target.closest('[data-act="rm-file"]');
          if (openBtn && window.hubAPI?.openOrderFile) {
            const f = draft.attachedFiles[+openBtn.dataset.fi];
            if (f) window.hubAPI.openOrderFile(f.filename);
          }
          if (rmBtn) {
            const fi = +rmBtn.dataset.fi;
            const removed = draft.attachedFiles[fi];
            if (removed?.filename) pendingFileDeletes.push(removed.filename);
            draft.attachedFiles.splice(fi, 1);
            refreshFiles();
          }
        });
      }

      const grid = modal.querySelector('#orderPhotos');
      const fileInput = modal.querySelector('#orderPhotoInput');

      const refresh = () => { grid.innerHTML = photosHtml(); };

      grid.addEventListener('click', (e) => {
        const add = e.target.closest('[data-act="add-photo"]');
        const rm  = e.target.closest('[data-act="rm-photo"]');
        if (add) fileInput.click();
        if (rm) {
          const i = +rm.dataset.pi;
          const removed = draft.printPhotos[i];
          if (removed?.filename) pendingDeletes.push(removed.filename);
          draft.printPhotos.splice(i, 1);
          // Drop any pending full for this index
          for (let p = pendingFulls.length - 1; p >= 0; p--) {
            if (pendingFulls[p].idx === i) pendingFulls.splice(p, 1);
            else if (pendingFulls[p].idx > i) pendingFulls[p].idx--;
          }
          refresh();
        }
      });

      fileInput.addEventListener('change', async (e) => {
        const file = e.target.files?.[0];
        e.target.value = '';
        if (!file) return;
        if (file.size > 8 * 1024 * 1024) { toast(t('pe.image_too_big'), 'error'); return; }
        try {
          const thumb = await resizeImage(file, 240, 0.85);
          const full  = await resizeImage(file, 1600, 0.88);
          const idx = draft.printPhotos.length;
          draft.printPhotos.push({ thumb, filename: null });
          pendingFulls.push({ idx, dataUrl: full });
          refresh();
        } catch (err) {
          console.error(err);
          toast(t('pe.upload_failed') || 'Photo upload failed', 'error');
        }
      });

      // Round 12 Feature 10: Internal comment thread
      renderOrderComments(orderId);

      // Round 12 Feature 5: Auto-link carrier tracking URL
      const carrierTrackBtn = document.createElement('button');
      carrierTrackBtn.className = 'btn ghost small';
      carrierTrackBtn.type = 'button';
      carrierTrackBtn.title = 'Open tracking page';
      carrierTrackBtn.textContent = '🔗 Track';
      carrierTrackBtn.style.cssText = 'margin-top:6px;';
      const trackRow = modal.querySelector('[data-f="trackingNumber"]')?.parentNode;
      if (trackRow) trackRow.appendChild(carrierTrackBtn);
      carrierTrackBtn.addEventListener('click', () => {
        const url = getCarrierTrackingUrl(draft.courierName, draft.trackingNumber);
        if (url) window.hubAPI?.openExternal?.(url);
        else toast(t('ship.need_courier'), 'warning');
      });
    },
    async onSave() {
      // Feature 6 (new 8-pack): Capacity check — warn if machine queue exceeds due date
      const newDueDate = (document.querySelector('[data-f="dueDate"]'))?.value || draft.dueDate;
      if (newDueDate && order.machineId) {
        const clearDate = estimateMachineQueueClearDate(order.machineId, order.id);
        const due = new Date(newDueDate);
        if (clearDate > due) {
          const clearStr = clearDate.toLocaleDateString(localeTag());
          const ok = await confirmModal(
            t('oe.capacity_warn', { date: clearStr }) ||
              `Machine queue clears on ${clearStr}, which is after the due date. Save anyway?`,
            {
              okText: t('oe.capacity_save_anyway') || 'Save anyway',
              cancelText: t('oe.capacity_change_machine') || 'Change machine',
              danger: false,
            }
          );
          if (!ok) return false;
        }
      }

      // Feature 3: Spool over-commit check
      const ocWarnings = checkSpoolOvercommit(order.parts || [], order.id);
      if (ocWarnings.length > 0) {
        const msgs = ocWarnings.map(w =>
          t('inv.overcommit_confirm', { name: w.spoolName, needed: Math.round(w.needed), available: Math.round(w.available) })
        ).join('\n');
        const ok = await confirmModal('⚠️ ' + msgs, { danger: false });
        if (!ok) return false;
      }

      // Feature 8: Record edit history before overwriting
      const existingOrder = printLog.find(o => o.id === order.id);
      if (existingOrder) {
        // Which fields are worth recording, and what counts as a change, is
        // lib/order-edit.js's answer — so an edit made anywhere else leaves the
        // same trace as one made here.
        recordOrderEdit(order, EditRules().changesBetween(existingOrder, {
          dueDate: draft.dueDate || null,
          discountPct: draft.discountPct,
          shippingCost: draft.shippingCost,
          priority: draft.priority,
          priorityLevel: draft.priorityLevel,
        }));
      }

      // Persist any pending full images to disk
      for (const { idx, dataUrl } of pendingFulls) {
        if (!draft.printPhotos[idx]) continue;
        try {
          const fname = await window.hubAPI.saveOrderPhoto(order.id, idx + '-' + Date.now().toString(36), dataUrl);
          draft.printPhotos[idx].filename = fname;
        } catch (e) {
          console.error('save order photo failed', e);
          toast(t('pe.save_failed') || 'Could not save photo to disk', 'error');
        }
      }
      // Delete any queued removals
      if (pendingDeletes.length > 0 && window.hubAPI?.deleteOrderPhoto) {
        for (const f of pendingDeletes) {
          try { await window.hubAPI.deleteOrderPhoto(f); } catch (_) {}
        }
      }
      order.notes = draft.notes;
      order.internalNotes = draft.internalNotes || undefined;
      order.invoiceNotes = draft.invoiceNotes || undefined;
      order.tags = draft.tags.length > 0 ? draft.tags : undefined;
      order.dueDate = draft.dueDate || null;
      // `true` or gone — never `false`. Every existing order predates this, so
      // an absent key must mean one thing rather than two.
      KhaytBusinessScope.setNonBusiness(order, !!draft.nonBusiness);
      Object.assign(order, EditRules().priorityFrom(
        draft.priorityLevel || (draft.priority ? 'high' : 'normal')));
      order.operatorId = draft.operatorId || undefined;
      order.printPhotos = draft.printPhotos;
      order.attachedFiles = draft.attachedFiles;
      order.courierName = draft.courierName || undefined;
      order.trackingNumber = draft.trackingNumber || undefined;
      order.deliveryAddress = draft.deliveryAddress || undefined;
      order.instalments = draft.instalments.length > 0 ? draft.instalments.map(ins => ({ ...ins })) : undefined;
      // Meaningless without a schedule, so it goes when the schedule does.
      order.instalmentBase = draft.instalments.length > 0 ? draft.instalmentBase : undefined;
      // Feature 2: Persist actual timestamps
      const psaEl = document.getElementById('oePrintingStartedAt');
      const cmpEl = document.getElementById('oeCompletedAt');
      if (psaEl && psaEl.value) {
        order.printingStartedAt = new Date(psaEl.value).toISOString();
      } else if (psaEl && !psaEl.value) {
        // keep existing if present and field left blank intentionally only clear if was never set
      }
      if (cmpEl && cmpEl.value) {
        order.completedAt = new Date(cmpEl.value).toISOString();
      }
      // Update paidAmount from instalments if present
      if (draft.instalments.length > 0) {
        const instPaid = draft.instalments.filter(ins => ins.paid).reduce((s, ins) => s + (+ins.amount || 0), 0);
        // paidAmount is the authoritative CASH figure — the deposit is written
        // straight into it at order creation, and payStatus()/orderOwedBase()
        // both read it. Assigning instPaid over it destroyed that deposit: the
        // plan generator builds a schedule with depositAmount:0 spanning the
        // full price, so a freshly generated plan has instPaid = 0 and a 500
        // deposit vanished with no ledger entry the moment the order was saved.
        // Instalment payments are additional cash, so ADD them to what the order
        // already held — but only when the schedule is known to cover the
        // BALANCE rather than the gross price.
        //
        // Math.max was right only BECAUSE the generator used to span the full
        // price: a 3,000 job with a 1,000 deposit got a 3,000 plan, so max(1000,
        // 3000) = 3000 and the order settled. It also meant the customer was
        // billed 4,000 for a 3,000 job, which is what the generator fix stopped.
        // With a 2,000 plan, max(1000, 2000) = 2000 and the order shows 1,000
        // owed FOREVER — the customer has paid in full and is still chased.
        //
        // instalmentBase is the cash that existed when the plan was generated,
        // written only by that generator. Plans made before it — and hand-built
        // ones, whose amounts mean whatever the shop decided — have none, and
        // keep the old rule, which is the right one for a schedule that already
        // spans the whole price.
        //
        // Still wrapped in Math.max, and that is not belt-and-braces. paidAmount
        // can have grown since the plan was made — a payment taken at the counter
        // and typed straight in — and `base + instPaid` would then be LOWER than
        // what the order already holds, destroying that cash. Which is precisely
        // the bug money-integrity.test.js exists to catch, and it caught this.
        const instBase = draft.instalmentBase;
        const fromPlan = (typeof instBase === 'number' && instBase >= 0)
          ? Math.round((instBase + instPaid) * 100) / 100
          : instPaid;
        order.paidAmount = Math.max(+order.paidAmount || 0, fromPlan);
        // Settled against the ORDER PRICE, not the instalment total. Instalment
        // amounts are freely editable, so a partial plan (two 100 rows on a
        // 2,000 order) marked paid reported the whole order as settled — and
        // paymentStatus is what the payment_received/paid webhooks carry.
        const owed = +order.price || 0;
        const paid = order.paidAmount;
        order.paymentStatus = paid <= 0 ? 'unpaid' : (owed > 0 && paid + 0.005 >= owed ? 'paid' : 'partial');
      }
      // Delete removed files from disk
      if (pendingFileDeletes.length > 0 && window.hubAPI?.deleteOrderFile) {
        for (const fn of pendingFileDeletes) {
          try { await window.hubAPI.deleteOrderFile(fn); } catch (_) {}
        }
      }
      // Recalculate price when any price-affecting field changed (compute prev values BEFORE overwriting)
      const prevOldExtra   = (order.extraLines || []).reduce((s, l) => s + (+l.amount || 0), 0);
      const newExtraTotal  = draft.extraLines.reduce((s, l) => s + Math.max(0, +l.amount || 0), 0);
      if (draft.discountPct !== (order.discountPct || 0) ||
          draft.shippingCost !== (+order.shippingCost || 0) ||
          newExtraTotal !== prevOldExtra) {
        const prevDiscountPct = order.discountPct || 0;
        const prevShipping    = +order.shippingCost || 0;
        const sellingBase = order.priceBeforeDiscount ||
          (prevDiscountPct < 100
            ? (+order.price - prevShipping - prevOldExtra) / (1 - prevDiscountPct / 100)
            : (+order.price - prevShipping - prevOldExtra)); // 100% discount: base = original price
        const newPrice = sellingBase * (1 - draft.discountPct / 100) + draft.shippingCost + newExtraTotal;
        order.price = +newPrice.toFixed(2);
        order.discountPct = draft.discountPct;
        order.priceBeforeDiscount = draft.discountPct > 0 ? +sellingBase.toFixed(2) : null;
        order.shippingCost = draft.shippingCost;
        // Re-clamp paidAmount in case price was reduced below what was already paid
        if ((order.paidAmount || 0) > (+order.price || 0)) {
          order.paidAmount = +order.price || 0;
          if (order.paidAmount >= +order.price) {
            order.paymentStatus = 'paid';
          }
        }
      }
      // Persist extra lines (after price recalculation to use correct prev values)
      order.extraLines = draft.extraLines.length > 0 ? draft.extraLines.map(l => ({ ...l })) : undefined;
      // Persist custom metadata fields
      const customFields = settings.customFields || [];
      if (customFields.length > 0) {
        const customData = {};
        customFields.forEach(f => {
          const el = document.querySelector(`[data-cf="${f.id}"]`);
          if (el) customData[f.id] = el.value.trim();
        });
        order.customData = Object.keys(customData).some(k => customData[k]) ? customData : undefined;
      }
      // Feature 1: Save part colours from the inline editors
      const colourInputs = document.querySelectorAll('.oe-part-colour');
      colourInputs.forEach(inp => {
        const pi = parseInt(inp.dataset.pi, 10);
        if (order.parts && order.parts[pi] !== undefined) {
          order.parts[pi].colour = inp.value.trim() || undefined;
        }
      });
      saveAll();
      renderLogs(); renderPortfolio(); renderDashboard(); renderAnalytics();
      toast(t('common.save'), 'success');
      return true;
    }
  });
}

/* ── Batch Print Planner ────────────────────────────────── */
function openBatchPlannerModal() {
  const candidates = printLog.filter(o => o.status !== 'completed' && o.status !== 'quote' && !o.voidedAt);
  if (candidates.length === 0) {
    toast(t('batch.no_orders') || 'No pending orders to plan', 'info');
    return;
  }

  const rowsHtml = candidates.map(o => {
    const totalWeight = (o.parts || []).reduce((s, p) => s + (+p.printWeight || 0) * (+p.qty || 1), 0);
    const machine = o.machineId ? (machines || []).find(m => m.id === o.machineId) : null;
    const matNames = [...new Set((o.parts || []).map(p => p.material).filter(Boolean))].join(', ');
    return `<label style="display:flex;align-items:flex-start;gap:10px;padding:8px 10px;border-radius:var(--radius-sm);cursor:pointer;border:1px solid transparent;transition:background .1s;" class="batch-row">
      <input type="checkbox" class="batch-cb" data-id="${o.id}" data-time="${+o.printTime || 0}" data-weight="${totalWeight.toFixed(1)}" data-mat="${escapeHtml(matNames)}" style="margin-top:2px;width:auto;flex-shrink:0;">
      <div style="flex:1;">
        <div style="font-weight:600;font-size:13px;">${escapeHtml(o.project || o.id)}</div>
        <div style="font-size:11.5px;color:var(--text-muted);">${escapeHtml(o.id)} · ${o.printTime}h · ${Math.round(totalWeight)}g${matNames ? ' · ' + escapeHtml(matNames) : ''}${machine ? ' · <span style="color:' + safeCssColor(machine.color) + ';">' + escapeHtml(machine.name) + '</span>' : ''}</div>
      </div>
      <span style="font-weight:600;color:var(--success);white-space:nowrap;">${fmtPrice(o.price)}</span>
    </label>`;
  }).join('');

  const bodyHtml = `
    <div style="margin-bottom:10px;display:flex;align-items:center;gap:10px;">
      <label style="display:flex;align-items:center;gap:6px;cursor:pointer;font-size:13px;">
        <input type="checkbox" id="batchSelectAll" style="width:auto;">
        <span>${escapeHtml(t('batch.select_all') || 'Select all')}</span>
      </label>
    </div>
    <div style="max-height:300px;overflow-y:auto;border:1px solid var(--border);border-radius:var(--radius);padding:4px 0;margin-bottom:14px;">
      ${rowsHtml}
    </div>
    <div id="batchSummary" style="background:var(--bg-elev);border-radius:var(--radius);padding:12px 16px;font-size:13px;min-height:64px;">
      <span style="color:var(--text-muted);">${escapeHtml(t('batch.select_hint') || 'Select orders to see totals')}</span>
    </div>
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-top:12px;">
      <button type="button" id="batchSuggest" class="btn small primary">🧩 ${escapeHtml(t('batch.suggest') || 'Suggest plates')}</button>
      <label style="font-size:12px;color:var(--text-muted);display:flex;align-items:center;gap:4px;">${escapeHtml(t('batch.max_hours') || 'Max h/plate')} <input type="number" id="batchMaxHours" min="1" step="1" value="24" style="width:60px;"></label>
      <label style="font-size:12px;color:var(--text-muted);display:flex;align-items:center;gap:4px;">${escapeHtml(t('batch.max_grams') || 'Max g/plate')} <input type="number" id="batchMaxGrams" min="1" step="50" value="1000" style="width:74px;"></label>
    </div>
    <div id="batchPlates" style="margin-top:12px;"></div>`;

  openFormModal({
    title: t('batch.title') || 'Batch Print Planner',
    saveLabel: t('common.close') || 'Close',
    sizeLg: true,
    bodyHtml,
    onSave() { return true; }
  });

  requestAnimationFrame(() => {
    const allCbs = document.querySelectorAll('.batch-cb');
    const selectAll = document.getElementById('batchSelectAll');
    const summary = document.getElementById('batchSummary');

    function updateSummary() {
      const checked = [...document.querySelectorAll('.batch-cb:checked')];
      if (checked.length === 0) {
        summary.innerHTML = `<span style="color:var(--text-muted);">${escapeHtml(t('batch.select_hint') || 'Select orders to see totals')}</span>`;
        return;
      }
      const totalTime = checked.reduce((s, cb) => s + +cb.dataset.time, 0);
      const totalWeight = checked.reduce((s, cb) => s + +cb.dataset.weight, 0);
      const totalRev = checked.reduce((s, cb) => {
        const o = printLog.find(x => x.id === cb.dataset.id);
        return s + (+o?.price || 0);
      }, 0);
      const matMap = {};
      checked.forEach(cb => {
        if (cb.dataset.mat) cb.dataset.mat.split(',').forEach(m => {
          const name = m.trim();
          if (name) matMap[name] = (matMap[name] || 0) + 1;
        });
      });
      const matHtml = Object.entries(matMap).map(([name, cnt]) => `<span style="background:var(--bg-card);padding:2px 8px;border-radius:10px;font-size:11px;">${escapeHtml(name)} ×${cnt}</span>`).join(' ');
      summary.innerHTML = `
        <div style="display:flex;flex-wrap:wrap;gap:20px;margin-bottom:8px;">
          <div><div style="font-size:18px;font-weight:700;">${checked.length}</div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('batch.orders') || 'Orders')}</div></div>
          <div><div style="font-size:18px;font-weight:700;">${totalTime.toFixed(1)}h</div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('batch.print_time') || 'Print time')}</div></div>
          <div><div style="font-size:18px;font-weight:700;">${Math.round(totalWeight)}g</div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('batch.total_weight') || 'Total weight')}</div></div>
          <div><div style="font-size:18px;font-weight:700;color:var(--success);">${fmtMoney(totalRev)}</div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('batch.revenue') || 'Revenue')}</div></div>
        </div>
        ${matHtml ? `<div style="display:flex;flex-wrap:wrap;gap:4px;">${matHtml}</div>` : ''}`;
    }

    allCbs.forEach(cb => cb.addEventListener('change', updateSummary));
    selectAll?.addEventListener('change', () => {
      allCbs.forEach(cb => { cb.checked = selectAll.checked; });
      updateSummary();
    });

    document.querySelectorAll('.batch-row').forEach(row => {
      row.addEventListener('mouseenter', () => row.style.background = 'var(--bg-elev)');
      row.addEventListener('mouseleave', () => row.style.background = '');
    });

    // Auto-suggest plates: pack the selected orders (or all if none selected)
    // into build batches by material + capacity (lib/plate-nesting.js).
    document.getElementById('batchSuggest')?.addEventListener('click', () => {
      const out = document.getElementById('batchPlates');
      if (typeof KhaytPlateNesting === 'undefined' || !out) return;
      const checked = [...document.querySelectorAll('.batch-cb:checked')];
      const ids = checked.length ? new Set(checked.map(cb => cb.dataset.id)) : null;
      const jobs = candidates.filter(o => !ids || ids.has(o.id)).map(o => ({
        id: o.id, project: o.project || o.id, hours: +o.printTime || 0,
        grams: (o.parts || []).reduce((s, p) => s + (+p.printWeight || 0) * (+p.qty || 1), 0),
        material: [...new Set((o.parts || []).map(p => p.material).filter(Boolean))][0] || o.material || '',
      }));
      const maxHours = Math.max(1, num(document.getElementById('batchMaxHours')?.value, 24));
      const maxGrams = Math.max(1, num(document.getElementById('batchMaxGrams')?.value, 1000));
      const { plates } = KhaytPlateNesting.planPlates(jobs, { maxHours, maxGrams });
      if (!plates.length) { out.innerHTML = `<span style="color:var(--text-muted);font-size:12.5px;">${escapeHtml(t('batch.select_hint') || 'Select orders first')}</span>`; return; }
      out.innerHTML = `<div style="font-size:12px;color:var(--text-muted);margin-bottom:6px;">${escapeHtml((t('batch.plates_n', { n: plates.length }) || `${plates.length} suggested plate(s)`))}</div>`
        + plates.map((p, i) => `
        <div style="border:1px solid var(--border);border-radius:var(--radius);padding:8px 12px;margin-bottom:8px;${p.oversize ? 'border-color:var(--warning,#d97706);' : ''}">
          <div style="font-size:12.5px;font-weight:600;margin-bottom:4px;">${escapeHtml(t('batch.plate') || 'Plate')} ${i + 1}${p.material ? ' · ' + escapeHtml(p.material) : ''} <span style="color:var(--text-muted);font-weight:400;">· ${p.hours}h · ${p.grams}g${p.oversize ? ' · ⚠ ' + escapeHtml(t('batch.oversize') || 'oversize') : ''}</span></div>
          <div style="font-size:12px;color:var(--text-soft,#c8ccd2);">${p.jobs.map(j => escapeHtml(j.project)).join(' · ')}</div>
        </div>`).join('');
    });
  });
}

/* ── Order Status Timeline ──────────────────────────────── */
function openOrderTimeline(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;

  const hist = order.statusHistory || [];
  if (hist.length === 0) {
    alert(t('ord.timeline_empty'));
    return;
  }

  const statusColors = {
    quote:     '#6366f1',
    pending:   '#6b7280',
    on_hold:   '#ef4444',
    printing:  '#22c55e',
    post:      '#f59e0b',
    qc:        '#3b82f6',
    completed: '#10b981',
  };

  const now = Date.now();
  const steps = hist.map((entry, i) => {
    const startMs = new Date(entry.at).getTime();
    const endMs   = i + 1 < hist.length ? new Date(hist[i + 1].at).getTime() : now;
    const durMs   = endMs - startMs;
    const durH    = durMs / 3600000;

    let durStr = '';
    if (durH < 1) {
      const mins = Math.round(durMs / 60000);
      durStr = `${mins}m`;
    } else if (durH < 24) {
      durStr = `${durH.toFixed(1)}h`;
    } else {
      const days = Math.floor(durH / 24);
      const remH = Math.round(durH % 24);
      durStr = remH > 0 ? `${days}d ${remH}h` : `${days}d`;
    }

    const isLast = i === hist.length - 1;
    const color = statusColors[entry.status] || '#6b7280';
    const localAt = new Date(entry.at).toLocaleString();
    const statusLabel = t('queue.' + entry.status) || entry.status;

    return { entry, startMs, durStr, color, isLast, localAt, statusLabel };
  });

  const totalMs  = new Date(hist[hist.length - 1].at).getTime() - new Date(hist[0].at).getTime();
  const totalH   = totalMs / 3600000;
  let totalStr   = '';
  if (totalH < 1)       totalStr = `${Math.round(totalMs / 60000)}m`;
  else if (totalH < 24) totalStr = `${totalH.toFixed(1)}h`;
  else { const d = Math.floor(totalH / 24); const h = Math.round(totalH % 24); totalStr = h > 0 ? `${d}d ${h}h` : `${d}d`; }

  const stepsHtml = steps.map((s, i) => `
    <div class="timeline-step${s.isLast ? ' timeline-last' : ''}">
      <div class="timeline-node" style="background:${s.color};box-shadow:0 0 0 3px ${s.color}33;"></div>
      ${i < steps.length - 1 ? '<div class="timeline-line"></div>' : ''}
      <div class="timeline-content">
        <span class="timeline-status" style="color:${s.color};">${escapeHtml(s.statusLabel)}</span>
        <span class="timeline-time">${escapeHtml(s.localAt)}</span>
        ${!s.isLast ? `<span class="timeline-dur">⏱ ${escapeHtml(s.durStr)}</span>` : '<span class="timeline-dur" style="color:var(--text-muted);font-style:italic;">(current)</span>'}
      </div>
    </div>`).join('');

  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = (client ? localName(client) : '') || (order.client || '');

  const overlay = appendStackedModal(`
    <div class="modal modal-form" style="max-width:480px;width:100%;">
      <div class="modal-header">
        <h3 id="modalTitle" style="margin:0;font-size:15px;">🕐 ${escapeHtml(t('ord.timeline_title'))} — ${escapeHtml(order.project || order.id)}</h3>
        <button class="btn ghost small" data-act="cancel" aria-label="Close" title="Close">×</button>
      </div>
      <div class="modal-body" style="max-height:70vh;overflow-y:auto;">
        <div style="margin-bottom:12px;font-size:12.5px;color:var(--text-muted);">
          ${clientName ? `👤 ${escapeHtml(clientName)} · ` : ''}
          ${escapeHtml(order.id)} · ${escapeHtml(t('ord.timeline_total'))}: <strong>${escapeHtml(totalStr)}</strong>
        </div>
        <div class="timeline-wrap">${stepsHtml}</div>
      </div>
      <div class="modal-footer">
        <button class="btn ghost" data-act="cancel">${escapeHtml(t('common.close') || 'Close')}</button>
      </div>
    </div>`, { zIndex: 10040 });
  if (!overlay) return;
  const closeTimeline = () => {
    document.removeEventListener('keydown', tlEscHandler);
    const idx = _escHandlerStack.indexOf(tlEscHandler);
    if (idx !== -1) _escHandlerStack.splice(idx, 1);
    overlay.remove();
  };
  const tlEscHandler = (e) => { if (e.key === 'Escape') closeTimeline(); };
  _escHandlerStack.push(tlEscHandler);
  document.addEventListener('keydown', tlEscHandler);
  overlay.querySelectorAll('[data-act="cancel"]').forEach(b => b.addEventListener('click', closeTimeline));
  overlay.addEventListener('click', e => { if (e.target === overlay) closeTimeline(); });
}

/* ============================================================
   Duplicate an order — clone into the build cart
   ============================================================ */
function duplicateOrder(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  currentBuild = (order.parts || []).map(p => {
    const copy = { ...p, id: uid('PRT') };
    // baseCost is a LINE total (unit cost x qty), matching what the calculator stores
    // when the part is first added. Using the per-unit cost here re-quoted a duplicated
    // or reprinted order at 1/qty of its real cost while still printing every unit.
    copy.baseCost = partTotalCost(copy);
    return copy;
  });
  currentBuildFromProductId = order.productId || null;
  currentClientId = order.clientId || null;
  currentExtraLines = (order.extraLines || []).map(l => ({ ...l }));
  if ($('#discountPct'))   $('#discountPct').value   = String(order.discountPct   || 0);
  if ($('#shippingCost'))  $('#shippingCost').value  = String(order.shippingCost  || 0);
  if ($('#calcClientRef')) $('#calcClientRef').value = order.clientRef || '';
  // Pre-fill client field with the order's client display name
  $('#clientInput').value = order.project || '';
  switchTab('calculator-tab');
  renderBuild();
  renderExtraLines();
  updateGrandTotal(); // populates #calcCurrency options
  if ($('#calcCurrency')) $('#calcCurrency').value = order.currency || '';
  toast(t('oe.duplicated'), 'success');
}

// Load an order's parts into the calculator as a NEW order, remembering the
// linkage (reprintOf/reason/cost/chain) so logPrint stamps it on save. The
// reprint is a fresh order — it deducts its own filament when it passes QC; the
// original's material accounting is never touched.
function createLinkedReprint(original, reason, costMode) {
  if (!original) return;
  currentBuild = (original.parts || []).map(p => {
    const copy = { ...p, id: uid('PRT') };
    // baseCost is a LINE total (unit cost x qty), matching what the calculator stores
    // when the part is first added. Using the per-unit cost here re-quoted a duplicated
    // or reprinted order at 1/qty of its real cost while still printing every unit.
    copy.baseCost = partTotalCost(copy);
    return copy;
  });
  currentBuildFromProductId = original.productId || null;
  currentClientId = original.clientId || null;
  currentExtraLines = (original.extraLines || []).map(l => ({ ...l }));
  pendingReprintMeta = {
    of: original.id,
    reason: reason || 'manual',
    cost: costMode || 'billable',
    chain: original.reprintChain || original.id,
  };
  switchTab('calculator-tab');
  if ($('#clientInput')) $('#clientInput').value = original.project || '';
  if ($('#discountPct')) $('#discountPct').value = String(original.discountPct || 0);
  if ($('#shippingCost')) $('#shippingCost').value = String(original.shippingCost || 0);
  renderBuild();
  renderExtraLines();
  updateGrandTotal(); // populates #calcCurrency options
  if ($('#calcCurrency')) $('#calcCurrency').value = original.currency || '';
  const msg = reason === 'rma' ? (t('qc.rma_reprint_toast') || 'RMA reprint loaded — review and save')
    : (t('oe.reprint_toast') || 'Reprint loaded — review and save');
  toast(msg, 'success');
}

function reprintOrder(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  // Manual reprint: billable by default (owner adjusts the price in the calculator).
  createLinkedReprint(order, 'manual', 'billable');
}

/* ============================================================
   RMA / warranty — customer-reported defect on a delivered order
   ============================================================ */
function openRmaModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const qcCfg = (settings && settings.qc) || {};
  const within = computeWithinWarranty(order.deliveredAt, qcCfg.warrantyDays, Date.now());
  const warnStyle = within ? 'color:var(--success,#159a6b);' : 'color:var(--danger,#c23b42);';
  const warnTxt = within ? (t('qc.within_warranty') || 'Within warranty') : (t('qc.out_of_warranty') || 'Outside warranty');
  openFormModal({
    title: t('qc.rma_title') || 'Open RMA',
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <p style="font-size:12.5px;margin-bottom:10px;${warnStyle}"><strong>${escapeHtml(warnTxt)}</strong>${order.deliveredAt ? ' · ' + escapeHtml(t('ord.delivered') || 'Delivered') + ' ' + escapeHtml(new Date(order.deliveredAt).toLocaleDateString(localeTag())) : ''}</p>
      <label>${escapeHtml(t('qc.rma_reason') || 'Reported problem')}</label>
      <input type="text" id="rmaReason" style="width:100%;margin-bottom:10px;" placeholder="${escapeHtml(t('qc.rma_reason_ph') || 'e.g. layer split after a week')}">
      <label>${escapeHtml(t('qc.rma_resolution') || 'Resolution')}</label>
      <select id="rmaResolution" style="margin-bottom:10px;">
        <option value="reprint" selected>${escapeHtml(t('qc.res_reprint') || 'Reprint (replacement)')}</option>
        <option value="refund">${escapeHtml(t('qc.res_refund') || 'Refund')}</option>
        <option value="declined">${escapeHtml(t('qc.res_declined') || 'Declined')}</option>
      </select>
      <label style="display:flex;align-items:center;gap:8px;font-weight:normal;">
        <input type="checkbox" id="rmaWithin" ${within ? 'checked' : ''} style="width:auto;"> ${escapeHtml(t('qc.within_warranty') || 'Within warranty')}
      </label>`,
    onMount(modal) { setTimeout(() => modal.querySelector('#rmaReason')?.focus(), 40); },
    onSave(modal) {
      const reason = modal.querySelector('#rmaReason').value.trim();
      const resolution = modal.querySelector('#rmaResolution').value;
      const withinWarranty = !!modal.querySelector('#rmaWithin')?.checked;
      order.rma = {
        reportedAt: new Date().toISOString(),
        reportedBy: (settings && settings.activeOperatorId) || null,
        reason: reason || null,
        withinWarranty,
        resolution,
        reprintId: null,
      };
      saveAll();
      renderKanban(); renderLogs();
      if (typeof fireQcWebhook === 'function') fireQcWebhook('rma_opened', order);
      toast(t('qc.rma_opened') || 'RMA opened', 'info');
      if (resolution === 'reprint') {
        // Within warranty → shop eats it (no charge); outside → billable by default.
        setTimeout(() => createLinkedReprint(order, 'rma', withinWarranty ? 'shop' : 'billable'), 0);
      }
      return true;
    }
  });
}

/* ============================================================
   Order Print Label
   ============================================================ */
async function generateOrderLabel(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;

  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = client ? localName(client) : (order.client || '');
  const machine = order.machineId ? machines.find(m => m.id === order.machineId) : null;
  const shopName = shopField('biz') || 'Khayt';
  const accentColor = safeCssColor(settings.invAccentColor, '#5E2E14');

  // QR code — encode the order ID
  let qrSvg = '';
  if (window.hubAPI?.generateQR) {
    try { qrSvg = await window.hubAPI.generateQR(order.id, { width: 80, margin: 0 }); }
    catch(e) { /* graceful fallback — no QR */ }
  }

  const totalParts = (order.parts || []).length;
  const totalWeight = (order.parts || []).reduce((s, p) => s + (+p.printWeight || 0), 0);
  const weightStr = totalWeight > 0 ? `${Math.round(totalWeight)}g` : '';
  const materialStr = order.material || (order.parts?.[0]?.material) || '';

  // Printed output must follow the shop's own language, not default to LTR English.
  const docLang = (typeof i18n !== 'undefined' && i18n.current === 'ar') ? 'ar' : 'en';
  const docDir = docLang === 'ar' ? 'rtl' : 'ltr';
  const html = `<!DOCTYPE html>
<html lang="${docLang}" dir="${docDir}">
<head>
<meta charset="UTF-8">
<title>Label — ${escapeHtml(order.id)}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: -apple-system, 'Segoe UI', sans-serif; background:#fff; color:#111; }
  .label {
    width: 85mm; min-height: 54mm;
    border: 1px solid #ccc; border-radius: 3mm;
    padding: 4mm 5mm; display: flex; flex-direction: column; gap: 2mm;
    page-break-after: always;
  }
  .label-header {
    display: flex; justify-content: space-between; align-items: flex-start;
    border-bottom: 0.5mm solid ${accentColor}; padding-bottom: 2mm; margin-bottom: 1mm;
  }
  .shop { font-size: 7pt; color: #888; font-weight: 600; text-transform: uppercase; letter-spacing: .4pt; }
  .order-id { font-size: 11pt; font-weight: 800; color: ${accentColor}; font-family: monospace; }
  .qr { width: 20mm; height: 20mm; flex-shrink: 0; }
  .qr svg { width: 100%; height: 100%; }
  .body { flex: 1; display: flex; gap: 3mm; }
  .info { flex: 1; display: flex; flex-direction: column; gap: 1.5mm; }
  .project { font-size: 9.5pt; font-weight: 700; line-height: 1.2; }
  .client  { font-size: 8pt; color: #555; }
  .meta    { font-size: 7.5pt; color: #666; display: flex; flex-wrap: wrap; gap: 2mm; margin-top: 1mm; }
  .meta span { background: #f3f4f6; border-radius: 2mm; padding: 0.5mm 1.5mm; }
  .footer { font-size: 6.5pt; color: #aaa; text-align: center; border-top: 0.3mm solid #eee; padding-top: 1.5mm; margin-top: 1mm; }
  @media print {
    body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .label { border: 0.5mm solid #ccc; }
  }
</style>
</head>
<body>
<div class="label">
  <div class="label-header">
    <div>
      <div class="shop">${escapeHtml(shopName)}</div>
      <div class="order-id">${escapeHtml(order.id)}</div>
    </div>
    ${qrSvg ? `<div class="qr">${qrSvg}</div>` : ''}
  </div>
  <div class="body">
    <div class="info">
      <div class="project">${escapeHtml(order.project || '—')}</div>
      ${clientName ? `<div class="client">👤 ${escapeHtml(clientName)}</div>` : ''}
      <div class="meta">
        ${materialStr ? `<span>🧵 ${escapeHtml(materialStr)}</span>` : ''}
        ${weightStr   ? `<span>⚖ ${escapeHtml(weightStr)}</span>` : ''}
        ${totalParts > 1 ? `<span>🔧 ${totalParts} parts</span>` : ''}
        ${machine     ? `<span>🖨 ${escapeHtml(machine.name)}</span>` : ''}
        ${order.dueDate ? `<span>📅 ${escapeHtml(order.dueDate)}</span>` : ''}
        ${order.priorityLevel && order.priorityLevel !== 'normal' ? `<span style="background:#fee2e2;color:#dc2626;">⚡ ${escapeHtml(order.priorityLevel)}</span>` : ''}
      </div>
    </div>
  </div>
  ${order.internalNotes ? `<div style="font-size:7pt;color:#444;border-top:0.3mm solid #eee;padding-top:1.5mm;">📝 ${escapeHtml(order.internalNotes.slice(0, 120))}</div>` : ''}
  <div class="footer">${escapeHtml(new Date().toLocaleDateString(localeTag()))} · Khayt</div>
</div>
<script>window.onload = () => { setTimeout(() => window.print(), 250); };<\/script>
</body></html>`;

  // Open in new window for printing
  const win = window.open('', '_blank', 'width=400,height=320,toolbar=0,menubar=0,scrollbars=0');
  if (win) {
    win.document.open();
    win.document.write(sanitizePrintHtml(html));
    win.document.close();
  } else {
    // Fallback: save to disk and open
    if (window.hubAPI?.saveHtml) {
      const saved = await window.hubAPI.saveHtml(html, `label-${order.id}.html`);
      if (saved?.path) window.hubAPI?.openPath?.(saved.path);
    }
    toast('🏷 ' + (t('ord.label_generated') || 'Label generated'), 'success');
  }
}

/* ============================================================
   Packing Slip
   ============================================================ */
async function generatePackingSlip(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = client ? localName(client) : (order.client || '');
  const clientPhone = client?.phone || '';
  const deliveryAddr = order.deliveryAddress
    || (client?.addresses?.[0]?.address || '');
  const shopName = shopField('biz') || 'Khayt';
  const shopPhone = settings.phone || '';
  const shopEmail = settings.email || '';
  const accentColor = safeCssColor(settings.invAccentColor, '#5E2E14');
  const dateStr = order.completedAt
    ? new Date(order.completedAt).toLocaleDateString(localeTag())
    : order.date || localDateStr();

  const parts = order.parts || [];
  const rowsHtml = parts.map(p => {
    const qty = p.qty || 1;
    const wt = Math.round((+p.printWeight || 0) * qty);
    return `<tr>
      <td>${escapeHtml(p.name || order.project || '—')}</td>
      <td>${escapeHtml(p.material || order.material || '—')}</td>
      <td>${escapeHtml(p.color || p.colour || '—')}</td>
      <td style="text-align:center;">${qty}</td>
      <td style="text-align:right;">${wt > 0 ? wt + 'g' : '—'}</td>
    </tr>`;
  }).join('');

  const totalWeight = parts.reduce((s, p) => s + (+p.printWeight || 0) * (p.qty || 1), 0);
  const totalQty = parts.reduce((s, p) => s + (p.qty || 1), 0);

  // Printed output must follow the shop's own language, not default to LTR English.
  const docLang = (typeof i18n !== 'undefined' && i18n.current === 'ar') ? 'ar' : 'en';
  const docDir = docLang === 'ar' ? 'rtl' : 'ltr';
  const html = `<!DOCTYPE html>
<html lang="${docLang}" dir="${docDir}">
<head>
<meta charset="UTF-8">
<title>Packing Slip — ${escapeHtml(order.id)}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,'Segoe UI',sans-serif; font-size:11pt; color:#111; background:#fff; padding:20mm; }
  .header { display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:10mm; border-bottom:2px solid ${accentColor}; padding-bottom:6mm; }
  .shop-name { font-size:18pt; font-weight:800; color:${accentColor}; }
  .shop-sub { font-size:9pt; color:#666; margin-top:2mm; }
  .slip-title { font-size:22pt; font-weight:700; color:${accentColor}; text-align:right; text-transform:uppercase; letter-spacing:1pt; }
  .slip-meta { font-size:9.5pt; color:#444; text-align:right; margin-top:2mm; line-height:1.7; }
  .section { margin-bottom:8mm; }
  .section-label { font-size:8pt; text-transform:uppercase; letter-spacing:.5pt; color:#888; margin-bottom:1.5mm; font-weight:700; }
  .bill-to { font-size:11pt; line-height:1.6; }
  table { width:100%; border-collapse:collapse; margin-bottom:6mm; }
  thead tr { background:${accentColor}; color:#fff; }
  thead th { padding:3mm 4mm; text-align:left; font-size:9pt; font-weight:700; letter-spacing:.3pt; }
  thead th:last-child, thead th:nth-child(4) { text-align:right; }
  tbody tr:nth-child(even) { background:#f9fafb; }
  td { padding:2.5mm 4mm; font-size:10pt; border-bottom:0.3mm solid #e5e7eb; }
  td:last-child, td:nth-child(4) { text-align:right; }
  tfoot td { padding:3mm 4mm; font-size:10.5pt; font-weight:700; border-top:1.5px solid #111; }
  .notes { background:#fffbeb; border-inline-start:3mm solid #fbbf24; padding:3mm 4mm; font-size:10pt; border-radius:1mm; margin-bottom:8mm; }
  .footer { text-align:center; font-size:9pt; color:#888; border-top:0.5mm solid #e5e7eb; padding-top:4mm; margin-top:4mm; }
  @media print { body { padding:15mm; } }
</style>
</head>
<body>
  <div class="header">
    <div>
      <div class="shop-name">${escapeHtml(shopName)}</div>
      <div class="shop-sub">${shopPhone ? escapeHtml(shopPhone) : ''}${shopPhone && shopEmail ? ' · ' : ''}${shopEmail ? escapeHtml(shopEmail) : ''}</div>
    </div>
    <div>
      <div class="slip-title">Packing Slip</div>
      <div class="slip-meta">
        <strong>${escapeHtml(t('common.date') || 'Date')}:</strong> ${escapeHtml(dateStr)}<br>
        <strong>${escapeHtml(t('log.order_id') || 'Order') || 'Order'}:</strong> ${escapeHtml(order.id)}
        ${order.invoiceNum ? `<br><strong>${escapeHtml(t('ord.invoice_num') || 'Invoice')}:</strong> ${escapeHtml(String(order.invoiceNum))}` : ''}
      </div>
    </div>
  </div>

  ${(clientName || deliveryAddr || clientPhone) ? `
  <div class="section">
    <div class="section-label">${escapeHtml(t('ps.ship_to') || 'Ship / Bill To')}</div>
    <div class="bill-to">
      ${clientName ? `<strong>${escapeHtml(clientName)}</strong><br>` : ''}
      ${deliveryAddr ? escapeHtml(deliveryAddr).replace(/\\n/g, '<br>') + '<br>' : ''}
      ${clientPhone ? escapeHtml(clientPhone) : ''}
    </div>
  </div>` : ''}

  <table>
    <thead>
      <tr>
        <th>${escapeHtml(t('ps.item') || 'Item')}</th>
        <th>${escapeHtml(t('ps.material') || 'Material')}</th>
        <th>${escapeHtml(t('ps.color') || 'Color')}</th>
        <th style="text-align:right;">${escapeHtml(t('ps.qty') || 'Qty')}</th>
        <th style="text-align:right;">${escapeHtml(t('ps.weight') || 'Weight')}</th>
      </tr>
    </thead>
    <tbody>
      ${rowsHtml || `<tr><td colspan="5" style="color:#888;text-align:center;">${escapeHtml(order.project || order.id)}</td></tr>`}
    </tbody>
    <tfoot>
      <tr>
        <td colspan="3" style="text-align:right;font-weight:600;">${escapeHtml(t('ps.total') || 'Total')}</td>
        <td style="text-align:right;">${totalQty}</td>
        <td style="text-align:right;">${totalWeight > 0 ? Math.round(totalWeight) + 'g' : '—'}</td>
      </tr>
    </tfoot>
  </table>

  ${order.notes ? `<div class="notes"><strong>${escapeHtml(t('common.notes') || 'Notes')}:</strong> ${escapeHtml(order.notes)}</div>` : ''}

  <div class="footer">
    ${escapeHtml(t('ps.thank_you') || 'Thank you for your business!')}
    ${shopName ? ` · ${escapeHtml(shopName)}` : ''}
  </div>
</body>
</html>`;

  const win = window.open('', '_blank', 'width=900,height=700,toolbar=0,menubar=0,scrollbars=1');
  if (win) {
    win.document.open();
    win.document.write(sanitizePrintHtml(html));
    win.document.close();
    win.focus();
    setTimeout(() => win.print(), 250);
  } else {
    if (window.hubAPI?.saveHtml) {
      const saved = await window.hubAPI.saveHtml(html, `packing-slip-${order.id}.html`);
      if (saved?.path) window.hubAPI?.openPath?.(saved.path);
    }
    toast(t('ps.title') || 'Packing Slip', 'success');
  }
}

/* ============================================================
   Analytics Export Report
   ============================================================ */

function openPartialDeliveryModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order || !order.parts || order.parts.length === 0) return;
  const delivered = order.parts.filter(p => p.delivered).length;
  const total = order.parts.length;

  const bodyHtml = `
    <div style="margin-bottom:12px; font-size:13px; color:var(--primary); font-weight:600;">
      ${escapeHtml(t('ord.parts_delivered', { done: delivered, total }))}
    </div>
    <div id="partialDeliveryList">
      ${order.parts.map((p, i) => `
        <label style="display:flex; align-items:center; gap:10px; padding:8px 0; border-bottom:1px solid var(--border-soft); cursor:pointer;">
          <input type="checkbox" class="pd-part-cb" data-pi="${i}" style="width:auto; margin:0;" ${p.delivered ? 'checked' : ''}>
          <span style="flex:1;">
            <strong>${escapeHtml(p.name || 'Part ' + (i + 1))}</strong>
            ${p.material ? `<span style="font-size:11px; color:var(--text-muted); margin-inline-start:6px;">${escapeHtml(p.material)}</span>` : ''}
          </span>
          ${p.delivered ? `<span style="font-size:10px; color:var(--success);">✓ delivered</span>` : ''}
        </label>`).join('')}
    </div>`;

  openFormModal({
    title: `📦 ${t('ord.partial_delivery')} — ${escapeHtml(order.project || order.id)}`,
    saveLabel: t('ord.mark_delivered_parts'),
    sizeLg: false,
    bodyHtml,
    onSave(modal) {
      const checkboxes = modal.querySelectorAll('.pd-part-cb');
      checkboxes.forEach(cb => {
        const idx = parseInt(cb.dataset.pi, 10);
        if (order.parts[idx]) order.parts[idx].delivered = cb.checked;
      });
      const newDelivered = order.parts.filter(p => p.delivered).length;
      saveAll();
      renderLogs();
      renderKanban();
      toast(t('ord.parts_delivered', { done: newDelivered, total: order.parts.length }), 'success');
      return true;
    }
  });
}

function openSpoolSwitchModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const parts = order.parts || [];

  const inventoryOptions = inventory.map(item =>
    `<option value="${item.id}">${escapeHtml(item.material)} (${Math.round(item.weight)}g)</option>`
  ).join('');

  const partsHtml = parts.length > 0
    ? parts.map((p, i) => `
        <div style="padding:10px 0; border-bottom:1px solid var(--border-soft);">
          <strong>${escapeHtml(p.name || 'Part ' + (i + 1))}</strong>
          ${p.material ? `<span style="font-size:11.5px; color:var(--text-muted); margin-inline-start:6px;">${escapeHtml(p.material)}</span>` : ''}
          ${(p.additionalSpools || []).length > 0 ? `
            <div style="font-size:11.5px; color:var(--primary); margin-top:4px;">
              ${p.additionalSpools.map(s => {
                const it = inventory.find(x => x.id === s.spoolId);
                return `+ ${escapeHtml(it ? it.material : s.spoolId)}: ${s.weight}g`;
              }).join(' | ')}
            </div>` : ''}
          <div style="display:flex; gap:8px; margin-top:6px; align-items:center;">
            <select class="ss-spool-sel" data-pi="${i}" style="flex:2; font-size:12.5px;">
              <option value="">${escapeHtml(t('oe.select_spool'))}</option>
              ${inventoryOptions}
            </select>
            <input type="number" class="ss-weight-inp" data-pi="${i}" min="0" step="1" placeholder="${escapeHtml(t('common.grams'))}" style="width:80px; font-size:12.5px;">
            <button class="btn small primary ss-add-btn" data-pi="${i}">${escapeHtml(t('ord.add_spool'))}</button>
          </div>
        </div>`)
    .join('')
    : `<p style="color:var(--text-muted);">${escapeHtml(t('queue.parts_count', { n: 0 }))}</p>`;

  openFormModal({
    title: `🔄 ${t('ord.spool_switch')} — ${escapeHtml(order.project || order.id)}`,
    noSave: true,
    bodyHtml: `<div id="spoolSwitchBody">${partsHtml}</div>`,
    onMount(modal) {
      modal.querySelectorAll('.ss-add-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          const idx = parseInt(btn.dataset.pi, 10);
          const spoolId = modal.querySelector(`.ss-spool-sel[data-pi="${idx}"]`)?.value;
          const weight = Math.max(0, parseFloat(modal.querySelector(`.ss-weight-inp[data-pi="${idx}"]`)?.value) || 0);
          if (!spoolId || weight <= 0) {
            toast(t('ord.add_spool') + ' — select spool and enter weight', 'error');
            return;
          }
          const part = order.parts[idx];
          if (!part) return;
          if (!part.additionalSpools) part.additionalSpools = [];
          part.additionalSpools.push({ spoolId, weight });
          // Deduct from inventory
          const invItem = inventory.find(i => i.id === spoolId);
          if (invItem) {
            invItem.weight = Math.max(0, invItem.weight - weight);
            if (!invItem.usageHistory) invItem.usageHistory = [];
            invItem.usageHistory.unshift({ orderId: order.id, project: order.project || '', weightUsed: weight, date: localDateStr() });
            if (invItem.usageHistory.length > 200) invItem.usageHistory.length = 200;
          }
          saveAll();
          renderInventory();
          toast(t('ord.spool_switch_saved'), 'success');
          // Reset inputs
          const selEl = modal.querySelector(`.ss-spool-sel[data-pi="${idx}"]`);
          const wgtEl = modal.querySelector(`.ss-weight-inp[data-pi="${idx}"]`);
          if (selEl) selEl.value = '';
          if (wgtEl) wgtEl.value = '';
        });
      });
    }
  });
}

/** Write an edit into the job's history. The rule is lib/order-edit.js's. */
function recordOrderEdit(order, changedFields) {
  EditRules().recordEdit(order, changedFields, { now: Date.now(), id: uid('edit') });
}

/** The order-edit rules, however this file happens to be loaded. */
function EditRules() {
  if (EditRules.cached) return EditRules.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytOrderEdit) {
    EditRules.cached = globalThis.KhaytOrderEdit;
    return EditRules.cached;
  }
  try { EditRules.cached = require('../lib/order-edit.js'); }
  catch (e) { EditRules.cached = null; }
  return EditRules.cached;
}

function openEditHistoryModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const history = order.editHistory || [];
  const bodyHtml = history.length === 0
    ? `<p style="color:var(--text-muted); text-align:center; padding:20px;">${escapeHtml(t('ord.edit_history_empty'))}</p>`
    : `<div class="table-wrap"><table style="width:100%; font-size:12.5px;">
        <thead><tr>
          <th>${escapeHtml(t('ord.edit_at'))}</th>
          <th>${escapeHtml(t('ord.edit_fields'))}</th>
        </tr></thead>
        <tbody>${[...history].reverse().map(h => {
          const d = new Date(h.at);
          const dateStr = d.toLocaleDateString(localeTag(), { day:'2-digit', month:'short', year:'numeric' }) + ' ' + d.toTimeString().slice(0,5);
          const fieldRows = Object.entries(h.fields).map(([k, v]) =>
            `<div style="margin-bottom:2px;"><strong>${escapeHtml(k)}:</strong> <span style="color:var(--danger);">${escapeHtml(String(v.from ?? ''))}</span> → <span style="color:var(--success);">${escapeHtml(String(v.to ?? ''))}</span></div>`
          ).join('');
          return `<tr>
            <td style="white-space:nowrap; color:var(--text-dim); vertical-align:top;">${escapeHtml(dateStr)}</td>
            <td>${fieldRows}</td>
          </tr>`;
        }).join('')}
        </tbody>
      </table></div>`;
  openFormModal({
    title: `${t('ord.edit_history')} — ${escapeHtml(orderId)}`,
    noSave: true,
    sizeLg: true,
    bodyHtml,
  });
}

async function splitOrderAcrossMachines(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order || !order.parts || order.parts.length < 2) return;

  const machineOptions = `<option value="">${escapeHtml(t('mach.unassigned'))}</option>` +
    machines.map(m => `<option value="${m.id}">${escapeHtml(m.name)}</option>`).join('');

  const partsHtml = order.parts.map((p, i) => `
    <div style="display:grid; grid-template-columns:1fr auto; gap:8px; align-items:center; padding:6px 0; border-bottom:1px solid var(--border-soft);">
      <div style="font-size:13px;">
        <strong>${escapeHtml(p.name || 'Part ' + (i + 1))}</strong>
        <span style="color:var(--text-muted); font-size:11.5px; margin-inline-start:6px;">${p.printTime || 0}h · ${p.printWeight || 0}g</span>
      </div>
      <select class="split-mach-sel" data-pi="${i}" style="font-size:12px; min-width:140px;">
        ${machineOptions}
      </select>
    </div>`).join('');

  const assignments = {}; // { partIndex: machineId }

  const confirmed = await new Promise(resolve => {
    openFormModal({
      title: t('ord.split_assign'),
      saveLabel: t('common.confirm'),
      bodyHtml: `
        <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('ord.split_confirm', { n: order.parts.length }))}</p>
        ${partsHtml}`,
      onMount(modal) {
        modal.querySelectorAll('.split-mach-sel').forEach(sel => {
          sel.addEventListener('change', () => {
            assignments[+sel.dataset.pi] = sel.value;
          });
        });
      },
      async onSave(modal) {
        modal.querySelectorAll('.split-mach-sel').forEach(sel => {
          assignments[+sel.dataset.pi] = sel.value;
        });
        resolve(true);
        return true;
      }
    });
    const obs = new MutationObserver(() => {
      if (!document.querySelector('#modalMount .modal')) { obs.disconnect(); resolve(false); }
    });
    obs.observe($('#modalMount'), { childList: true });
  });
  if (!confirmed) return;

  // Group parts by machine
  const machineGroups = {};
  for (let i = 0; i < order.parts.length; i++) {
    const mid = assignments[i] || '';
    if (!machineGroups[mid]) machineGroups[mid] = [];
    machineGroups[mid].push(i);
  }

  // Money already taken has to travel with the price it was taken against.
  // Every sub-order was created `paidAmount: 0, paymentStatus: 'unpaid'`, so a
  // job with a deposit on it came out the other side owing its FULL value again
  // and the customer was invoiced for money they had already paid. The parent
  // kept the record, but a superseded parent is excluded from what is owed —
  // correctly, since its children carry the debt — so the deposit was simply
  // gone. lib/split-order.js divides price, deposit and credit notes together,
  // giving the last group every remainder so the shares add back up exactly.
  const groupEntries = Object.entries(machineGroups);
  const shares = KhaytSplitOrder.splitMoney({
    price: +order.price || 0,
    paid: +order.paidAmount || 0,
    credited: (order.creditNotes || []).reduce((s, cn) => s + (+cn.amount || 0), 0),
    costs: groupEntries.map(([, idxs]) => idxs.reduce((s, i) => s + (+order.parts[i].baseCost || 0), 0)),
  });
  const subOrderIds = [];
  for (let gi = 0; gi < groupEntries.length; gi++) {
    const [mid, partIndices] = groupEntries[gi];
    const parts = partIndices.map(i => ({ ...order.parts[i] }));
    const { price: subPrice, paidAmount: subPaid, credited: subCredit } = shares[gi];
    const subId = uid('SUB');
    const subInvoiceNum = nextInvoiceNumber();
    const subOrder = {
      id: subId,
      parentOrderId: order.id,
      project: `${order.project} — Parts ${partIndices.map(i => i + 1).join(',')}`,
      clientId: order.clientId,
      machineId: mid || null,
      parts,
      printTime: parts.reduce((s, p) => s + (+p.printTime || 0), 0),
      material: order.material || '',
      date: order.date || localDateStr(),
      status: 'pending',
      price: subPrice,
      paidAmount: subPaid,
      paymentStatus: KhaytSplitOrder.paymentStatusFor(subPrice, subPaid),
      creditNotes: subCredit > 0
        ? [{ id: uid('CN'), amount: subCredit, at: new Date().toISOString(), reason: `Carried from ${order.id}` }]
        : [],
      materialDeducted: false,
      statusHistory: [{ status: 'pending', at: new Date().toISOString() }],
      invoiceNum: subInvoiceNum,
      invoiceNumber: subInvoiceNum,
    };
    printLog.push(subOrder);
    subOrderIds.push(subId);
  }

  order.status = 'split';
  order.splitInto = subOrderIds;
  saveAll();
  renderKanban();
  renderLogs();
  toast(t('ord.split_done', { n: subOrderIds.length }), 'success');
}

function openChangeOrderModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  openFormModal({
    title: 'Change Order — ' + escapeHtml(order.project || order.id),
    sizeLg: false,
    saveLabel: 'Save Change Order',
    bodyHtml: `
      <div style="background:var(--surface-2);border-radius:6px;padding:10px;font-size:12px;margin-bottom:12px;color:var(--text-muted);">
        <strong>Order:</strong> ${escapeHtml(order.id)}<br>
        <strong>Project:</strong> ${escapeHtml(order.project || '—')}<br>
        <strong>Current Price:</strong> ${fmtPrice(order.price)}<br>
        <strong>Current Due Date:</strong> ${escapeHtml(order.dueDate || '—')}
      </div>
      <label>What changed?</label>
      <textarea id="coDescription" rows="3" placeholder="Describe the change…"></textarea>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px;">
        <div>
          <label>New Price (optional)</label>
          <input type="number" id="coNewPrice" min="0" step="0.01" placeholder="${fmtMoney(order.price)}">
        </div>
        <div>
          <label>New Due Date (optional)</label>
          <input type="date" id="coNewDueDate" value="${escapeHtml(order.dueDate || '')}">
        </div>
      </div>`,
    onSave(modal) {
      const description = modal.querySelector('#coDescription').value.trim();
      if (!description) { toast(t('co.describe_required'), 'error'); return false; }
      const newPrice    = modal.querySelector('#coNewPrice').value;
      const newDueDate  = modal.querySelector('#coNewDueDate').value;
      const entry = {
        at: new Date().toISOString(),
        description,
        oldPrice:    +order.price || 0,
        newPrice:    newPrice ? num(newPrice, +order.price) : null,
        oldDueDate:  order.dueDate || null,
        newDueDate:  newDueDate || null,
      };
      if (!order.changeLog) order.changeLog = [];
      order.changeLog.push(entry);
      if (newPrice)   order.price   = num(newPrice, order.price);
      if (newDueDate) order.dueDate = newDueDate;
      saveAll();
      renderLogs();
      renderKanban();
      toast(t('co.saved'), 'success');
    },
  });
}

async function captureFailurePhoto(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;

  let filePath = null;
  if (window.hubAPI?.pickFile) {
    filePath = await window.hubAPI.pickFile({ filters: [{ name: 'Images', extensions: ['jpg','jpeg','png','webp'] }] })
      .catch(() => null);
  }

  if (!filePath) {
    // Fallback: hidden file input
    filePath = await new Promise(resolve => {
      const inp = document.createElement('input');
      inp.type = 'file';
      inp.accept = 'image/jpeg,image/png,image/webp';
      inp.style.display = 'none';
      document.body.appendChild(inp);
      inp.onchange = () => { const f = inp.files[0]; inp.remove(); resolve(f || null); };
      inp.oncancel = () => { inp.remove(); resolve(null); };
      inp.click();
    });
  }

  if (!filePath) return;

  // If hubAPI.copyFileToVault exists, use it; otherwise read as dataURL
  if (window.hubAPI?.copyFileToVault && typeof filePath === 'string') {
    try {
      const filename = await window.hubAPI.copyFileToVault(filePath, orderId);
      order.failurePhotoPath = filename;
      saveAll();
      toast(t('qc.photo_saved'), 'success');
      renderKanban();
    } catch(e) {
      toast(t('qc.photo_save_failed') + ': ' + e.message, 'error');
    }
    return;
  }

  // filePath is a File object (from the hidden input fallback)
  if (filePath instanceof File) {
    const reader = new FileReader();
    reader.onload = async () => {
      const dataUrl = reader.result;
      const filename = `failure-${orderId}-${Date.now()}.jpg`;
      if (window.hubAPI?.saveOrderPhoto) {
        try {
          await window.hubAPI.saveOrderPhoto(orderId, 0, dataUrl);
          order.failurePhotoPath = filename;
        } catch (e) {
          // The catch used to set the SAME field as success, so a failed save left the
          // order permanently pointing at a photo that does not exist.
          console.error('saveOrderPhoto failed:', e);
          toast('⚠ ' + (t('ord.photo_save_failed') || 'Could not save that photo'), 'error', 6000);
          return;
        }
      } else {
        order.failurePhotoPath = filename;
      }
      saveAll();
      toast(t('qc.photo_captured'), 'success');
      renderKanban();
    };
    reader.readAsDataURL(filePath);
  }
}
  const api = {
    logPrint,
    promptActuals,
    // Public because it is a real operation on an order — "tell the settings
    // this used how it went" — that any completion path should be able to call,
    // and because it writes to another module's records, which is worth being
    // able to drive end to end.
    recordSetupOutcomes,
    updateStatus,
    resumeFromHold,
    holdOrder,
    qcPassOrder,
    qcFailOrder,
    recordQcFailure,
    measuredWasteFor,
    promptScrapOrReprint,
    createLinkedReprint,
    openRmaModal,
    // QC pure helpers (unit-tested; also used by kanban/analytics at runtime)
    qcStatusOf,
    inspectorInitials,
    reprintChainRoot,
    applyReprintMeta,
    computeWithinWarranty,
    computeQcMetrics,
    resinLogWash,
    resinLogCure,
    resinCompletePost,
    deleteLog,
    markDelivered,
    openShipModal,
    applyShippingStatus,
    openAssemblyModal,
    reprintSinglePart,
    openPaymentModal,
    clearPayment,
    renderOeExtraLinesHtml,
    openOrderEditor,
    openBatchPlannerModal,
    openOrderTimeline,
    duplicateOrder,
    reprintOrder,
    generateOrderLabel,
    generatePackingSlip,
    openPartialDeliveryModal,
    openSpoolSwitchModal,
    recordOrderEdit,
    openEditHistoryModal,
    splitOrderAcrossMachines,
    openChangeOrderModal,
    captureFailurePhoto,
    paymentBadge,
  };

  Object.assign(global, api);
  global.KhaytOrderFlows = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
