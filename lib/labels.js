'use strict';
(function () {

/**
 * Label sheet builder — pure HTML for a printable grid of QR labels (orders or
 * spools). Side-effect free so it's unit-testable; the renderer resolves QR data
 * URLs (via hub:generate-qr) and the order/spool fields, then injects the result
 * into #label-print-area and calls window.print().
 *
 * Each label: { title, lines: string[], qr: dataUrl, sub?: string }.
 */

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/** Build the inner HTML for #label-print-area. `opts.heading` is optional. */
function buildLabelSheet(labels, opts = {}) {
  const list = Array.isArray(labels) ? labels.filter(Boolean) : [];
  const cards = list.map((l) => {
    const lines = (Array.isArray(l.lines) ? l.lines : []).filter((x) => x != null && String(x).trim() !== '')
      .map((x) => `<div class="lbl-line">${esc(x)}</div>`).join('');
    const qr = l.qr ? `<img class="lbl-qr" src="${esc(l.qr)}" alt="QR">` : '';
    const sub = l.sub ? `<div class="lbl-sub">${esc(l.sub)}</div>` : '';
    return `<div class="lbl-card">
      ${qr}
      <div class="lbl-body">
        <div class="lbl-title">${esc(l.title)}</div>
        ${lines}
        ${sub}
      </div>
    </div>`;
  }).join('');
  const heading = opts.heading ? `<div class="lbl-heading">${esc(opts.heading)}</div>` : '';
  return `${heading}<div class="label-grid">${cards}</div>`;
}

const api = { buildLabelSheet, esc };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLabels = api;

})();
