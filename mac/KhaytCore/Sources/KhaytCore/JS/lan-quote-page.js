'use strict';

/**
 * The customer's quote page and the approval rule. Read by the Node LAN
 * server AND by the native Mac app's JavaScriptCore runtime, which has no
 * `require` and no Node crypto — so a token is minted from the platform's
 * getRandomValues (Node and the browser both have it) and verified with a
 * byte loop that reads every byte whatever the first mismatch, the shape
 * renderer/util.js already uses. Wrapped so nothing lands in the shared
 * global scope.
 */
(function (global) {

/** 2·n hex characters from n random bytes. */
function randomHex(bytes) {
  const buf = new Uint8Array(bytes);
  global.crypto.getRandomValues(buf);
  return Array.from(buf, (b) => b.toString(16).padStart(2, '0')).join('');
}

/** Constant-time over the UTF-8 bytes; a length difference is folded in, not returned early. */
function constantTimeEqual(a, b) {
  const x = new TextEncoder().encode(String(a));
  const y = new TextEncoder().encode(String(b));
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] || 0) ^ (y[i] || 0);
  return diff === 0;
}

/** Escape text for LAN HTML responses. */
function lanEscapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

const LAN_QUOTE_STYLES = `
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh;padding:24px 16px}
.container{max-width:520px;margin:0 auto}
.header{text-align:center;margin-bottom:24px}
.header h1{font-size:1.5rem;font-weight:700;color:#f1f5f9;margin-bottom:4px}
.header p{color:#94a3b8;font-size:.9rem}
.card{background:#1e293b;border-radius:16px;padding:24px;margin-bottom:16px}
.meta{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px}
.meta label{font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;color:#64748b;display:block;margin-bottom:2px}
.meta span{font-size:.9rem;color:#e2e8f0}
table{width:100%;border-collapse:collapse;font-size:.85rem;margin:12px 0}
th{text-align:left;color:#64748b;font-size:.72rem;text-transform:uppercase;padding:8px 6px;border-bottom:1px solid #334155}
td{padding:8px 6px;border-bottom:1px solid #0f172a}
.total-row td{font-weight:700;color:#f1f5f9}
.btn{display:block;width:100%;padding:14px;border:none;border-radius:10px;font-size:1rem;font-weight:600;cursor:pointer;margin-top:8px}
.btn-primary{background:#6366f1;color:#fff}
.btn-primary:disabled{opacity:.5;cursor:not-allowed}
.note{font-size:.85rem;color:#94a3b8;line-height:1.5;text-align:center}
.ok{color:#4ade80;font-size:1.1rem;font-weight:600;text-align:center}
`;

/**
 * Render mobile-friendly quote approval page.
 * @param {{ order: object, shopName: string, approvePath: string, alreadyApproved?: boolean, expired?: boolean }} opts
 */
/** Ensure per-order secret required to approve quotes over LAN (prevents IDOR by order id alone). */
function ensureQuoteApprovalToken(order) {
  if (!order) return '';
  if (!order.quoteApprovalToken) {
    order.quoteApprovalToken = randomHex(16);
  }
  return order.quoteApprovalToken;
}

function ensureTrackingToken(order) {
  if (!order) return '';
  if (!order.trackingToken) {
    order.trackingToken = randomHex(16);
  }
  return order.trackingToken;
}

function verifyQuoteApprovalToken(order, provided) {
  return verifyOrderAccessToken(order, provided, 'quoteApprovalToken');
}

function verifyOrderAccessToken(order, provided, field = 'quoteApprovalToken') {
  const expected = order?.[field];
  const token = String(provided || '').trim();
  if (!expected || !token) return false;
  try {
    return constantTimeEqual(token, expected);
  } catch {
    return false;
  }
}

function renderLanQuoteApprovalPage({
  order,
  shopName,
  approvePath,
  approvalToken = '',
  alreadyApproved = false,
  expired = false,
  // No default. A quote page is where a customer agrees to pay, so a WRONG unit
  // costs more than a missing one: 'SAR' on a shop whose prices are in USD
  // understates the total by roughly 3.75x, and the customer has no way to know.
  // Shows the number bare when the shop's currency is not known.
  currencyLabel = '',
}) {
  const project = lanEscapeHtml(order.project || order.id);
  const id = lanEscapeHtml(order.id);
  const price = lanEscapeHtml(String(+order.price || 0));
  const parts = order.parts || [];
  const partsRows = parts.length
    ? parts.map((p, i) => `<tr><td>${i + 1}. ${lanEscapeHtml(p.name || p.material || 'Part')}</td><td style="text-align:right;">${lanEscapeHtml(String(p.qty || 1))}</td></tr>`).join('')
    : `<tr><td colspan="2">${project}</td></tr>`;

  let actionBlock = '';
  if (alreadyApproved) {
    actionBlock = `<p class="ok">✅ Quote approved — we'll start production soon.</p>`;
  } else if (expired) {
    actionBlock = `<p class="note" style="color:#f87171;">This quote has expired. Please contact ${lanEscapeHtml(shopName)} for an updated quote.</p>`;
  } else {
    actionBlock = `
      <p class="note" style="margin-bottom:12px;">Review the quote below and tap approve to confirm your order.</p>
      <button class="btn btn-primary" id="approveBtn">✅ Approve Quote</button>
      <p class="note" style="margin-top:12px;font-size:.75rem;">By approving you agree to proceed with this order at the quoted price.</p>
      <script>
        document.getElementById('approveBtn').addEventListener('click', async function() {
          const btn = this;
          btn.disabled = true;
          btn.textContent = 'Submitting…';
          try {
            const r = await fetch(${JSON.stringify(approvePath)}, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'approve', approvalToken: ${JSON.stringify(approvalToken)} }) });
            if (r.ok) { location.reload(); return; }
            btn.disabled = false;
            btn.textContent = '✅ Approve Quote';
            alert('Could not approve — please try again or contact the shop.');
          } catch (e) {
            btn.disabled = false;
            btn.textContent = '✅ Approve Quote';
            alert('Network error — check your Wi-Fi connection.');
          }
        });
      </script>`;
  }

  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote ${id} — ${lanEscapeHtml(shopName)}</title><style>${LAN_QUOTE_STYLES}</style></head><body>
<div class="container">
  <div class="header"><h1>${lanEscapeHtml(shopName)}</h1><p>Quote approval · ${id}</p></div>
  <div class="card">
    <div class="meta">
      <div><label>Project</label><span>${project}</span></div>
      <div><label>Quote #</label><span>${id}</span></div>
      ${order.date ? `<div><label>Date</label><span>${lanEscapeHtml(order.date)}</span></div>` : ''}
      ${order.quoteExpiresAt ? `<div><label>Expires</label><span>${lanEscapeHtml(order.quoteExpiresAt)}</span></div>` : ''}
    </div>
    <table><thead><tr><th>Description</th><th style="text-align:right;">Qty</th></tr></thead><tbody>${partsRows}</tbody>
    <tfoot><tr class="total-row"><td>Total</td><td style="text-align:right;">${price}${currencyLabel ? ' ' + lanEscapeHtml(currencyLabel) : ''}</td></tr></tfoot></table>
    ${actionBlock}
  </div>
</div></body></html>`;
}

/** Apply quote approval to a store snapshot; returns updated order or null. */
function applyQuoteApprovalToStore(storeData, orderId, nowIso) {
  const idx = (storeData.printLog || []).findIndex(o => o.id === orderId);
  if (idx === -1) return null;
  const order = storeData.printLog[idx];
  if (isQuoteExpired(order, nowIso ? localDayOf(new Date(nowIso)) : undefined)) return { error: 'expired', order };
  const canApprove = order.status === 'quote' || (order.status === 'on_hold' && order.hasQuote);
  if (!canApprove) return { error: 'cannot_approve', order };
  const now = nowIso || new Date().toISOString();
  storeData.printLog[idx] = {
    ...order,
    status: 'pending',
    clientApprovedAt: now,
    quoteAcceptedAt: now.split('T')[0],
  };
  return { order: storeData.printLog[idx] };
}

/** `YYYY-MM-DD` in the local calendar — see isQuoteExpired for why not UTC. */
function localDayOf(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function isQuoteExpired(order, today) {
  if (!order?.quoteExpiresAt) return false;
  // `today` may be handed in (a host with its own clock, a test); otherwise:
  // The shop's calendar day, not UTC's. quoteExpiresAt is a local day written by
  // the desktop, so comparing it against a UTC day was wrong for part of every
  // day: in Riyadh (UTC+3) from local midnight to 03:00 the UTC day is still
  // YESTERDAY, so a quote that expired yesterday stayed approvable — the
  // customer could still accept it. In New York (UTC-4) the error runs the other
  // way after 20:00, marking a quote expired four hours early.
  //
  // renderer/util.js standardised on this local-calendar form and a guard bans
  // the UTC one there; lib was never covered, so this survived.
  const day = today || localDayOf(new Date());
  return order.quoteExpiresAt < day;
}

/**
 * The small pages around the quote — not found, a bad link, expired, cannot
 * approve, approved — as the Node routes wrote them inline, verbatim, so the
 * Mac serves the same bytes. `opts.project` for `approved` is ALREADY ESCAPED
 * by the caller, as the route had it.
 */
function notice(kind, opts) {
  const o = opts || {};
  const projectName = o.project == null ? '' : String(o.project);
  switch (kind) {
    case 'quote_not_found': return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Not Found</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Quote not found</h2></body></html>`;
    case 'invalid_link': return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p style="color:#94a3b8;margin-top:8px;">Open the quote from the link your shop sent you.</p></body></html>`;
    case 'order_not_found': return `<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Order not found</h2></body></html>`;
    case 'invalid_link_approve': return `<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p>Open the quote page from the link your shop sent you, then approve from there.</p></body></html>`;
    case 'expired': return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Expired</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Quote expired</h2><p>This quote is no longer valid. Please contact the shop for an updated quote.</p></body></html>`;
    case 'cannot_approve': return `<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Cannot approve</h2><p>This quote is no longer awaiting approval.</p></body></html>`;
    case 'approved': return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Approved</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#6366f1}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Quote Approved!</h2><p>Your approval for <strong>${projectName}</strong> has been received. We'll start working on your order shortly.</p></div></body></html>`;
    default: return '';
  }
}

const api = {
  lanEscapeHtml,
  notice,
  ensureQuoteApprovalToken,
  ensureTrackingToken,
  verifyOrderAccessToken,
  verifyQuoteApprovalToken,
  renderLanQuoteApprovalPage,
  applyQuoteApprovalToStore,
  isQuoteExpired,
  localDayOf,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytLanQuotePage = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
