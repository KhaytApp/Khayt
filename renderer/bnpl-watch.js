'use strict';
/* ============================================================
   Buy-now-pay-later: finish the payments the shop sent links for.

   Tabby and Tamara both wait for the MERCHANT once the customer has paid —
   Tamara's authorise (within 72 hours, or the order expires), Tabby's capture
   (or no settlement for 21 days). Khayt has no public address for them to
   notify, so while it is open it asks: every open link on a job is checked
   with the provider (hub:bnpl-check), which takes the step that is due, and a
   paid link is recorded on its job exactly as the Record Payment dialog
   records one — the same rule, the same receipt email, webhooks and
   accounting push. Rules: lib/bnpl-confirm.js.
   ============================================================ */

const BNPL_WATCH_MS = 10 * 60 * 1000;
let _bnplChecking = false;

function bnplWatchEnabled() {
  const b = (typeof settings !== 'undefined' && settings && settings.bnpl) || {};
  return !!((b.tabby && b.tabby.enabled) || (b.tamara && b.tamara.enabled));
}

/** Check every open link once. Never two runs at a time; one failing link never stops the rest. */
async function checkBnplLinks() {
  if (_bnplChecking || typeof KhaytBnplConfirm === 'undefined' || !window.hubAPI?.bnplCheck) return;
  if (!bnplWatchEnabled()) return;
  _bnplChecking = true;
  try {
    const due = KhaytBnplConfirm.linksToCheck(typeof printLog !== 'undefined' ? printLog : []);
    for (const { orderId, link } of due) {
      let r;
      try { r = await window.hubAPI.bnplCheck({ provider: link.provider, id: link.id }); }
      catch (e) { r = { ok: false, error: String((e && e.message) || e) }; }
      // The job may have changed while we waited on the network: work on what is there now.
      const order = printLog.find((o) => o && o.id === orderId);
      const live = order && (order.bnplLinks || []).find((l) => l && l.provider === link.provider && l.id === link.id);
      if (!order || !live || live.state !== 'open') continue;
      if (!r || !r.ok) {
        // Leave it open and try again next time; say so only for a step that FAILED,
        // which is money waiting on the shop, not a quiet network blip.
        if (r && r.remoteStatus) {
          const name = link.provider === 'tamara' ? 'Tamara' : 'Tabby';
          toast(t('bnpl.confirm_failed', { service: name, project: order.project || order.id, error: r.error || '' }), 'warning', 8000);
        }
        console.warn('[bnpl] check failed', link.provider, link.id, r && r.error);
        continue;
      }
      if (r.state === 'paid') {
        KhaytBnplConfirm.settle(live, 'paid', r.remoteStatus);
        const out = PaymentRules().recordPayment(order,
          KhaytBnplConfirm.paymentFor(order, live, localDateStr()),
          { today: localDateStr(), settings });
        runPaymentEffects(order, out.effects);   // saves, renders, receipt email, webhooks, accounting
        const name = link.provider === 'tamara' ? 'Tamara' : 'Tabby';
        toast(t('bnpl.confirmed', { service: name, project: order.project || order.id }), 'success', 6000);
      } else if (r.state === 'closed') {
        KhaytBnplConfirm.settle(live, 'closed', r.remoteStatus);
        saveAll();
      } else if (live.remoteStatus !== r.remoteStatus) {
        KhaytBnplConfirm.settle(live, 'open', r.remoteStatus);
        saveAll();
      }
    }
  } finally {
    _bnplChecking = false;
  }
}

function startBnplWatch() {
  if (startBnplWatch.started) return;
  startBnplWatch.started = true;
  setTimeout(() => { checkBnplLinks(); }, 20 * 1000);   // after the window has settled
  setInterval(() => { checkBnplLinks(); }, BNPL_WATCH_MS);
}

if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', () => startBnplWatch());
}
if (typeof module !== 'undefined' && module.exports) module.exports = { checkBnplLinks, bnplWatchEnabled };
