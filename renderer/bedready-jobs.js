'use strict';
/**
 * Bed Ready's own job creation — "Add to print queue".
 *
 * The calculator's primary button is wired in wire-events.js to `logPrint()`, which lives
 * in order-flows.js. That module is business-only and Bed Ready does not ship it, so
 * bedready-shim.js declared `logPrint` a no-op to stop the boot-time ReferenceError.
 *
 * Which left the one button the whole app funnels into doing nothing at all. It renders,
 * it is the green primary action, it says "Add to print queue", the click lands, and
 * `function () { return ''; }` returns. No job appears, nothing errors, nothing says why.
 * `printLog.unshift` in order-flows.js is the ONLY renderer path that ever creates an
 * order, so a Bed Ready install could not put a single job into its production queue —
 * which makes the queue, the machine strip, the actuals prompt and the dashboard's
 * "prints done" all features of a screen that could never have anything on it.
 *
 * So Bed Ready gets a real one. This is not order-flows.js with the commerce stripped
 * out — it is the record a workshop needs, built from what Bed Ready actually collects:
 *
 *   parts          currentBuild (build.js) — the calculator's cart, carried over whole so
 *                  cost, weight and time survive into the queue card and into inventory
 *   machine        #machineAssign, so the machine strip and WIP limits have something to
 *                  work with from the moment the job exists
 *   due date       queue depth ÷ avgDailyWorkingHours (app-helpers.js) — the same estimate
 *                  the shared queue already renders a badge from
 *   activity log   logActivity (app-helpers.js)
 *
 * Deliberately absent, because they are business or depend on it: invoice/quote numbering,
 * clients, deposits and payment status, discounts and rush fees, shipping and tracking
 * tokens, quote approval tokens, webhooks, and the `asQuote` half of the signature — Bed
 * Ready has no quotes, and `#btnSaveAsQuote` (the only caller that passes `true`) is
 * `biz-only` and never visible here.
 *
 * Field names match order-flows.js exactly where they are kept. That is the point: every
 * shared consumer downstream (kanban.js, queue-list.js, queue-groups.js, inventory
 * deduction, bedready-actuals.js) already reads these names, so a Bed Ready job is not a
 * second shape of order that each of them would have to learn.
 *
 * Loaded AFTER bedready-shim.js and only by bedready.html, so it replaces the shim's
 * no-op. The shim assigns only when a name is undefined; this assigns unconditionally,
 * on purpose.
 */
(function (global) {
  const T = (k, fb) => {
    try { const s = (typeof t === 'function') ? t(k) : ''; return (s && s !== k && !/\{\w+\}/.test(s)) ? s : fb; } catch (_) { return fb; }
  };
  const say = (msg, kind, ms) => { try { if (typeof toast === 'function') toast(msg, kind, ms); } catch (_) {} };
  const orders = () => (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
  const conf = () => (typeof settings !== 'undefined' && settings) ? settings : {};
  const val = (sel) => { try { const e = document.querySelector(sel); return e ? e.value : ''; } catch (_) { return ''; } };
  const n = (v, d) => (typeof num === 'function' ? num(v, d) : (parseFloat(v) || d));

  /**
   * A job id a maker can read off a card and say out loud.
   *
   * order-flows.js keys off the invoice counter; Bed Ready has no invoices, and
   * `nextInvoiceNumber` is one of the shim's no-ops (it returns ''), so borrowing it
   * would give every job the same empty sequence. This keeps its own counter on
   * settings, and falls back to a uid if the counter is somehow unavailable — an id
   * collision would silently merge two jobs, since id is the primary key.
   */
  function nextJobId(now) {
    const cfg = conf();
    const year = now.getFullYear();
    if (cfg.brJobYear !== year) { cfg.brJobYear = year; cfg.brJobNext = 1; }
    const seq = Math.max(1, parseInt(cfg.brJobNext, 10) || 1);
    const id = `JOB-${year}-${String(seq).padStart(4, '0')}`;
    // Never hand back an id that already exists — a restored backup or an edited store
    // can leave the counter behind the log.
    if (orders().some((o) => o && o.id === id)) {
      return (typeof uid === 'function') ? uid('JOB') : `JOB-${year}-${Date.now().toString(36)}`;
    }
    cfg.brJobNext = seq + 1;
    return id;
  }

  /**
   * Estimated finish, from how much work is already queued plus this job.
   * Returns null when the shop has not told us its working hours — better no date
   * than a made-up one on the card.
   */
  function estimateDueDate(now, addedHours) {
    try {
      const queueHrs = orders()
        .filter((o) => o && o.status !== 'completed' && o.status !== 'delivered' && o.status !== 'on_hold')
        .reduce((s, o) => s + (+o.printTime || 0), 0);
      const totalHrs = queueHrs + addedHours;
      const dailyHrs = (typeof avgDailyWorkingHours === 'function') ? avgDailyWorkingHours() : 0;
      if (!(dailyHrs > 0) || !(totalHrs > 0)) return null;
      const d = new Date(now);
      d.setDate(d.getDate() + Math.ceil(totalHrs / dailyHrs));
      return (typeof localDateStr === 'function') ? localDateStr(d) : null;
    } catch (_) { return null; }
  }

  /** Clear the calculator back to an empty cart once the job is on the queue. */
  function resetBuild() {
    currentBuild = [];
    currentBuildFromProductId = null;
    currentExtraLines = [];
    if (typeof currentComponents !== 'undefined') currentComponents = [];
    if (typeof currentAssemblyQty !== 'undefined') currentAssemblyQty = 1;
    try { localStorage.removeItem('hub_current_build_v1'); } catch (_) {}
    if (typeof renderBuild === 'function') { try { renderBuild(); } catch (_) {} }
    if (typeof renderExtraLines === 'function') { try { renderExtraLines(); } catch (_) {} }
    const clear = (sel, v) => { try { const e = document.querySelector(sel); if (e) e.value = v; } catch (_) {} };
    clear('#clientInput', '');
    clear('#discountPct', '0');
    const strip = document.querySelector('#priceTiersStrip');
    if (strip) strip.style.display = 'none';
  }

  /**
   * Put the calculator's cart on the production queue as one job.
   *
   * Signature matches order-flows.js (`asQuote`) so the shared wiring can call it
   * unchanged, but Bed Ready has no quotes: a quote request is treated as a plain job
   * rather than silently creating a record no screen here can show.
   */
  function logPrint() {
    // An empty cart means the maker filled the part fields and pressed the button without
    // pressing "Add part" — do what they meant, exactly as order-flows.js does.
    if (typeof currentBuild === 'undefined' || !Array.isArray(currentBuild)) return;
    const pending = (typeof formHasPendingPart === 'function') && formHasPendingPart();
    if (currentBuild.length === 0 || pending) {
      const before = currentBuild.length;
      if (typeof addPart === 'function') { try { addPart(); } catch (_) {} }
      if (currentBuild.length === before) return; // addPart already explained why
    }

    const now = new Date();
    const totalPrintTime = currentBuild.reduce((s, p) => s + (+p.printTime || 0), 0);
    const totalBaseCost = currentBuild.reduce((s, p) => s + (+p.baseCost || 0), 0);
    const margin = Math.max(0, n(val('#margin'), 0));
    const materials = [...new Set(currentBuild.map((p) => p.material).filter(Boolean))].join(', ');
    const project = String(val('#clientInput') || '').trim()
      || currentBuild[0].name
      || T('queue.untitled_job', 'Untitled job');

    const id = nextJobId(now);
    const nowIso = now.toISOString();

    orders().unshift({
      id,
      date: (typeof localDateStr === 'function') ? localDateStr(now) : nowIso.slice(0, 10),
      timestamp: nowIso,
      project,
      material: materials,
      printTime: +totalPrintTime.toFixed(1),
      // Cost, not a sale price: Bed Ready's calculator prices a print for the person
      // making it. Kept under the same key the shared queue and dashboard already read.
      price: +(totalBaseCost * (1 + margin / 100)).toFixed(2),
      currency: val('#calcCurrency') || undefined,
      status: 'pending',
      statusHistory: [{ status: 'pending', at: nowIso }],
      queuePos: orders().filter((o) => o && o.status === 'pending').length + 1,
      machineId: val('#machineAssign') || null,
      dueDate: estimateDueDate(now, totalPrintTime),
      priority: false,
      notes: '',
      internalNotes: '',
      tags: [],
      attachedFiles: [],
      printPhotos: [],
      materialDeducted: false,
      // Filled in when the job completes — bedready-actuals.js writes these.
      actualPrintTime: null,
      actualWeight: null,
      parts: currentBuild.map((p) => ({ ...p, partStatus: p.partStatus || 'pending' })),
    });

    if (typeof logActivity === 'function') {
      try { logActivity('order_created', `${id}${project ? ' · ' + project : ''}`, id); } catch (_) {}
    }
    if (typeof saveAll === 'function') saveAll();

    resetBuild();

    if (typeof renderKanban === 'function') { try { renderKanban(); } catch (_) {} }
    if (typeof renderQueueList === 'function') { try { renderQueueList(); } catch (_) {} }
    if (typeof renderDashboard === 'function') { try { renderDashboard(); } catch (_) {} }

    say(T('calc.quote.saved', 'Added to the print queue'), 'success');
  }

  // Unconditional: bedready-shim.js has already put a no-op here, and this replaces it.
  global.logPrint = logPrint;
  global.KhaytBedReadyJobs = { logPrint, nextJobId, estimateDueDate };
})(typeof globalThis !== 'undefined' ? globalThis : window);
