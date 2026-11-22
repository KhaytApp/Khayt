'use strict';
(function (global) {

/**
 * Reporting a Saudi tax invoice to ZATCA, Phase 2.
 *
 * Wrapped like `lib/zatca-qr.js` beside it, and for the same reason that file
 * gives: these rules lived in `renderer/invoicing.js`, so the only thing that
 * could decide whether an invoice had been accepted was the Electron window.
 * The module existed and had a test suite; `renderer/invoicing.js` kept its own
 * copy of four of these functions and it was the copy that ran. They agreed —
 * checked line by line before this was written — but that was luck holding,
 * not a guarantee, and the tests were on the half nobody executed.
 *
 * What these decide is not cosmetic. `nextZatcaIcv` numbers an invoice in a
 * sequence a tax authority requires to be unbroken, and `zatcaSubmitAccepted`
 * decides whether a document handed to a customer counts as reported.
 */

/**
 * Base64-encode UTF-8 XML for the ZATCA API payload.
 *
 * `Buffer` in the main process, `btoa` in a window — and neither exists in the
 * other. The caller may pass its own encoder; the fallbacks cover both hosts so
 * that most callers do not have to care. `zatca-qr.js` solves the same split by
 * taking `base64` as an option, and this keeps that shape.
 */
function xmlToBase64(xml, opts) {
  const text = String(xml || '');
  if (opts && typeof opts.base64 === 'function') return opts.base64(text);
  if (typeof Buffer !== 'undefined') return Buffer.from(text, 'utf8').toString('base64');
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary);
}

/** Whether Phase 2 submission prerequisites are met. */
function zatcaPhase2Ready(settings) {
  const z2 = settings?.zatcaPhase2;
  return !!(settings?.enableZatca && z2?.enabled && (z2.pcsid || z2.csid));
}

/** Next invoice counter value for a new submission (reuse pending ICV on retry). */
function nextZatcaIcv(z2, order) {
  if (order?.zatcaSubmission?.icv) return order.zatcaSubmission.icv;
  return (z2?.invoiceCounter || 0) + 1;
}

/** True when order is eligible for ZATCA reporting. */
function orderEligibleForZatcaSubmit(order) {
  if (!order || order.voidedAt) return false;
  return order.status === 'completed' || order.status === 'delivered';
}

/** Interpret Fatoorah HTTP response as accepted/rejected. */
function zatcaSubmitAccepted(httpOk, body) {
  if (!httpOk) return false;
  const status = body?.validationResults?.status || body?.reportingStatus || body?.clearanceStatus;
  if (status && String(status).toUpperCase() === 'REJECTED') return false;
  return true;
}

/** Build submission log entry (trimmed for store). */
function buildZatcaLogEntry({ order, payload, result, manual, status, message }) {
  return {
    orderId: order.id,
    invoiceNumber: payload.invoiceNumber,
    uuid: payload.uuid,
    icv: payload.invoiceCounter,
    at: new Date().toISOString(),
    status,
    httpStatus: result?.status ?? null,
    message: message || '',
    manual: !!manual,
  };
}

function appendZatcaSubmissionLog(z2, entry) {
  const log = Array.isArray(z2.submissions) ? [...z2.submissions] : [];
  log.unshift(entry);
  z2.submissions = log.slice(0, 100);
}

const api = {
  xmlToBase64,
  zatcaPhase2Ready,
  nextZatcaIcv,
  orderEligibleForZatcaSubmit,
  zatcaSubmitAccepted,
  buildZatcaLogEntry,
  appendZatcaSubmissionLog,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytZatcaSubmit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
