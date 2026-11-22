'use strict';
/**
 * What the print actually used — offered to Bed Ready when a job finishes.
 *
 * The main process has been collecting this all along. lib/printer-poll-cache.js runs in
 * main.js, is not gated by flavour, and stashes a `lastCompleted` — filament and duration
 * as the printer reported them — every time a job it is polling finishes. Bed Ready has
 * been throwing those measurements away for want of anywhere to put them.
 *
 * Now that its queue can complete a job (bedready-queue.js), there is somewhere.
 *
 * Two deliberate departures from Khayt's version:
 *
 *   It only asks when there is a MEASUREMENT to offer. Khayt prompts on every completion,
 *   pre-filled from the estimate, which suits a shop recording numbers for invoices. A
 *   maker with no printer connected would just get a dialog on every job asking them to
 *   retype what the estimator already said. Nothing measured, no dialog.
 *
 *   It asks AFTER the job is completed, not as a gate on completing it. The print
 *   finished whether or not anyone fills this in; making the queue wait on a dialog would
 *   mean a dismissed prompt leaves the job stuck in the previous column.
 *
 * The thing this must not get wrong is whose numbers these are. A completion stays
 * offerable for 24 hours, and a shop running five-hour jobs back to back will have started
 * another one well inside that window — so the figures on screen can belong to the PREVIOUS
 * print while wearing a green "Measured" label. prefillActuals returns the filename it
 * measured; this shows it, every time, unmissably.
 */
(function (global) {
  const PA = () => global.KhaytPrinterActuals || null;

  /**
   * A locale string, with its placeholders filled.
   *
   * `t(key)` without params returns the raw entry — "measured on {file}" — and the filename
   * this dialog exists to show never appears. Falls back to English when the key is missing
   * OR when a placeholder survives, because a line reading "{file}" is worse than one in the
   * wrong language.
   */
  const T = (k, fb, params) => {
    try {
      const s = (typeof t === 'function') ? t(k, params) : '';
      return (s && s !== k && !/\{[a-z_]+\}/i.test(s)) ? s : fb;
    } catch (_) { return fb; }
  };
  const esc = (s) => (typeof escapeHtml === 'function') ? escapeHtml(String(s == null ? '' : s)) : String(s == null ? '' : s);
  const num = (v, fb) => { const n = parseFloat(v); return Number.isFinite(n) ? n : fb; };

  /** The estimate this job was quoted on, in the shapes prefillActuals wants. */
  function estimateOf(order) {
    const weightG = Array.isArray(order.parts)
      ? order.parts.reduce((s, p) => s + (+p.printWeight || 0) * (+p.qty || 1), 0)
      : 0;
    return { printTime: +order.printTime || 0, weightG };
  }

  /** The completion the poll cache captured for this job's machine, if any. */
  function completionFor(order) {
    if (!order || !order.machineId) return null;
    const cache = (typeof machineStatusCache === 'object' && machineStatusCache) ? machineStatusCache : null;
    return (cache && cache[order.machineId] && cache[order.machineId].lastCompleted) || null;
  }

  /**
   * Offer the measured figures for a job that has just completed.
   * @returns {boolean} whether a dialog was shown
   */
  function offerActuals(order) {
    const pa = PA();
    if (!pa || !order || typeof openFormModal !== 'function') return false;

    const est = estimateOf(order);
    const pre = pa.prefillActuals({ estimate: est, completion: completionFor(order), now: Date.now() });
    // Nothing came off a printer, so there is nothing here the maker does not already know.
    if (!pre || !pre.measured) return false;

    const initTime = pre.timeH != null ? pre.timeH : est.printTime;
    const initWeight = pre.weightG != null ? Math.round(pre.weightG * 10) / 10 : Math.round(est.weightG);
    const tag = (measured) => measured
      ? `<span style="color:var(--ok,#159d68);font-weight:600;">${esc(T('act.measured', 'Measured'))}</span>`
      : esc(T('act.est', 'Estimated'));

    openFormModal({
      title: T('act.title', 'What the print actually used'),
      saveLabel: T('act.confirm', 'Record'),
      sizeLg: false,
      bodyHtml: `
        <p style="font-size:13px;color:var(--text-dim);margin-bottom:12px;">${esc(T('act.hint',
          'Your printer reported these. Correcting one marks it as your figure, not a measurement.'))}</p>
        <p style="font-size:12px;margin:-4px 0 14px;padding:8px 10px;border-radius:var(--radius);background:var(--bg-elev);">
          ${esc(pre.filename
            ? T('act.from_printer_file',
                `These figures came from ${pre.source || 'your printer'}, measured on ${pre.filename} — what that job actually used, not the estimate.`,
                { source: pre.source || T('act.your_printer', 'your printer'), file: pre.filename })
            : T('act.from_printer',
                `These figures came from ${pre.source || 'your printer'} — what it actually used, not the estimate.`,
                { source: pre.source || T('act.your_printer', 'your printer') }))}
        </p>
        <div class="inline-pair">
          <div>
            <label>${esc(T('act.print_time', 'Print time'))} (${esc(T('common.hours', 'hours'))})</label>
            <input type="number" id="brActTime" value="${initTime}" min="0" step="0.1">
            <div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${tag(pre.timeMeasured)} · ${esc(T('act.est', 'Estimated'))}: ${esc(est.printTime)}</div>
          </div>
          <div>
            <label>${esc(T('act.weight', 'Filament'))} (${esc(T('common.grams', 'g'))})</label>
            <input type="number" id="brActWeight" value="${initWeight}" min="0" step="1">
            <div style="font-size:11px;color:var(--text-muted);margin-top:2px;">${tag(pre.weightMeasured)} · ${esc(T('act.est', 'Estimated'))}: ${esc(est.weightG.toFixed(0))}</div>
          </div>
        </div>`,
      onSave(modal) {
        const tv = num(modal.querySelector('#brActTime').value, est.printTime);
        const wv = num(modal.querySelector('#brActWeight').value, 0);
        order.actualPrintTime = +tv.toFixed(2);
        order.actualWeight = +wv.toFixed(1);
        // Which figures are measurements and which are typed. The estimator calibrates
        // itself from these, and a guess taught back to it as a measurement is worse than
        // no data — it would drift the estimator toward whatever the shop already believed.
        const same = (a, b) => Math.abs(a - b) < 0.005;
        order.actualsSource = {
          time: pre.timeMeasured && same(order.actualPrintTime, initTime) ? (pre.source || 'printer') : 'manual',
          weight: pre.weightMeasured && same(order.actualWeight, initWeight) ? (pre.source || 'printer') : 'manual',
          at: new Date().toISOString(),
        };
        if (typeof saveAll === 'function') saveAll();
        if (typeof renderKanban === 'function') { try { renderKanban(); } catch (_) {} }
        return true;
      },
    });
    return true;
  }

  global.brOfferActuals = offerActuals;
  global.KhaytBedReadyActuals = { offerActuals, estimateOf, completionFor };
})(typeof globalThis !== 'undefined' ? globalThis : window);
