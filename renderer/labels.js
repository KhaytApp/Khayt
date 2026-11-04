'use strict';
/**
 * Label printing (orders + spools). Builds a printable QR-label sheet via
 * lib/labels.js, injects it into #label-print-area, and prints. Order QRs link
 * to the customer tracking page (cloud portal) when connected; spool QRs encode
 * a scan-in code (KHAYT-SPOOL:<id>).
 */
(function (global) {
  async function qrFor(text) {
    try { return await window.hubAPI.generateQR(String(text), { dataUrl: true, width: 160 }); }
    catch { return ''; }
  }

  function orderTrackUrl(o) {
    const c = settings.cloud || {};
    if (c.enabled && c.url && o.trackingToken) return `${String(c.url).replace(/\/+$/, '')}/p/${o.trackingToken}`;
    return 'KHAYT-ORDER:' + o.id;
  }

  function printLabels(labels, heading) {
    if (!labels.length) { toast(t('lbl.none') || 'Nothing to label', 'info'); return; }
    const area = document.getElementById('label-print-area');
    if (!area || typeof KhaytLabels === 'undefined') return;
    area.innerHTML = KhaytLabels.buildLabelSheet(labels, { heading });
    const root = document.documentElement;
    root.classList.add('printing-labels');
    const cleanup = () => { root.classList.remove('printing-labels'); area.innerHTML = ''; window.removeEventListener('afterprint', cleanup); };
    window.addEventListener('afterprint', cleanup);
    setTimeout(() => window.print(), 120);
  }

  async function printOrderLabels(orderIds) {
    const ids = Array.isArray(orderIds) ? orderIds : [orderIds];
    const orders = ids.map((id) => printLog.find((o) => o.id === id)).filter(Boolean);
    const labels = [];
    for (const o of orders) {
      const client = o.clientId ? clients.find((c) => c.id === o.clientId) : null;
      labels.push({
        title: o.project || jobRef(o),
        lines: [
          client ? localName(client) : (o.client || ''),
          o.material || '',
          o.dueDate ? ((t('lbl.due') || 'due') + ' ' + o.dueDate) : '',
        ],
        sub: o.id,
        qr: await qrFor(orderTrackUrl(o)),
      });
    }
    printLabels(labels, t('lbl.orders') || 'Order labels');
  }

  async function printSpoolLabels(itemIds) {
    const items = (Array.isArray(itemIds) && itemIds.length)
      ? itemIds.map((id) => inventory.find((i) => i.id === id)).filter(Boolean)
      : (inventory || []).filter(Boolean);
    const labels = [];
    for (const i of items) {
      const grams = i.weight != null ? i.weight : i.weightRemaining;
      labels.push({
        title: i.material || i.name || '—',
        lines: [i.color || '', (grams != null && grams !== '') ? (Math.round(+grams) + ' g') : '', i.brand || ''],
        sub: i.id,
        qr: await qrFor('KHAYT-SPOOL:' + i.id),
      });
    }
    printLabels(labels, t('lbl.spools') || 'Spool labels');
  }

  const api = { printOrderLabels, printSpoolLabels };
  Object.assign(global, api);
  global.KhaytLabelsUI = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
