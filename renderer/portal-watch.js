'use strict';
/* ============================================================
   "Check response", on its own: what customers did with the portal links
   this shop published, read when the window comes to the front and every
   fifteen minutes — the Mac's Shop+PortalWatch.swift.

   WHY: a customer's approval and their deposit reached the book only when
   somebody opened the job's link sheet and pressed "Check response". A quote
   approved on Sunday sat as a quote until Tuesday.

   COST: one `hub:cloud-published-list` per look, whatever the number of jobs —
   the list carries every link's answer and payment, and each job is matched in
   it (`KhaytPortalOwner.responseFor`). Coming to the front looks at most once a
   minute; nothing is asked when no published job is waiting on anything, or
   when Khayt Cloud is not connected; a "too many requests" answer holds the
   watcher off for an hour. Two looks never overlap.

   WHAT IT DOES WITH THE ANSWER: exactly what the button does
   (`applyPortalResponse` in integrations.js) — a payment is recorded once
   (`recordPortalPayment` keys it on the provider's reference), and an approval
   moves a quote to Pending through `updateStatus`, only when the person at
   this computer may edit jobs.
   ============================================================ */

const PORTAL_WATCH_EVERY_MS = 15 * 60 * 1000;
const PORTAL_WATCH_MIN_GAP_MS = 60 * 1000;
const PORTAL_WATCH_BACKOFF_MS = 60 * 60 * 1000;

let _portalWatchBusy = false;
let _portalWatchedAt = 0;
let _portalWatchNotBefore = 0;

/**
 * The published jobs worth asking about: a quote (waiting on an answer), or a
 * job that asked for a deposit the portal has not yet paid onto it. A void, or
 * a page coming down, is not asked about. Same rule as the Mac's
 * `portalJobsToWatch`.
 */
function portalJobsToWatch(jobs) {
  const out = [];
  for (const o of Array.isArray(jobs) ? jobs : []) {
    if (!o || o.cloudPublished !== true || o.portalTakedownPending === true) continue;
    if (o.voidedAt != null) continue;
    if (!o.id || typeof o.trackingToken !== 'string' || !o.trackingToken) continue;
    const depositAsked = typeof o.cloudDeposit === 'number' && o.cloudDeposit > 0;
    const depositIn = Array.isArray(o.portalPayments) && o.portalPayments.length > 0;
    if (o.status === 'quote' || (depositAsked && !depositIn)) out.push({ id: o.id, token: o.trackingToken });
  }
  return out;
}

function portalWatchConfigured() {
  const c = (typeof settings !== 'undefined' && settings && settings.cloud) || {};
  return !!(c.enabled && c.shopId);
}

/** One look at the portal for every job waiting on it. `opts.force` skips the minute gap. */
async function checkPortalNow(opts) {
  const o = opts || {};
  const now = typeof o.now === 'number' ? o.now : Date.now();
  if (_portalWatchBusy || typeof KhaytPortalOwner === 'undefined') return;
  if (!window.hubAPI || !window.hubAPI.cloudPublishedList || !portalWatchConfigured()) return;
  if (now < _portalWatchNotBefore) return;
  if (!o.force && _portalWatchedAt && now - _portalWatchedAt < PORTAL_WATCH_MIN_GAP_MS) return;
  const waiting = portalJobsToWatch(typeof printLog !== 'undefined' ? printLog : []);
  if (!waiting.length) return;
  _portalWatchBusy = true;
  _portalWatchedAt = now;
  try {
    const c = settings.cloud || {};
    let lst;
    try { lst = await window.hubAPI.cloudPublishedList({ url: c.url, shopId: c.shopId, token: c.token }); }
    catch (e) { lst = { ok: false, error: String((e && e.message) || e) }; }
    if (!lst || !lst.ok) {
      // Quietly: the next look tries again, and the sheet's button says why.
      if (/429|too many|rate/i.test(String((lst && lst.error) || ''))) _portalWatchNotBefore = now + PORTAL_WATCH_BACKOFF_MS;
      return;
    }
    const mayMove = typeof operatorCan !== 'function' || operatorCan('orders', 'edit');
    for (const job of waiting) {
      // The job may have changed while we waited on the network: work on what is there now.
      const order = printLog.find((x) => x && x.id === job.id);
      if (!order || order.trackingToken !== job.token) continue;
      applyPortalResponse(order, lst.items, job.token, { quiet: true, mayMove });
    }
  } finally {
    _portalWatchBusy = false;
  }
}

function startPortalWatch() {
  if (startPortalWatch.started) return;
  startPortalWatch.started = true;
  // Not in the first seconds of a launch, which has enough to read.
  setTimeout(() => { checkPortalNow(); }, 20 * 1000);
  setInterval(() => { checkPortalNow({ force: true }); }, PORTAL_WATCH_EVERY_MS);
  window.addEventListener('focus', () => { checkPortalNow(); });
}

if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', () => startPortalWatch());
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { portalJobsToWatch, checkPortalNow, portalWatchConfigured, PORTAL_WATCH_EVERY_MS };
}
