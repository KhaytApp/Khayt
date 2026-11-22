/**
 * lib/lan-order-page.js is the customer's tracking page, lifted out of the
 * `/order/:id` route of lib/lan-server.js so the Mac app serves the same
 * bytes. THE PROOF METHOD: the route's page-building block is copied below
 * VERBATIM (one edit: the carriers require path, relative to this file) and
 * run against generated orders; the module must produce the identical page.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const LanAuth = require('../lib/lan-auth.js');
const LanOrderPage = require('../lib/lan-order-page.js');
const lanEscapeHtml = LanAuth.lanEscapeHtml;
function scriptSafeJson(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026');
}

function originalPage(order, store) {
            const shopName = lanEscapeHtml(store.settings?.shopName || 'Khayt');
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
              let carriersLib = null;
              try { carriersLib = require('../lib/carriers.js'); } catch (_) { carriersLib = null; }
              const proj = carriersLib ? carriersLib.projectShipping(order) : null;
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
const originalNotFound = () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Not Found</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Order Not Found</h2><p>We couldn't find an order with that ID. Please check the link and try again.</p></div></body></html>`;
const originalInvalid = () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Invalid tracking link</h2><p>Use the tracking link your shop sent you, or ask them for an updated link.</p></div></body></html>`;

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
const pick = (r, list) => list[Math.floor(r() * list.length)];
function genOrder(r, i) {
  const o = { id: `O-${i}`, status: pick(r, ['pending', 'printing', 'post', 'qc', 'completed', 'on_hold', 'cancelled', 'delivered', 'weird']) };
  if (r() < 0.8) o.project = pick(r, ['Bracket', 'Vase <b>&</b>', 'مقبض', '']);
  if (r() < 0.6) o.client = pick(r, ['Sara', 'Al Noor & Sons', '']);
  if (r() < 0.6) o.material = pick(r, ['PLA', 'PETG "clear"', '']);
  if (r() < 0.6) o.dueDate = pick(r, ['2027-02-01', '']);
  if (r() < 0.4) { o.shippingStatus = pick(r, ['label_created', 'in_transit', 'out_for_delivery', 'delivered', 'exception', 'odd']); }
  if (r() < 0.4) { o.trackingNumber = pick(r, ['TN123', '<x>']); o.carrier = pick(r, ['smsa', 'aramex', 'spl', 'manual', 'nope', undefined]); }
  if (r() < 0.5) o.surveyToken = pick(r, ['tok-1', 'a"b<c>&']);
  if (r() < 0.3) o.survey = { rating: 5 };
  return o;
}

test('the tracking page is byte-identical to the route over generated orders', () => {
  const r = rng(20260916);
  let withShipping = 0, withSurvey = 0, thanked = 0;
  for (let i = 0; i < 500; i++) {
    const order = genOrder(r, i);
    const store = { settings: pick(r, [{ shopName: 'Khayt' }, { shopName: 'Al <Noor>' }, {}]) };
    const expected = originalPage(order, store);
    assert.equal(LanOrderPage.trackingPage(order, store), expected, `order ${i}: ${JSON.stringify(order)}`);
    if (expected.includes('card-title">Shipping')) withShipping++;
    if (expected.includes('id="surveyCard"')) withSurvey++;
    if (expected.includes('Thank you for your feedback')) thanked++;
  }
  assert.ok(withShipping > 20 && withSurvey > 20 && thanked > 20, `shipping ${withShipping} survey ${withSurvey} thanked ${thanked}`);
});

test('the two notices are the route\'s pages', () => {
  assert.equal(LanOrderPage.notice('order_not_found'), originalNotFound());
  assert.equal(LanOrderPage.notice('invalid_tracking_link'), originalInvalid());
  assert.equal(LanOrderPage.notice('x'), '');
});

test('a survey is checked and written as the route did', () => {
  assert.deepEqual(LanOrderPage.surveyCheck({ rating: 5 }), { ok: false, status: 400, error: 'Invalid payload — token and rating (1-5) are required' });
  assert.equal(LanOrderPage.surveyCheck({ token: 't', rating: '5' }).ok, false);
  assert.equal(LanOrderPage.surveyCheck({ token: 't', rating: 6 }).ok, false);
  const ok = LanOrderPage.surveyCheck({ token: 't', rating: 4, comment: 'x'.repeat(2500) });
  assert.equal(ok.ok, true);
  assert.equal(ok.comment.length, 2000);
  const patched = LanOrderPage.surveyPatch({ id: 'O', surveyToken: 't', status: 'completed' }, 4, '  fine  ', '2027-01-15T09:16:00.000Z');
  assert.deepEqual(patched.survey, { rating: 4, comment: 'fine', submittedAt: '2027-01-15T09:16:00.000Z' });
  assert.equal(patched.surveyToken, undefined);
  assert.equal(patched.status, 'completed');
  assert.equal(LanOrderPage.SURVEY_SUBMIT_LIMIT, 30);
});

test('the server draws the page and the notices from the module', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  assert.ok(src.includes('LanOrderPage.trackingPage(order, store)'));
  assert.ok(src.includes("LanOrderPage.notice('invalid_tracking_link')"));
  assert.ok(src.includes("LanOrderPage.notice('order_not_found')"));
  assert.ok(!src.includes('<title>Order Status — '), 'an inline copy of the tracking page is back in the server');
});
