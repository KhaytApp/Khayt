'use strict';

/**
 * The customer's order page — "where is my order" — and the survey it ends
 * with. Lifted out of `lib/lan-server.js`, where the page was built inline
 * in the `/order/:id` route, so the native Mac app can serve the SAME bytes.
 * The Node server draws from this module now; `test/lan-order-page.test.js`
 * holds it to the original route, copied verbatim.
 *
 * PURE. The shipping projection comes from `lib/carriers.js` (moved from
 * renderer/ so both hosts can load it); the escaping is `lan-auth`'s. The
 * survey rule is what the `/api/survey` route checked and wrote, without the
 * store or the clock: the host finds the order by token and hands the clock in.
 */
(function (global) {

  const LanAuth = global.KhaytLanAuth
    || (typeof require === 'function' ? require('./lan-auth.js') : null);
  const Carriers = global.KhaytCarriers
    || (typeof require === 'function' ? require('./carriers.js') : null);
  const lanEscapeHtml = (s) => LanAuth.lanEscapeHtml(s);

  /** JSON safe to sit inside a <script> — the server's `scriptSafeJson`. */
  function scriptSafeJson(value) {
    return JSON.stringify(value)
      .replace(/</g, '\\u003c')
      .replace(/>/g, '\\u003e')
      .replace(/&/g, '\\u0026');
  }

  /** Survey submissions per address, per window. */
  const SURVEY_SUBMIT_LIMIT = 30;

  /** `GET /order/:id` — the tracking page, from the order and the book's settings. */
  function trackingPage(order, store) {
    const settings = (store && store.settings) || {};
    const shopName = lanEscapeHtml(settings.shopName || 'Khayt');
    const projectName = lanEscapeHtml(order.project || order.id);
    const clientName = order.client ? lanEscapeHtml(order.client) : null;
    const material = order.material ? lanEscapeHtml(order.material) : null;
    const dueDate = order.dueDate ? lanEscapeHtml(order.dueDate) : null;
    const status = (order.status || 'pending').toLowerCase();

    const statusLabels = {
      pending: 'Waiting to Start',
      printing: 'Printing',
      post: 'Post-Processing',
      qc: 'Quality Check',
      completed: 'Ready for Pickup / Completed',
      on_hold: 'On Hold',
      cancelled: 'Cancelled'
    };
    const statusDescriptions = {
      pending: 'Your order is in the queue and will start soon.',
      printing: 'Your order is currently being printed.',
      post: 'Your print is finished — post-processing is underway.',
      qc: 'Your order is going through a quality check.',
      completed: 'Your order is complete and ready for pickup!',
      on_hold: 'Your order is temporarily on hold. We\'ll update you soon.',
      cancelled: 'This order has been cancelled. Please contact us if you have questions.'
    };
    const steps = ['Pending', 'Printing', 'Post-Processing', 'Quality Check', 'Ready / Completed'];
    const stepMap = { pending: 0, printing: 1, post: 2, qc: 3, completed: 4 };
    const currentStep = stepMap[status] !== undefined ? stepMap[status] : (status === 'on_hold' || status === 'cancelled' ? -1 : 0);
    const isWarning = status === 'on_hold' || status === 'cancelled';
    const accentColor = isWarning ? (status === 'cancelled' ? '#ef4444' : '#f59e0b') : '#6366f1';
    const statusLabel = lanEscapeHtml(statusLabels[status] || status);
    const statusDesc = lanEscapeHtml(statusDescriptions[status] || 'We are working on your order.');

    const stepsHtml = steps.map((label, i) => {
      const active = !isWarning && i <= currentStep;
      const isCurrent = !isWarning && i === currentStep;
      return `<div class="step${active ? ' active' : ''}${isCurrent ? ' current' : ''}"><div class="dot"></div><div class="step-label">${lanEscapeHtml(label)}</div></div>`;
    }).join('');

    const detailsHtml = [
      clientName ? `<div class="detail"><span class="detail-label">Customer</span><span class="detail-val">${clientName}</span></div>` : '',
      material ? `<div class="detail"><span class="detail-label">Material</span><span class="detail-val">${material}</span></div>` : '',
      dueDate ? `<div class="detail"><span class="detail-label">Est. Due Date</span><span class="detail-val">${dueDate}</span></div>` : ''
    ].filter(Boolean).join('');

    // Shipping block — customer-safe projection only (status, carrier, tracking #,
    // carrier deep link). Never projects shipmentMeta / cost / internal notes.
    let shippingHtml = '';
    if (order.shippingStatus || order.trackingNumber) {
      const proj = Carriers ? Carriers.projectShipping(order) : null;
      const shipLabels = { label_created: 'Label created', in_transit: 'In transit', out_for_delivery: 'Out for delivery', delivered: 'Delivered', exception: 'Delivery issue' };
      const carrierName = proj && proj.carrierLabel ? (proj.carrierLabel.en || '') : (order.carrier || '');
      const stLabel = proj && proj.shippingStatus ? (shipLabels[proj.shippingStatus] || proj.shippingStatus) : '';
      const rows = [];
      if (carrierName) rows.push(`<div class="detail"><span class="detail-label">Carrier</span><span class="detail-val">${lanEscapeHtml(carrierName)}</span></div>`);
      if (proj && proj.trackingNumber) {
        const tnCell = proj.trackingUrl
          ? `<a href="${lanEscapeHtml(proj.trackingUrl)}" target="_blank" rel="noopener noreferrer" style="color:#a5b4fc;text-decoration:none;">${lanEscapeHtml(proj.trackingNumber)}</a>`
          : lanEscapeHtml(proj.trackingNumber);
        rows.push(`<div class="detail"><span class="detail-label">Tracking #</span><span class="detail-val">${tnCell}</span></div>`);
      }
      if (stLabel) rows.push(`<div class="detail"><span class="detail-label">Shipping</span><span class="detail-val">${lanEscapeHtml(stLabel)}</span></div>`);
      if (rows.length) shippingHtml = `<div class="card"><div class="card-title">Shipping</div>${rows.join('')}</div>`;
    }

    let surveyHtml = '';
    if ((order.status === 'completed' || order.status === 'delivered') && order.surveyToken && !order.survey) {
      const tokJs = scriptSafeJson(order.surveyToken);
      const oidJs = scriptSafeJson(order.id);
      surveyHtml = `<div class="card" id="surveyCard"><div class="card-title">Rate Your Experience</div><p style="color:#94a3b8;font-size:.85rem;margin-bottom:12px;">How was your order?</p><div id="stars" style="display:flex;justify-content:center;gap:6px;font-size:28px;margin-bottom:12px">${[1, 2, 3, 4, 5].map(n => `<span data-v="${n}" style="cursor:pointer">☆</span>`).join('')}</div><textarea id="surveyComment" placeholder="Optional comment" style="width:100%;background:#0f172a;border:1px solid #334155;border-radius:8px;color:#e2e8f0;padding:10px;font-size:.85rem;min-height:72px;margin-bottom:10px;box-sizing:border-box;"></textarea><button id="surveyBtn" style="width:100%;padding:10px;border:none;border-radius:8px;background:#6366f1;color:#fff;font-weight:600;cursor:pointer;">Submit Feedback</button><p id="surveyThanks" style="display:none;color:#4ade80;margin-top:10px;text-align:center;">Thank you!</p></div><script>(function(){let r=0;document.querySelectorAll('#stars span').forEach(s=>s.addEventListener('click',()=>{r=+s.dataset.v;document.querySelectorAll('#stars span').forEach((st,i)=>st.textContent=i<r?'\\u2605':'\\u2606');}));document.getElementById('surveyBtn').addEventListener('click',async()=>{if(!r){alert('Please select a rating');return;}const btn=document.getElementById('surveyBtn');btn.disabled=true;try{const res=await fetch('/api/survey',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:${tokJs},orderId:${oidJs},rating:r,comment:document.getElementById('surveyComment').value.trim()})});if(res.ok){btn.style.display='none';document.getElementById('surveyThanks').style.display='block';}else{btn.disabled=false;alert('Could not submit — try again');}}catch(e){btn.disabled=false;}});})();</script>`;
    } else if (order.survey) {
      surveyHtml = `<div class="card"><p style="color:#4ade80;text-align:center;font-size:.9rem;">⭐ Thank you for your feedback!</p></div>`;
    }

    return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Status — ${projectName}</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh;padding:24px 16px}.container{max-width:480px;margin:0 auto}.header{text-align:center;margin-bottom:28px}.header h1{font-size:1.5rem;font-weight:700;color:#f1f5f9;margin-bottom:4px}.header .subtitle{color:#94a3b8;font-size:.9rem}.card{background:#1e293b;border-radius:16px;padding:24px;margin-bottom:16px}.card-title{font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:#64748b;margin-bottom:16px}.status-badge{display:inline-block;padding:6px 14px;border-radius:20px;font-size:.85rem;font-weight:600;background:${accentColor}22;color:${accentColor};margin-bottom:12px}.status-desc{color:#94a3b8;font-size:.9rem;line-height:1.5}.progress{display:flex;align-items:flex-start;gap:0;margin-top:8px}.step{flex:1;display:flex;flex-direction:column;align-items:center;position:relative}.step:not(:last-child)::after{content:'';position:absolute;top:10px;left:50%;width:100%;height:2px;background:#334155;z-index:0}.step.active:not(:last-child)::after{background:#6366f1}.dot{width:20px;height:20px;border-radius:50%;background:#334155;border:2px solid #334155;position:relative;z-index:1;transition:all .2s}.step.active .dot{background:#6366f1;border-color:#6366f1}.step.current .dot{box-shadow:0 0 0 4px #6366f133}.step-label{font-size:.65rem;color:#64748b;margin-top:6px;text-align:center;line-height:1.3}.step.active .step-label{color:#a5b4fc}.detail{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid #0f172a}.detail:last-child{border-bottom:none}.detail-label{font-size:.8rem;color:#64748b}.detail-val{font-size:.85rem;color:#e2e8f0;font-weight:500;text-align:right;max-width:60%}.footer{text-align:center;margin-top:24px;color:#475569;font-size:.8rem;line-height:1.6}</style></head><body><div class="container"><div class="header"><h1>${projectName}</h1><div class="subtitle">Order Status</div></div><div class="card"><div class="card-title">Current Status</div><div class="status-badge">${statusLabel}</div><p class="status-desc">${statusDesc}</p>${!isWarning ? `<div class="progress" style="margin-top:20px">${stepsHtml}</div>` : ''}</div>${detailsHtml ? `<div class="card"><div class="card-title">Order Details</div>${detailsHtml}</div>` : ''}${shippingHtml}${surveyHtml}<div class="footer"><p>Thank you for choosing ${shopName}</p><p style="margin-top:4px;font-size:.75rem;color:#334155">Auto-refreshes every 30s</p></div></div><script>setTimeout(()=>location.reload(),30000);</script></body></html>`;
  }

  /** The two answers around the page, as the route wrote them. */
  function notice(kind) {
    switch (kind) {
      case 'order_not_found': return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Not Found</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Order Not Found</h2><p>We couldn't find an order with that ID. Please check the link and try again.</p></div></body></html>`;
      case 'invalid_tracking_link': return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Invalid tracking link</h2><p>Use the tracking link your shop sent you, or ask them for an updated link.</p></div></body></html>`;
      default: return '';
    }
  }

  /**
   * What a posted survey must carry: a token and a rating 1–5; a comment is
   * cut at 2000. Returns `{ ok: true, token, rating, comment }` or the
   * refusal the route has always sent.
   */
  function surveyCheck(parsed) {
    const p = parsed && typeof parsed === 'object' ? parsed : {};
    let comment = p.comment;
    if (typeof comment === 'string' && comment.length > 2000) comment = comment.slice(0, 2000);
    const { token, rating } = p;
    if (!token || typeof rating !== 'number' || rating < 1 || rating > 5) {
      return { ok: false, status: 400, error: 'Invalid payload — token and rating (1-5) are required' };
    }
    return { ok: true, token, rating, comment };
  }

  /** The order with its survey written and its token spent — the route's write. */
  function surveyPatch(order, rating, comment, submittedAt) {
    return {
      ...order,
      survey: { rating, comment: (comment || '').trim(), submittedAt },
      surveyToken: undefined,
    };
  }

  const api = { trackingPage, notice, scriptSafeJson, surveyCheck, surveyPatch, SURVEY_SUBMIT_LIMIT };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLanOrderPage = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
