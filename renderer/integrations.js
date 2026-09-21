/**
 * External integrations: email, webhooks, BNPL, LAN API, status pages, surveys,
 * Telegram, iCal, referral analytics, shipping links.
 */
/* ============================================================
   BNPL / Payment-link service catalog (23 global services)
   ============================================================ */
const BNPL_CATALOG = [
  // ── MENA ────────────────────────────────────────────────────────────────────
  { id:'tabby',       name:'Tabby',              regions:['SA','AE','KW','BH','EG','QA'], color:'#6c5ce7', hasApi:true,  dashUrl:'https://business.tabby.ai',                      desc:'Split into 4 payments, 0% interest · MENA' },
  { id:'tamara',      name:'Tamara',             regions:['SA','AE','KW'],               color:'#00b48a', hasApi:true,  dashUrl:'https://merchant.tamara.co',                      desc:'Pay in 2, 3 or 6 instalments · Gulf' },
  { id:'cashew',      name:'Cashew',             regions:['AE','KW','BH','QA'],          color:'#f59e0b', hasApi:false, dashUrl:'https://getcashew.com',                           desc:'Split purchases in the Gulf' },
  { id:'postpay',     name:'Postpay',            regions:['AE','SA'],                    color:'#0ea5e9', hasApi:false, dashUrl:'https://postpay.io',                              desc:'Pay in 3 installments · UAE/KSA' },
  // ── Europe ──────────────────────────────────────────────────────────────────
  { id:'klarna',      name:'Klarna',             regions:['SE','DE','GB','US','AU','NL'], color:'#ffb3c7', hasApi:false, dashUrl:'https://www.klarna.com/merchant',                 desc:'Pay in 3, finance or pay now · 40+ countries' },
  { id:'clearpay',    name:'Clearpay / Afterpay',regions:['AU','NZ','GB','US','CA','FR'], color:'#b2fce4', hasApi:false, dashUrl:'https://www.clearpay.co.uk/merchant',             desc:'Pay in 4 fortnightly instalments' },
  { id:'scalapay',    name:'Scalapay',           regions:['IT','FR','DE','ES','PT'],     color:'#ff6b6b', hasApi:false, dashUrl:'https://scalapay.com',                            desc:'Split into 3 · Southern Europe' },
  { id:'alma',        name:'Alma',               regions:['FR','BE','ES','IT','NL'],     color:'#fa7268', hasApi:false, dashUrl:'https://almapay.com',                             desc:'Pay in 2–12 instalments · France & Europe' },
  { id:'laybuy',      name:'Laybuy',             regions:['NZ','AU','GB'],               color:'#5b2d8e', hasApi:false, dashUrl:'https://business.laybuy.com',                    desc:'6 weekly instalments · NZ/AU/UK' },
  // ── North America ────────────────────────────────────────────────────────────
  { id:'affirm',      name:'Affirm',             regions:['US','CA'],                    color:'#0fa0db', hasApi:false, dashUrl:'https://www.affirm.com/business',                 desc:'Flexible monthly payments · US & Canada' },
  { id:'sezzle',      name:'Sezzle',             regions:['US','CA','IN','DE'],          color:'#392558', hasApi:false, dashUrl:'https://dashboard.sezzle.com',                    desc:'Pay in 4 interest-free · US/CA/EU' },
  { id:'zip',         name:'Zip (Quadpay)',       regions:['AU','NZ','US','GB','ZA'],     color:'#aa8fff', hasApi:false, dashUrl:'https://zip.co/merchants',                        desc:'Pay in 4 fortnightly · AU/US/UK' },
  // ── Asia-Pacific ─────────────────────────────────────────────────────────────
  { id:'paidy',       name:'Paidy',              regions:['JP'],                         color:'#3d5afe', hasApi:false, dashUrl:'https://merchant.paidy.com',                      desc:'Monthly consolidation & 3-instalments · Japan' },
  { id:'atome',       name:'Atome',              regions:['SG','MY','HK','ID','TH','PH'],color:'#00c853', hasApi:false, dashUrl:'https://www.atome.sg/merchants',                  desc:'Pay in 3 equal instalments · Southeast Asia' },
  { id:'kredivo',     name:'Kredivo',            regions:['ID','VN','TH','PH'],          color:'#e53935', hasApi:false, dashUrl:'https://kredivo.com/business',                    desc:'Southeast Asia BNPL leader' },
  // ── India ────────────────────────────────────────────────────────────────────
  { id:'simpl',       name:'Simpl',              regions:['IN'],                         color:'#ff4b00', hasApi:false, dashUrl:'https://getsimpl.com/merchant',                   desc:'Pay in 3 with no-cost EMI · India' },
  { id:'lazypay',     name:'LazyPay',            regions:['IN'],                         color:'#fbbf24', hasApi:false, dashUrl:'https://lazypay.in',                              desc:'Pay later & EMI · India' },
  // ── Africa ───────────────────────────────────────────────────────────────────
  { id:'mpesa',       name:'M-Pesa',             regions:['KE','TZ','GH','EG','LS','MZ'],color:'#4caf50', hasApi:false, dashUrl:'https://developer.safaricom.co.ke',               desc:'Mobile money · East & Central Africa' },
  { id:'flutterwave', name:'Flutterwave',        regions:['NG','GH','KE','ZA','EG','TZ'],color:'#f68b1e', hasApi:false, dashUrl:'https://merchant.flutterwave.com',                desc:'Pan-African payments platform' },
  // ── Latin America ────────────────────────────────────────────────────────────
  { id:'mercadopago', name:'Mercado Pago',       regions:['BR','AR','MX','CO','CL'],     color:'#00b1ea', hasApi:false, dashUrl:'https://www.mercadopago.com.br/developers',       desc:'Largest LATAM platform · cuotas / instalments' },
  { id:'kueski',      name:'Kueski Pay',         regions:['MX'],                         color:'#ff5722', hasApi:false, dashUrl:'https://kueskipay.com/negocios',                  desc:'Buy now, pay later · Mexico' },
  // ── Global ───────────────────────────────────────────────────────────────────
  { id:'stripe',      name:'Stripe',             regions:['*'],                          color:'#635bff', hasApi:true,  dashUrl:'https://dashboard.stripe.com',                    desc:'Global payments — enables Klarna/Afterpay/Affirm via dashboard' },
  { id:'paypal',      name:'PayPal Pay Later',   regions:['US','GB','AU','DE','FR','IT'], color:'#003087', hasApi:false, dashUrl:'https://www.paypal.com/merchant',                 desc:'Pay in 4 or monthly financing via PayPal' },
];

/* ============================================================
   Feature 5 (new batch): Email notification helpers
   ============================================================ */
async function autoSendEmailNotification(order, newStatus) {
  const cfg = settings.emailConfig;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;

  // The message — and the decision to send one at all — is
  // `lib/order-email.js`, so the Mac app sends the same email rather than a
  // second app's idea of one. What stays here is what only this app has: the
  // toasts, and the transport in the main process.
  const mail = KhaytOrderEmail.messageFor(order, newStatus, {
    settings, clients,
    shopName: shopName() || 'Khayt',
    clientName: client ? localName(client) : '',
    statusLabel: t('queue.' + newStatus) || newStatus,
  });
  if (!mail) {
    // A customer with no address on file, on a move the shop DOES want told
    // about, is worth saying out loud — it is the one "not sent" that looks
    // like a bug rather than a setting. Every other no is a silent skip.
    const wanted = cfg && cfg.provider && cfg.provider !== 'none' &&
      (cfg.triggers || []).includes(newStatus) && order.clientId && !client?.email;
    if (wanted) {
      toast(t('notify.no_email') || `No email on file for ${localName(client)} — notification not sent`, 'info', 3000);
    }
    return;
  }
  const { to, subject, html: body } = mail;
  try {
    const result = await window.hubAPI?.sendEmail?.({ to, subject, body, smtpConfig: cfg });
    if (result?.ok) {
      toast(t('notify.email_sent'), 'success', 2000);
    } else if (result?.fallback && result?.mailtoUrl) {
      // mailto fallback — no toast
    } else {
      const msg = result?.error || t('notify.email_failed') || 'Email notification failed';
      console.warn('autoSendEmailNotification:', msg);
      toast(msg, 'warning', 4000);
    }
  } catch (e) {
    console.warn('autoSendEmailNotification:', e);
    toast(t('notify.email_failed') || 'Email notification failed', 'warning', 4000);
  }
}

// Re-entrancy guard for the periodic digest send. Declared here (where it's used)
// — it must live in integrations.js's top-level scope, not another module's IIFE.
let _digestInFlight = false;

async function checkAndSendDigest() {
  if (_digestInFlight) return;
  const d = settings.emailDigest;
  if (!d?.enabled) return;
  const cfg = settings.emailConfig;
  if (!cfg || cfg.provider === 'none') return;
  const to = d.recipientEmail || settings.email;
  if (!to) return;
  const now = new Date();
  if (now.getHours() !== (d.hour ?? 8)) return;
  // Compute period key
  let periodKey;
  if (d.frequency === 'weekly') {
    if (now.getDay() !== (d.weekday ?? 1)) return;
    // ISO week number
    const jan1 = new Date(now.getFullYear(), 0, 1);
    const week = Math.ceil(((now - jan1) / 86400000 + jan1.getDay() + 1) / 7);
    periodKey = `${now.getFullYear()}-W${String(week).padStart(2,'0')}`;
  } else if (d.frequency === 'monthly') {
    // Fire on the configured day-of-month (clamped to the month's length).
    const lastDom = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
    const fireDom = Math.min(d.monthday ?? 1, lastDom);
    if (now.getDate() !== fireDom) return;
    periodKey = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  } else {
    periodKey = localDateStr(now);
  }
  if (d.lastSentDate === periodKey) return; // already sent
  const body = buildDigestEmailHtml();
  const freqWord = d.frequency === 'weekly' ? 'Weekly' : (d.frequency === 'monthly' ? 'Monthly' : 'Daily');
  const subject = `${shopName() || 'Khayt'} — ${freqWord} Digest`;
  _digestInFlight = true;
  try {
    const result = await window.hubAPI?.sendEmail?.({ to, subject, body, smtpConfig: cfg });
    if (result?.ok) {
      settings.emailDigest = { ...settings.emailDigest, lastSentDate: periodKey };
      saveAll();
    }
  } finally {
    _digestInFlight = false;
  }
}

/* ============================================================
   Feature 8 (new 8-pack): Customer loyalty tiers
   ============================================================ */

/** Get the best matching tier for a client based on their completed order stats */

/** Render the loyalty tier management UI in settings */


/* ============================================================
   Round 12 — Feature 1: Outbound Webhooks
   ============================================================ */
/**
 * Fan an event out to every enabled subscription listening for it (PUBLIC-API-SPEC §2).
 * The POST itself still goes through the hardened main-process handler, so the https-only
 * / blocked-host / DNS-rebinding / no-redirect / HMAC guarantees are unchanged.
 *
 * Retries use the bus's backoff ladder and are scheduled in-process: a retry survives as
 * long as the app is running. A delivery still pending when the app quits is recorded as
 * such in the log rather than resumed (the spec's durable main-process queue is a
 * follow-up); the consumer-side idempotency key makes a manual Resend safe.
 */
function webhookSubscriptions() {
  const wh = settings.webhooks || {};
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return [];
  if (!Array.isArray(wh.subscriptions)) {
    // Lazily migrate the legacy one-URL-per-event config on first use.
    const migrated = Bus.migrateLegacyWebhooks(wh);
    settings.webhooks = { ...wh, subscriptions: migrated };
    if (migrated.length) saveAll();
    return migrated;
  }
  return wh.subscriptions;
}

function recordWebhookDelivery(entry) {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  const wh = settings.webhooks || {};
  settings.webhooks = { ...wh, deliveries: Bus.appendDelivery(wh.deliveries, entry) };
  saveAll();
}

function disableWebhookSubscription(subId, reason) {
  const wh = settings.webhooks || {};
  settings.webhooks = {
    ...wh,
    subscriptions: (wh.subscriptions || []).map(s => s.id === subId ? { ...s, enabled: false, disabledReason: reason } : s),
  };
  saveAll();
  toast(t('webhook.disabled', { reason }) || `Webhook disabled: ${reason}`, 'warning', 5000);
}

/** Deliver one body to one subscription, retrying per the bus policy. */
async function deliverWebhook(sub, body, attempt = 1) {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  let status, error;
  try {
    const r = await window.hubAPI?.fireWebhook?.(sub.url, body.event, body, sub.secret || '');
    status = r && r.status;
    if (r && r.ok === false) error = r.error || `HTTP ${status || '?'}`;
  } catch (e) {
    error = String(e && e.message || e);
  }
  const okDelivered = !error;
  recordWebhookDelivery({
    id: body.id, subscriptionId: sub.id, event: body.event, at: new Date().toISOString(),
    status: okDelivered ? 'ok' : (Bus.shouldRetry(status, attempt) ? 'retrying' : 'failed'),
    httpStatus: status || null, attempts: attempt, error: error || null,
  });
  if (okDelivered) { clearPendingWebhook(body.id); return; }
  // A consumer answering 410 Gone is telling us to stop for good.
  if (Bus.isGone(status)) { clearPendingWebhook(body.id); disableWebhookSubscription(sub.id, 'gone'); return; }
  if (Bus.shouldRetry(status, attempt)) {
    const delay = Bus.backoffDelayMs(attempt + 1);
    // Persist the retry BEFORE arming the timer, so a quit mid-backoff resumes on launch.
    persistPendingWebhook({ id: body.id, subscriptionId: sub.id, event: body.event, payload: body.payload, attempt: attempt + 1 }, delay);
    setTimeout(() => { deliverWebhook(sub, body, attempt + 1); }, delay);
  } else {
    clearPendingWebhook(body.id);
    toast((t('webhook.failed') || 'Webhook failed') + `: ${body.event}`, 'warning', 4000);
  }
}

function persistPendingWebhook(entry, delayMs) {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  const wh = settings.webhooks || {};
  settings.webhooks = { ...wh, pending: Bus.schedulePending(wh.pending, entry, delayMs) };
  saveAll();
}

function clearPendingWebhook(deliveryId) {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  const wh = settings.webhooks || {};
  if (!Array.isArray(wh.pending) || !wh.pending.length) return;
  settings.webhooks = { ...wh, pending: Bus.removePending(wh.pending, deliveryId) };
  saveAll();
}

/**
 * Resume webhook retries left over from a previous run. Anything that came due while the
 * app was closed fires now; anything still in the future gets its timer re-armed. Called
 * once at boot — this is what makes the retry queue durable rather than best-effort.
 */
function resumePendingWebhooks() {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  const wh = settings.webhooks || {};
  const pending = Array.isArray(wh.pending) ? wh.pending : [];
  if (!pending.length) return;
  const subById = new Map((wh.subscriptions || []).map(s => [s.id, s]));
  const fire = (p) => {
    const sub = subById.get(p.subscriptionId);
    if (!sub || sub.enabled === false) { clearPendingWebhook(p.id); return; }
    deliverWebhook(sub, { id: p.id, event: p.event, version: 1, timestamp: new Date().toISOString(), payload: p.payload || {} }, p.attempt || 1);
  };
  for (const p of Bus.duePending(pending)) fire(p);
  for (const p of Bus.futurePending(pending)) setTimeout(() => fire(p), Math.min(p.inMs, 2_147_000_000));
}

/**
 * A status or lifecycle event, with its payload built by the shared rule.
 *
 * The payload is `KhaytWebhookBus.statusPayload` rather than an object literal
 * at each call site, because the Mac app signs the same bytes: a field renamed
 * here — or the keys written in a different order, which changes the JSON and
 * therefore the HMAC — would be a delivery a consumer verifies and rejects from
 * one app and accepts from the other. The Bus is reached for through the same
 * guard as everywhere else in this file: `bedready.html` is a second entry
 * point with its own script list.
 */
function fireStatusWebhook(eventName, order, newStatus) {
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  return fireWebhook(eventName, Bus.statusPayload(eventName, order, newStatus));
}

async function fireWebhook(eventName, payload) {
  const wh = settings.webhooks;
  if (!wh?.enabled) return;
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  const subs = Bus.matchSubscriptions(webhookSubscriptions(), eventName);
  if (!subs.length) return;   // no listener → no-op, exactly as before
  const body = Bus.buildDeliveryBody(eventName, payload);
  for (const sub of subs) deliverWebhook(sub, { ...body, id: body.id + '_' + sub.id });
}

/** Manual resend from the delivery log. */
function resendWebhookDelivery(deliveryId) {
  const wh = settings.webhooks || {};
  const rec = (wh.deliveries || []).find(d => d.id === deliveryId);
  const sub = (wh.subscriptions || []).find(s => s.id === (rec && rec.subscriptionId));
  if (!rec || !sub) return;
  const Bus = (typeof KhaytWebhookBus !== 'undefined') ? KhaytWebhookBus : null;
  if (!Bus) return;
  deliverWebhook(sub, Bus.buildDeliveryBody(rec.event, rec.payload || {}, rec.id + '_resend'));
  toast(t('webhook.resent') || 'Resent', 'info');
}


/* ============================================================
   Round 12 — Feature 3: Post-Delivery NPS / Star Rating Survey
   ============================================================ */
async function generateSurveyPage(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  if (!order.surveyToken) {
    const bytes = new Uint8Array(12);
    crypto.getRandomValues(bytes);
    order.surveyToken = 'srv-' + Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    saveAll();
  }
  const token = order.surveyToken;

  const lanInfo = await window.hubAPI?.getLanUrl?.();
  const surveyUrl = lanInfo?.ok ? lanInfo.url + '/api/survey' : null;

  const shopName = escapeHtml(shopField('biz') || 'Khayt');
  const html = `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${shopName} — Order Feedback</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;padding:20px;}
  .card{background:#1e293b;border-radius:16px;padding:40px 36px;max-width:480px;width:100%;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.5);}
  h1{font-size:22px;margin:0 0 6px;} p{color:#94a3b8;margin:0 0 24px;}
  .stars{display:flex;justify-content:center;gap:8px;margin-bottom:24px;}
  .star{font-size:40px;cursor:pointer;transition:transform .15s;} .star:hover,.star.sel{transform:scale(1.2);}
  textarea{width:100%;box-sizing:border-box;background:#0f172a;border:1px solid #334155;color:#e2e8f0;border-radius:8px;padding:12px;font-size:14px;resize:vertical;min-height:90px;margin-bottom:16px;}
  button{background:#5E2E14;color:#fff;border:none;border-radius:8px;padding:12px 28px;font-size:15px;cursor:pointer;font-weight:600;}
  button:hover{background:#7c3d1b;} .thanks{display:none;font-size:18px;font-weight:600;color:#4ade80;}
</style></head>
<body><div class="card">
  <h1>📦 ${shopName}</h1>
  <p>Order <strong>${escapeHtml(order.id)}</strong>${order.project ? ' — ' + escapeHtml(order.project) : ''}</p>
  <p>How would you rate your experience?</p>
  <div class="stars" id="stars">
    <span class="star" data-v="1">⭐</span>
    <span class="star" data-v="2">⭐</span>
    <span class="star" data-v="3">⭐</span>
    <span class="star" data-v="4">⭐</span>
    <span class="star" data-v="5">⭐</span>
  </div>
  <div id="ratingErr" style="display:none;color:#f87171;font-size:13px;margin:-16px 0 12px;">Please select a rating first.</div>
  <textarea id="comment" placeholder="Any comments? (optional)"></textarea>
  <button onclick="submit()">Submit Feedback</button>
  <div class="thanks" id="thanks">🎉 Thank you for your feedback!</div>
</div>
<script id="survey-config" type="application/json">{"token":${JSON.stringify(token)},"orderId":${JSON.stringify(orderId)}}</script>
<script>
  let _cfg = {};
  try {
    _cfg = JSON.parse(document.getElementById('survey-config').textContent);
  } catch (e) {
    console.error('survey-config parse:', e);
  }
  let rating = 0;
  document.querySelectorAll('.star').forEach(s => {
    s.addEventListener('click', () => {
      rating = parseInt(s.dataset.v);
      document.querySelectorAll('.star').forEach((st, i) => st.classList.toggle('sel', i < rating));
    });
  });
  async function submit() {
    if (!rating) { document.getElementById('ratingErr').style.display='block'; return; }
    document.getElementById('ratingErr').style.display='none';
    const btn = document.querySelector('button');
    btn.disabled = true; btn.textContent = 'Sending…';
    const data = { token: _cfg.token, orderId: _cfg.orderId, rating, comment: document.getElementById('comment').value.trim() };
    ${surveyUrl ? `
    try {
      const r = await fetch(${JSON.stringify(surveyUrl)}, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
      });
      if (r.ok) {
        document.getElementById('thanks').style.display = 'block';
        btn.style.display = 'none';
        document.getElementById('stars').style.pointerEvents = 'none';
      } else {
        btn.disabled = false; btn.textContent = 'Submit Feedback';
        document.getElementById('thanks').textContent = '⚠ Submission failed. Please try again.';
        document.getElementById('thanks').style.cssText = 'display:block;color:#f87171;';
      }
    } catch(e) {
      btn.disabled = false; btn.textContent = 'Submit Feedback';
      document.getElementById('thanks').textContent = '⚠ Could not connect. Make sure you are on the same network.';
      document.getElementById('thanks').style.cssText = 'display:block;color:#f87171;';
    }
    ` : `
    document.getElementById('thanks').textContent = '⚠ Survey endpoint not available. Please contact the shop directly.';
    document.getElementById('thanks').style.cssText = 'display:block;color:#f87171;font-size:14px;';
    btn.disabled = false; btn.textContent = 'Submit Feedback';
    `}
  }
</script>
</body></html>`;

  window.hubAPI?.saveHtml?.(html, `survey-${orderId}.html`, { interactive: true });
  toast(t('cl.portal_generated'), 'success', 4000);
}

function openRecordSurveyModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  openFormModal({
    title: t('survey.title'),
    saveLabel: t('common.save'),
    bodyHtml: `
      <p style="color:var(--text-muted);margin:0 0 16px;">${t('survey.intro').split('{id}').map(escapeHtml).join(`<strong>${escapeHtml(orderId)}</strong>`)}</p>
      <label>${escapeHtml(t('survey.star_rating'))}</label>
      <div style="display:flex;gap:8px;margin-bottom:16px;" id="surveyStarRow">
        ${[1,2,3,4,5].map(n => `<button class="btn${(order.survey?.rating||0)>=n ? ' primary' : ' ghost'}" data-star="${n}" style="font-size:20px;padding:6px 10px;" type="button">⭐</button>`).join('')}
      </div>
      <label>${escapeHtml(t('survey.comment_optional'))}</label>
      <textarea id="surveyComment" rows="3">${escapeHtml(order.survey?.comment||'')}</textarea>`,
    onMount: () => {
      $$('#surveyStarRow button').forEach(btn => {
        btn.addEventListener('click', () => {
          const v = parseInt(btn.dataset.star);
          $$('#surveyStarRow button').forEach((b, i) => {
            b.className = 'btn ' + (i < v ? 'primary' : 'ghost');
          });
        });
      });
    },
    onSave: () => {
      const rating = $$('#surveyStarRow button').filter(b => b.className.includes('primary')).length;
      order.survey = { rating, comment: $('#surveyComment').value.trim(), recordedAt: new Date().toISOString() };
      saveAll();
      toast(`✅ Rating saved: ${rating}/5`, 'success');
    }
  });
}


/* ============================================================
   Round 12 — Feature 6: Recurring job auto-clone improvements
   (Existing checkRecurringOrders extended with leadDays + template selection)
   ============================================================ */
// (checkRecurringOrders is extended in-place below its existing definition via post-load call)

/* ============================================================
   Round 12 — Feature 7: LAN API settings
   ============================================================ */

/* ============================================================
   ZATCA Phase 2 Settings
   ============================================================ */

/* ============================================================
   Feature H3: Exchange Rates Settings
   ============================================================ */

/* ============================================================
   BNPL / Payment Link Settings
   ============================================================ */

async function openBnplModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const buyer  = { name: client ? localName(client) : (order.client || ''), phone: client?.phone || '', email: client?.email || '' };
  const amount = +order.price || 0;
  const b      = settings.bnpl || {};

  const apiSvcs = BNPL_CATALOG.filter(s => s.hasApi && b[s.id]?.enabled && b[s.id]?.apiKey);

  const svcRows = apiSvcs.length
    ? apiSvcs.map(svc => `
        <div class="bnpl-modal-svc" data-svc="${escapeHtml(svc.id)}" style="padding:12px;background:var(--bg-elev);border-radius:var(--radius);margin-bottom:10px;border-inline-start:3px solid ${escapeHtml(svc.color)};">
          <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;">
            <span style="font-weight:600;">${escapeHtml(svc.name)}</span>
            <button class="btn ghost small" id="bnplGen_${escapeHtml(svc.id)}">${t('bnpl.generate')}</button>
          </div>
          <div id="bnplResult_${escapeHtml(svc.id)}" style="margin-top:8px;font-size:12px;"></div>
        </div>`
    ).join('')
    : `<p style="color:var(--text-muted);font-size:13px;">${t('bnpl.configure_first')}</p>`;

  const infoCards = BNPL_CATALOG.filter(s => !s.hasApi).map(s =>
    `<a href="#" class="bnpl-info-card" data-url="${escapeHtml(s.dashUrl)}" style="padding:8px 10px;background:var(--bg-elev);border-radius:var(--radius);border-inline-start:2px solid ${escapeHtml(s.color)};text-decoration:none;color:inherit;cursor:pointer;display:block;">
      <span style="font-weight:600;font-size:12px;">${escapeHtml(s.name)}</span>
      <span style="font-size:10px;color:var(--text-muted);margin-left:6px;">${s.regions.slice(0,4).join('·')}</span>
    </a>`
  ).join('');

  openFormModal({
    title: `💳 ${t('bnpl.payment_modal')} — ${escapeHtml(order.project || order.id)}`,
    fields: [],
    extraHtml: `
      <div style="margin-bottom:6px;font-size:12px;color:var(--text-muted);">${t('bnpl.amount_label')}: <strong>${fmtPrice(amount)} ${currencySymbol()}</strong></div>
      <h4 style="font-size:13px;margin-bottom:8px;">${t('bnpl.integrated')}</h4>
      ${svcRows}
      <details style="margin-top:12px;">
        <summary style="font-size:12px;cursor:pointer;color:var(--text-muted);">${t('bnpl.directory')} (${BNPL_CATALOG.filter(s=>!s.hasApi).length} ${t('bnpl.services')})</summary>
        <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:6px;margin-top:8px;">${infoCards}</div>
      </details>`,
    onSubmit: () => {},
  });

  // Wire up generate buttons
  for (const svc of apiSvcs) {
    document.getElementById(`bnplGen_${svc.id}`)?.addEventListener('click', async () => {
      const btn = document.getElementById(`bnplGen_${svc.id}`);
      const res_el = document.getElementById(`bnplResult_${svc.id}`);
      if (btn) { btn.disabled = true; btn.textContent = t('bnpl.generating'); }
      let result;
      const cfg = b[svc.id];
      const commonArgs = { amount, currency: cfg.currency || 'SAR', description: order.project || order.id, buyer, orderId: order.invoiceNumber || order.id, itemName: order.project || order.id };
      if (svc.id === 'tabby')  result = await window.hubAPI?.bnplTabby?.({ ...commonArgs, apiKey: cfg.apiKey, merchantCode: cfg.merchantCode });
      if (svc.id === 'tamara') result = await window.hubAPI?.bnplTamara?.({ ...commonArgs, apiKey: cfg.apiKey, country: cfg.country || 'SA' });
      if (svc.id === 'stripe') result = await window.hubAPI?.bnplStripe?.({ ...commonArgs, apiKey: cfg.apiKey, successUrl: cfg.successUrl, cancelUrl: cfg.cancelUrl, customerEmail: buyer.email });
      if (btn) { btn.disabled = false; btn.textContent = t('bnpl.generate'); }
      if (!res_el) return;
      if (result?.ok && result.url) {
        // Generate QR for the link
        let qrHtml = '';
        try { const svg = await window.hubAPI?.generateQR?.(result.url, { width: 120, margin: 1 }); if (svg) qrHtml = svg; } catch {}
        const waMsg = t('bnpl.wa_message',{name:buyer.name,url:result.url,service:svc.name}) || `Hi ${buyer.name}, here is your payment link: ${result.url}`;
        res_el.innerHTML = `
          <div style="display:flex;gap:12px;align-items:flex-start;flex-wrap:wrap;">
            <div>${qrHtml}</div>
            <div style="flex:1;min-width:120px;">
              <div style="word-break:break-all;font-size:11px;margin-bottom:6px;"><a href="#" class="bnpl-open-link" data-url="${escapeHtml(result.url)}" style="color:var(--primary);">${escapeHtml(result.url)}</a></div>
              <div style="display:flex;gap:6px;flex-wrap:wrap;">
                <button class="btn ghost small bnpl-copy-link" data-url="${escapeHtml(result.url)}">${t('bnpl.copy_link')}</button>
                <button class="btn ghost small bnpl-share-wa" data-wa-phone="${escapeHtml(buyer.phone||'')}" data-wa-msg="${escapeHtml(waMsg)}">${t('bnpl.share_wa')}</button>
              </div>
            </div>
          </div>`;
        res_el.querySelectorAll('.bnpl-open-link').forEach(a => {
          a.addEventListener('click', e => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.url); });
        });
        res_el.querySelectorAll('.bnpl-copy-link').forEach(btn => {
          btn.addEventListener('click', async () => {
            const ok = await copyText(btn.dataset.url);
            window._toast?.(ok ? (window._t?.('bnpl.link_copied') || 'Copied')
                               : (window._t?.('common.copy_failed') || 'Copy failed'), ok ? 'success' : 'warning');
          });
        });
        res_el.querySelectorAll('.bnpl-share-wa').forEach(btn => {
          btn.addEventListener('click', () => { window.hubAPI?.shareWhatsApp?.({ phone: btn.dataset.waPhone, message: btn.dataset.waMsg, pdfPath: null }); });
        });
        toast(t('bnpl.link_generated'), 'success');
      } else {
        res_el.innerHTML = `<span style="color:var(--danger);font-size:12px;">❌ ${escapeHtml(result?.error || 'Failed')}</span>`;
      }
    });
  }

  // Info card clicks
  document.querySelectorAll('.bnpl-info-card').forEach(card => {
    card.addEventListener('click', e => { e.preventDefault(); window.hubAPI?.openExternal?.(card.dataset.url); });
  });
}

/** Sync LAN bind/enabled from the settings form when present (Start without Save). */
function syncLanApiFromFormIfPresent() {
  const section = $('#lanApiSection');
  if (!section) return;
  const prev = settings.lanApi || {};
  const bindEl = section.querySelector('#lan_bind_lan');
  const enabledEl = section.querySelector('#lan_enabled');
  const portEl = section.querySelector('#lan_port');
  settings.lanApi = {
    ...prev,
    ...(enabledEl ? { enabled: enabledEl.checked } : {}),
    ...(portEl ? { port: parseInt(portEl.value, 10) || prev.port || 3219 } : {}),
    ...(bindEl ? { bindLan: bindEl.checked } : {}),
  };
}

/** Online intake requires LAN bind — not localhost-only. */
function ensureLanNetworkAccess() {
  if (!settings.onlineEnabled && !settings.lanApi?.bindLan) return;
  settings.lanApi = {
    ...(settings.lanApi || {}),
    enabled: true,
    bindLan: true,
  };
}

async function startLanServer() {
  syncLanApiFromFormIfPresent();
  ensureLanNetworkAccess();
  const lan = settings.lanApi || {};
  const bindLan = lan.bindLan || settings.onlineEnabled;
  const res = await window.hubAPI?.startLanServer?.({
    port: lan.port || 3219,
    pin: lan.pin || '',
    bindLan: bindLan ? 'lan' : 'loopback',
  });
  const statusRow = $('#lanStatusRow');
  const qrWrap    = $('#lanQrWrap');
  if (res?.ok) {
    settings.lanApi = { ...settings.lanApi, enabled: true, bindLan: !res.loopbackOnly };
    if (res.intakeToken) settings.lanApi.intakeToken = res.intakeToken;
    else if (res.intakeTokenGenerated) settings.lanApi.intakeToken = STORE_SECRET_MASK;
    // Keep the plaintext PIN in memory so the Online panel can display it; mask after first save
    if (res.intakePin) settings.lanApi.intakePin = res.intakePin;
    else if (res.intakePinGenerated) settings.lanApi.intakePin = STORE_SECRET_MASK;
    if (res.calendarToken) settings.lanApi.calendarToken = res.calendarToken;
    else if (res.calendarTokenGenerated) settings.lanApi.calendarToken = STORE_SECRET_MASK;
    saveAll();
    const loopbackWarn = res.loopbackOnly
      ? `<div style="font-size:11px;color:var(--warn);margin-top:6px;">${escapeHtml(t('lan.loopback_warn') || 'Listening on this Mac only — enable “Listen on all network interfaces” for other devices on Wi‑Fi.')}</div>`
      : `<div style="font-size:11px;color:var(--text-muted);margin-top:6px;">${escapeHtml(t('lan.same_wifi_hint') || 'Other devices: same Wi‑Fi, open this URL. Test intake: /intake')}</div>`;
    if (statusRow) {
      statusRow.innerHTML = `🟢 Active at <a href="#" class="lan-url-link" data-url="${escapeHtml(res.url)}" style="color:var(--primary);">${escapeHtml(res.url)}</a>${loopbackWarn}`;
      statusRow.querySelectorAll('.lan-url-link').forEach(a => { a.addEventListener('click', e => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.url); }); });
    }
    if (res.loopbackOnly && settings.onlineEnabled) {
      toast(t('lan.loopback_warn') || 'LAN is localhost-only — other devices cannot connect. Enable network listen in Settings → Online.', 'warning', 8000);
    }
    loadLanQr(res.url);
    refreshLanIntakePinLive();
    updateWebhookUrlDisplay(res.url);
    refreshOnlineIntakeUrlDisplay?.($('#onlineDetails'));
    renderOnlineCustomerLinks?.();
    renderWaitingOnlinePanel?.();
    renderOnlineSettings?.();
  } else {
    if (statusRow) statusRow.textContent = `❌ Failed: ${res?.error || 'unknown error'}`;
    toast((t('lan.start_failed') || 'LAN server failed to start') + ': ' + (res?.error || 'unknown'), 'error', 8000);
  }
}

function updateWebhookUrlDisplay(baseUrl) {
  const section = document.getElementById('lanWebhookSection');
  const display = document.getElementById('webhookUrlDisplay');
  if (!section || !display) return;
  const token = settings.lanApi?.webhookToken || '';
  if (!baseUrl || !token) { section.style.display = 'none'; return; }
  const firstMachine = machines[0];
  const machineId = firstMachine?.id || 'machine-id';
  const url = `${baseUrl}/api/webhook/printer/${encodeURIComponent(machineId)}`;
  display.textContent = url;
  let hint = section.querySelector('.webhook-token-hint');
  if (!hint) {
    hint = document.createElement('p');
    hint.className = 'webhook-token-hint';
    hint.style.cssText = 'font-size:11px;color:var(--text-muted);margin:6px 0 0;';
    display.insertAdjacentElement('afterend', hint);
  }
  hint.textContent = t('lan.webhook_header_hint') || 'Send webhook token via x-khayt-webhook-token header (not in URL)';
  section.style.display = 'block';
}

async function reconcileLanServerStatus() {
  const res = await window.hubAPI?.getLanUrl?.().catch(() => null);
  const live = !!res?.ok;
  settings.lanApi = { ...settings.lanApi, enabled: live };
  const statusRow = document.getElementById('lanStatusRow');
  if (statusRow) {
    if (live) {
      statusRow.innerHTML = `🟢 Active at <a href="#" class="lan-url-link" data-url="${escapeHtml(res.url)}" style="color:var(--primary);">${escapeHtml(res.url)}</a>`;
      statusRow.querySelectorAll('.lan-url-link').forEach((a) => {
        a.addEventListener('click', (e) => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.url); });
      });
    } else if (!settings.lanApi?.enabled) {
      statusRow.textContent = '⚫ Server stopped';
      document.getElementById('lanQrWrap')?.style && (document.getElementById('lanQrWrap').style.display = 'none');
    }
  }
  return live;
}

async function startTunnelFromSettings({ confirm = false } = {}) {
  if (!settings.lanApi?.enabled) {
    toast(t('lan.tunnel_need_server') || 'Start the LAN server first', 'warning');
    return { ok: false };
  }
  saveLanApiSettingsFromForm?.({ restartServer: false });
  const port = settings.lanApi?.port || 3219;
  if (confirm) {
    const confirmMsg = t('lan.tunnel_confirm_msg') || t('lan.tunnel_security_warning');
    if (!window.confirm(confirmMsg)) return { ok: false };
  }
  const tRow = document.getElementById('tunnelStatusRow');
  if (tRow) tRow.textContent = '⏳ Connecting…';
  const res = await window.hubAPI?.startTunnel?.(port, { acknowledgedRisk: true });
  if (res?.ok) {
    if (tRow) {
      tRow.innerHTML = `🟢 Active at <a href="#" class="lan-url-link" data-url="${escapeHtml(res.url)}" style="color:var(--primary)">${escapeHtml(res.url)}</a>`;
      tRow.querySelectorAll('.lan-url-link').forEach((a) => {
        a.addEventListener('click', (e) => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.url); });
      });
    }
    toast(t('lan.tunnel_active'), 'success');
    updateWebhookUrlDisplay(res.url);
  } else if (tRow) {
    tRow.textContent = `❌ ${res?.error || 'Failed to connect'}`;
    toast(res?.error || t('lan.tunnel_failed'), 'error');
  }
  return res;
}

async function refreshLanIntakePinLive() {
  const el = document.getElementById('lanIntakePinLive');
  const input = document.getElementById('lan_intake_pin');
  if (!el) return;
  const res = await window.hubAPI?.getLanUrl?.().catch(() => null);
  if (!res?.ok) {
    el.style.display = 'none';
    return;
  }
  if (res.intakePin) {
    settings.lanApi = { ...settings.lanApi, intakePin: res.intakePin };
    if (input && (!input.value || isSecretMasked(settings.lanApi.intakePin))) {
      input.value = res.intakePin;
    }
    el.style.display = 'block';
    el.textContent = (t('lan.intake_pin_live') || 'Current intake PIN (legacy): {pin}').replace('{pin}', res.intakePin);
  } else {
    el.style.display = 'none';
  }
}

async function loadLanQr(urlOverride) {
  const qrWrap = $('#lanQrWrap');
  if (!qrWrap) return;
  let url = urlOverride;
  if (!url) {
    const res = await window.hubAPI?.getLanUrl?.();
    if (!res?.ok) return;
    url = res.url;
  }
  const base = String(url || '').replace(/\/$/, '');
  const qrUrl = typeof intakeUrlFromBase === 'function' ? intakeUrlFromBase(base) : `${base}/intake`;
  let qrVisual = await window.hubAPI?.generateQR?.(qrUrl, { width: 150, dataUrl: true });
  if (!qrVisual) qrVisual = await window.hubAPI?.generateQR?.(qrUrl, { width: 150 });
  if (qrVisual) {
    qrWrap.style.display = 'block';
    const label = t('lan.qr_intake_label') || 'Scan from phone to open the customer intake form';
    const qrBlock = String(qrVisual).startsWith('data:')
      ? `<img src="${qrVisual}" alt="QR code" width="150" height="150" style="display:block;border-radius:8px;">`
      : qrVisual;
    qrWrap.innerHTML = `<div style="font-size:12px;color:var(--text-muted);margin-bottom:6px;">${escapeHtml(label)} <span style="font-size:11px;opacity:0.7;">(tap QR to copy URL)</span></div>
      <div style="font-size:11px;color:var(--text-muted);margin-bottom:4px;">${escapeHtml(t('lan.qr_url_hint') || 'Open this exact link on your phone (same Wi‑Fi). It must end with /intake')}</div>
      <div style="font-size:13px;margin-bottom:8px;padding:8px 10px;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);word-break:break-all;"><a href="#" class="lan-qr-url-link" data-url="${escapeHtml(qrUrl)}" style="color:var(--primary);font-weight:600;">${escapeHtml(qrUrl)}</a></div>
      <div id="lanQrSvgWrap" style="cursor:pointer;display:inline-block;" title="Click to copy URL">${qrBlock}</div>`;
    qrWrap.querySelector('.lan-qr-url-link')?.addEventListener('click', (e) => {
      e.preventDefault();
      window.hubAPI?.openExternal?.(e.currentTarget.dataset.url);
    });
    document.getElementById('lanQrSvgWrap')?.addEventListener('click', async () => {
      await copyAndToast(qrUrl, t('common.copied') || 'URL copied to clipboard');
    });
  }
}

/* ============================================================
   Round 12 — Feature 8: Accounting Export (double-entry CSV)
   ============================================================ */
function exportAccountingCSV() {
  const rows = [['Date','DocNumber','Type','Description','Account','Debit','Credit','VAT','Currency']];
  // Per-order currency, not the shop's base symbol. Stamping the base symbol on every row
  // while emitting the order's own price exported a 1,200 USD invoice as "1200.00, SAR" —
  // every other money path uses orderCurrency(), and lib/accounting-export.js carries the
  // invoice's own currency per row. This renderer copy was the odd one out.
  const rowCur = (o) => (typeof orderCurrency === 'function' ? orderCurrency(o) : currencySymbol());
  const cur = currencySymbol(); // base currency — used by the expense rows below

  // Revenue entries (completed invoices)
  printLog.filter(o => KhaytOrderStatus.isFinished(o)).forEach(o => {
    // A journal must balance, so the split has to match how the shop prices:
    // under exclusive pricing the debit to receivables is price + tax, not price.
    const _t = KhaytTax.computeTax(+o.price || 0, KhaytTax.profileFromSettings(settings));
    const subtotal = _t.subtotal;
    const vat = _t.taxTotal;
    // Debit Accounts Receivable
    const oc = rowCur(o);
    rows.push([o.date||o.timestamp?.split('T')[0]||'', o.id, 'Invoice', escapeHtml(o.project||o.client||'Order'), 'Accounts Receivable', (+o.price||0).toFixed(2), '', vat.toFixed(2), oc]);
    // Credit Revenue
    rows.push([o.date||o.timestamp?.split('T')[0]||'', o.id, 'Invoice', escapeHtml(o.project||o.client||'Order'), 'Revenue', '', subtotal.toFixed(2), '', oc]);
    // Credit VAT Payable. The VAT column is left BLANK here: it is already carried on the
    // A/R row above, and repeating it made a sum of that column double-count the VAT.
    if (vat > 0) rows.push([o.date||o.timestamp?.split('T')[0]||'', o.id, 'Invoice', 'VAT Payable', 'VAT Payable', '', vat.toFixed(2), '', oc]);
    // Credit notes: a credited or voided invoice used to stay fully booked as revenue,
    // with its A/R never clearing.
    for (const cn of (o.creditNotes || [])) {
      const amt = +cn.amount || 0;
      if (!(amt > 0)) continue;
      const cnDate = (cn.date || cn.at || o.date || '').slice(0, 10);
      rows.push([cnDate, cn.id || o.id, 'Credit Note', escapeHtml(cn.reason || 'Credit note'), 'Revenue', amt.toFixed(2), '', '', oc]);
      rows.push([cnDate, cn.id || o.id, 'Credit Note', escapeHtml(cn.reason || 'Credit note'), 'Accounts Receivable', '', amt.toFixed(2), '', oc]);
    }
    // Payment entries
    if (o.paidAmount > 0) {
      rows.push([o.paidAt?.split('T')[0]||o.date||'', o.id, 'Payment', `Payment for ${escapeHtml(o.id)}`, 'Cash / Bank', (+o.paidAmount||0).toFixed(2), '', '', oc]);
      rows.push([o.paidAt?.split('T')[0]||o.date||'', o.id, 'Payment', `Payment for ${escapeHtml(o.id)}`, 'Accounts Receivable', '', (+o.paidAmount||0).toFixed(2), '', oc]);
    }
    if ((+o.giftCardDiscount || 0) > 0) {
      // Clear the gift-card-settled portion from A/R against the gift-card liability,
      // otherwise the exported ledger leaves that portion open forever.
      const gd = (+o.giftCardDiscount).toFixed(2);
      rows.push([o.paidAt?.split('T')[0]||o.date||'', o.id, 'Payment', `Gift card redeemed for ${escapeHtml(o.id)}`, 'Gift Card Liability', gd, '', '', oc]);
      rows.push([o.paidAt?.split('T')[0]||o.date||'', o.id, 'Payment', `Gift card redeemed for ${escapeHtml(o.id)}`, 'Accounts Receivable', '', gd, '', oc]);
    }
  });

  // Expense entries
  expenses.forEach(e => {
    rows.push([e.date||'', e.id||'', 'Expense', escapeHtml(e.note||e.category||'Expense'), `Expense: ${escapeHtml(e.category||'Other')}`, (+e.amount||0).toFixed(2), '', '', cur]);
    rows.push([e.date||'', e.id||'', 'Expense', escapeHtml(e.note||e.category||'Expense'), 'Cash / Bank', '', (+e.amount||0).toFixed(2), '', cur]);
  });

  downloadBlob(new Blob([rows.map(r => r.map(csvEsc).join(',')).join('\n')], { type: 'text/csv' }), 'khayt-accounting-journal.csv');
  toast(t('notify.journal_exported'), 'success');
}

/* ============================================================
   Round 12 — Feature 9: Saved filter presets
   ============================================================ */

/* ============================================================
   Round 12 — Feature 10: Per-job internal comment thread
   ============================================================ */
function renderOrderComments(orderId) {
  const el = $('#orderCommentsSection');
  if (!el) return;
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const comments = order.comments || [];
  const opName = settings.activeOperatorId
    ? (operators.find(op => op.id === settings.activeOperatorId)?.name || t('comments.operator'))
    : (shopName() || t('comments.admin'));

  el.innerHTML = `
    <div id="commentFeed" style="max-height:260px;overflow-y:auto;margin-bottom:12px;display:flex;flex-direction:column;gap:8px;">
      ${comments.length === 0 ? `<p style="color:var(--text-muted);font-size:12.5px;margin:0;">${escapeHtml(t('comments.none'))}</p>` :
        comments.map(c => `
          <div style="background:var(--bg-elev);border-radius:var(--radius);padding:8px 12px;border-inline-start:3px solid var(--primary);">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px;">
              <span style="font-size:12px;font-weight:600;color:var(--primary);">${escapeHtml(c.authorName||'—')}</span>
              <span style="font-size:11px;color:var(--text-muted);">${new Date(c.createdAt).toLocaleString()}</span>
            </div>
            <p style="margin:0;font-size:13px;white-space:pre-wrap;">${escapeHtml(c.text)}</p>
          </div>`).join('')
      }
    </div>
    <div style="display:flex;gap:8px;align-items:flex-end;">
      <textarea id="commentInput" rows="2" placeholder="${escapeHtml(t('comments.placeholder'))}" style="flex:1;resize:vertical;font-size:13px;"></textarea>
      <button class="btn primary" id="btnPostComment">${escapeHtml(t('comments.post'))}</button>
    </div>`;

  // Auto-scroll to bottom
  const feed = el.querySelector('#commentFeed');
  if (feed) feed.scrollTop = feed.scrollHeight;

  el.querySelector('#btnPostComment')?.addEventListener('click', () => {
    const text = el.querySelector('#commentInput')?.value?.trim();
    if (!text) return;
    if (!order.comments) order.comments = [];
    order.comments.push({
      id: Date.now().toString(36),
      authorName: opName,
      text,
      createdAt: new Date().toISOString(),
    });
    saveAll();
    renderOrderComments(orderId);
  });
}

/* ============================================================
   Feature 7: Shareable order status page (local HTML export)
   ============================================================ */
async function exportOrderStatusPage(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  ensureTrackingToken(order);
  const bizName = shopField('biz') || 'Khayt';
  const accentColor = safeCssColor(settings.invAccentColor, '#5E2E14');

  // qc and delivered were missing here too, and the fallback prints the raw key
  // — so a customer read "qc" and "delivered" as the status of their order.
  const STATUS_LABELS = {
    quote:     'Quote',
    pending:   'Pending',
    on_hold:   'On Hold',
    printing:  'Printing',
    post:      'Post-Processing',
    qc:        'Final Checks',
    completed: 'Completed',
    delivered: 'Delivered',
  };

  // One shared progress map — see lib/order-progress.js. This used to be
  // STATUS_ORDER.indexOf(order.status), and `qc` and `delivered` were not in
  // that list: indexOf returned -1, every step compared false, and a customer
  // who had ALREADY RECEIVED their print saw a tracker with nothing reached.
  const curIdx = KhaytOrderProgress.progressIndex(order.status);
  const stepsHtml = ['Quote', 'Pending', 'Printing', 'Post-Processing', 'Completed']
    .map((lbl, i) => {
      const stepStatus = KhaytOrderProgress.STEPS[i];
      const done    = KhaytOrderProgress.stepReached(order.status, i);
      const current = curIdx === i;
      return `<div style="display:flex;flex-direction:column;align-items:center;flex:1;">
        <div style="width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:16px;font-weight:700;
          background:${done ? accentColor : '#e5e7eb'};color:${done ? '#fff' : '#9ca3af'};
          ${current ? 'box-shadow:0 0 0 4px ' + accentColor + '33;' : ''}">
          ${done ? '✓' : (i + 1)}
        </div>
        <div style="font-size:11px;margin-top:6px;text-align:center;color:${done ? '#111827' : '#9ca3af'};font-weight:${current ? '700' : '400'};">${lbl}</div>
      </div>`;
    });
  const connectors = stepsHtml.map((s, i) => i < stepsHtml.length - 1
    ? s + `<div style="flex:0 0 24px;height:2px;background:${curIdx > i ? accentColor : '#e5e7eb'};margin-top:15px;"></div>`
    : s
  ).join('');

  const isReady = KhaytOrderStatus.isFinished(order);
  const msg = isReady
    ? 'Your order is ready for pickup / delivery!'
    : order.status === 'on_hold'
      ? `Your order is temporarily on hold.${order.holdReason ? ' Reason: ' + escapeHtml(order.holdReason) : ''}`
      : 'Your order is being processed. We\'ll notify you when it\'s ready.';

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Order Status — ${escapeHtml(order.id)}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f9fafb; color: #111827; padding: 24px 16px; }
    .card { background: #fff; border-radius: 16px; box-shadow: 0 2px 16px rgba(0,0,0,0.08); max-width: 480px; margin: 0 auto; overflow: hidden; }
    .header { background: ${accentColor}; color: #fff; padding: 24px; }
    .header h1 { font-size: 22px; font-weight: 700; }
    .header p { font-size: 13px; opacity: 0.8; margin-top: 4px; }
    .body { padding: 24px; }
    .info-row { display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid #f3f4f6; font-size: 14px; }
    .info-row:last-child { border-bottom: none; }
    .info-label { color: #6b7280; }
    .info-value { font-weight: 600; }
    .stepper { display: flex; align-items: flex-start; margin: 24px 0; }
    .message { background: ${isReady ? '#d1fae5' : '#fffbeb'}; border-left: 4px solid ${isReady ? '#10b981' : '#f59e0b'}; padding: 14px 16px; border-radius: 8px; margin-top: 16px; font-size: 14px; color: #374151; }
    .footer { text-align: center; padding: 16px 24px; background: #f9fafb; font-size: 12px; color: #9ca3af; border-top: 1px solid #f3f4f6; }
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <h1>${escapeHtml(bizName)}</h1>
      <p>Order Status Update</p>
    </div>
    <div class="body">
      <div class="stepper">${connectors}</div>
      <div class="info-row"><span class="info-label">Order #</span><span class="info-value">${escapeHtml(order.id)}</span></div>
      <div class="info-row"><span class="info-label">Project</span><span class="info-value">${escapeHtml(order.project || '—')}</span></div>
      <div class="info-row"><span class="info-label">Status</span><span class="info-value">${escapeHtml(STATUS_LABELS[order.status] || order.status)}</span></div>
      ${order.dueDate ? `<div class="info-row"><span class="info-label">Estimated completion</span><span class="info-value">${escapeHtml(order.dueDate)}</span></div>` : ''}
      <div class="message">${msg}</div>
    </div>
    <div class="footer">Generated by ${escapeHtml(bizName)} · ${new Date().toLocaleDateString(localeTag())}</div>
  </div>
</body>
</html>`;

  if (window.hubAPI?.saveHtml) {
    await window.hubAPI.saveHtml(html, `order-status-${order.id}.html`);
    toast(t('ord.status_page_saved'), 'success');
  } else {
    // Fallback: download as blob
    downloadBlob(new Blob([html], { type: 'text/html;charset=utf-8' }), `order-status-${order.id}.html`);
    toast(t('ord.status_page_saved'), 'success');
  }
}

/* ============================================================
   New 8-pack Feature 6: Split order across machines
   ============================================================ */

/* ============================================================
   New 8-pack Feature 8: Auto-export status page on status change
   ============================================================ */
async function autoExportStatusPage(order) {
  if (!order || !order.clientId) return;
  if (!window.hubAPI?.writeStatusPage) return;
  try {
    // Build the same HTML as exportOrderStatusPage but don't open it
    const bizName = shopField('biz') || 'Khayt';
    const accentColor = safeCssColor(settings.invAccentColor, '#5E2E14');
    // Same shared map as exportOrderStatusPage — see lib/order-progress.js.
    const curIdx = KhaytOrderProgress.progressIndex(order.status);
    const stepsHtml = ['Quote', 'Pending', 'Printing', 'Post-Processing', 'Completed']
      .map((lbl, i) => {
        const stepStatus = KhaytOrderProgress.STEPS[i];
        const done    = KhaytOrderProgress.stepReached(order.status, i);
        const current = curIdx === i;
        return `<div style="display:flex;flex-direction:column;align-items:center;flex:1;">
          <div style="width:32px;height:32px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:16px;font-weight:700;
            background:${done ? accentColor : '#e5e7eb'};color:${done ? '#fff' : '#9ca3af'};
            ${current ? 'box-shadow:0 0 0 4px ' + accentColor + '33;' : ''}">
            ${done ? '✓' : (i + 1)}
          </div>
          <div style="font-size:11px;margin-top:6px;text-align:center;color:${done ? '#111827' : '#9ca3af'};font-weight:${current ? '700' : '400'};">${lbl}</div>
        </div>`;
      });
    const connectors = stepsHtml.map((s, i) => i < stepsHtml.length - 1
      ? s + `<div style="flex:0 0 24px;height:2px;background:${curIdx > i ? accentColor : '#e5e7eb'};margin-top:15px;"></div>`
      : s
    ).join('');
    const isReady = KhaytOrderStatus.isFinished(order);
    const msg = isReady
      ? 'Your order is ready for pickup / delivery!'
      : order.status === 'on_hold'
        ? `Your order is temporarily on hold.${order.holdReason ? ' Reason: ' + escapeHtml(order.holdReason) : ''}`
        : 'Your order is being processed. We\'ll notify you when it\'s ready.';
    const html = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Order Status — ${escapeHtml(order.id)}</title>
<style>* { box-sizing: border-box; margin: 0; padding: 0; }body { font-family: -apple-system, sans-serif; background: #f9fafb; color: #111827; padding: 24px 16px; }.card { background: #fff; border-radius: 16px; box-shadow: 0 2px 16px rgba(0,0,0,0.08); max-width: 480px; margin: 0 auto; overflow: hidden; }.header { background: ${accentColor}; color: #fff; padding: 24px; }.header h1 { font-size: 22px; font-weight: 700; }.body { padding: 24px; }.info-row { display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid #f3f4f6; font-size: 14px; }.info-label { color: #6b7280; }.info-value { font-weight: 600; }.stepper { display: flex; align-items: flex-start; margin: 24px 0; }.message { background: ${isReady ? '#d1fae5' : '#fffbeb'}; border-left: 4px solid ${isReady ? '#10b981' : '#f59e0b'}; padding: 14px 16px; border-radius: 8px; margin-top: 16px; font-size: 14px; color: #374151; }.footer { text-align: center; padding: 16px 24px; background: #f9fafb; font-size: 12px; color: #9ca3af; border-top: 1px solid #f3f4f6; }</style></head><body>
<div class="card"><div class="header"><h1>${escapeHtml(bizName)}</h1><p>Order Status Update</p></div>
<div class="body"><div class="stepper">${connectors}</div>
<div class="info-row"><span class="info-label">Order #</span><span class="info-value">${escapeHtml(order.id)}</span></div>
<div class="info-row"><span class="info-label">Project</span><span class="info-value">${escapeHtml(order.project || '—')}</span></div>
<div class="info-row"><span class="info-label">Status</span><span class="info-value">${escapeHtml(order.status)}</span></div>
${order.dueDate ? `<div class="info-row"><span class="info-label">Due</span><span class="info-value">${escapeHtml(order.dueDate)}</span></div>` : ''}
<div class="message">${escapeHtml(msg)}</div></div>
<div class="footer">Generated by ${escapeHtml(bizName)} · ${new Date().toLocaleDateString(localeTag())}</div></div></body></html>`;
    const filePath = await window.hubAPI.writeStatusPage(html, order.id);
    return filePath || null;
  } catch (e) { console.error('autoExportStatusPage error', e); return null; }
}

async function openSavedStatusPage(orderId) {
  if (!window.hubAPI?.writeStatusPage || !window.hubAPI?.openFile) return;
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const filePath = await autoExportStatusPage(order);
  if (filePath) {
    await window.hubAPI.openFile(filePath);
  }
  toast(t('ord.status_page_open'), 'success');
}

// Feature G1: Customer Portal QR modal (LAN) + Khayt Cloud public status link.
async function openCustomerPortalModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;

  const cloudOn = !!(settings.cloud?.enabled && settings.cloud?.shopId);
  const cloudBtn = cloudOn
    ? `<button class="btn small" id="portalCloudPublish">${escapeHtml(t('ord.portal_cloud_publish') || '☁ Publish public link (Khayt Cloud)')}</button>`
    : '';
  const wireCloud = (modal) => modal.querySelector('#portalCloudPublish')
    ?.addEventListener('click', () => publishOrderToCloudPortal(orderId)); // replaces this modal

  const lanInfo = await window.hubAPI?.getLanUrl?.();
  if (!lanInfo?.ok) {
    openFormModal({
      title: t('ord.portal_qr_title') || 'Customer Portal QR',
      noSave: true,
      sizeLg: false,
      bodyHtml: `
        <div style="text-align:center;padding:16px 0;">
          <div style="font-size:32px;margin-bottom:12px;">${cloudOn ? '☁' : '⚠'}</div>
          <p style="${cloudOn ? '' : 'color:var(--warning);'}font-weight:600;margin-bottom:8px;">${escapeHtml(t('lan.not_running') || 'LAN server is not running')}</p>
          <p style="font-size:13px;color:var(--text-muted);margin-bottom:16px;">${escapeHtml(cloudOn ? (t('ord.portal_cloud_hint') || 'Publish a public status link via Khayt Cloud — works anywhere, no LAN needed.') : (t('lan.start_hint') || 'Start the LAN server in Settings first'))}</p>
          <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;">
            <button type="button" class="btn ${cloudOn ? '' : 'primary'}" data-act="open-settings-from-modal">${escapeHtml(t('nav.settings') || 'Go to Settings')}</button>
            ${cloudBtn}
          </div>
        </div>`,
      onMount(modal) { wireCloud(modal); },
    });
    return;
  }

  const url = buildLanOrderTrackingUrl(lanInfo.url, order);
  let qrHtml = '';
  try {
    const qrDataUrl = await window.hubAPI.generateQR(url, { width: 200, dataUrl: true });
    if (qrDataUrl) qrHtml = `<img src="${escapeHtml(qrDataUrl)}" alt="QR" style="width:200px;height:200px;display:block;margin:0 auto;">`;
  } catch(e) { /* silent */ }

  openFormModal({
    title: t('ord.portal_qr_title') || 'Customer Portal QR',
    noSave: true,
    sizeLg: false,
    bodyHtml: `
      <div style="text-align:center;padding:12px 0;">
        ${qrHtml || '<p style="color:var(--text-muted);">QR unavailable</p>'}
        <p style="font-size:12px;color:var(--text-muted);margin:12px 0 6px;word-break:break-all;">${escapeHtml(url)}</p>
        <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-top:8px;">
          <button class="btn small" id="portalQrCopy">${escapeHtml(t('common.copy') || 'Copy URL')}</button>
          <button class="btn small primary" id="portalQrWa">${escapeHtml(t('inv.share_whatsapp') || 'Share WhatsApp')}</button>
          ${cloudBtn}
        </div>
        ${cloudOn ? `<p style="font-size:11px;color:var(--text-muted);margin-top:8px;">${escapeHtml(t('ord.portal_cloud_note') || 'The cloud link works outside your network.')}</p>` : ''}
      </div>`,
    onMount(modal) {
      modal.querySelector('#portalQrCopy')?.addEventListener('click', async () => {
        if (await copyText(url)) toast(t('common.copied') || 'Copied!', 'success');
        else toast(url, 'info', 6000);
      });
      modal.querySelector('#portalQrWa')?.addEventListener('click', async () => {
        const waMsg = `${t('ord.portal_track_msg') || 'Track your order'}: ${url}`;
        const cl = order.clientId ? clients.find(c => c.id === order.clientId) : null;
        const phone = cl?.phone || '';
        if (window.hubAPI?.shareWhatsApp) {
          await window.hubAPI.shareWhatsApp({ phone, message: waMsg, pdfPath: null });
        } else {
          const waUrl = `https://wa.me/?text=${encodeURIComponent(waMsg)}`;
          window.open(waUrl, '_blank');
        }
      });
      wireCloud(modal);
    },
  });
}

const CLOUD_PORTAL_STATUS_LABELS = {
  quote: 'Quote', pending: 'Pending', on_hold: 'On hold',
  printing: 'Printing', post: 'Post-processing', qc: 'Final checks',
  completed: 'Completed', delivered: 'Delivered',
};

/** AI assist: draft a customer message for an order (status update, quote
 *  follow-up, payment reminder, …). Uses the existing aiExtract IPC + the
 *  owner's Anthropic key. The draft is always editable before sending. */
async function aiDraftReply(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const ai = settings.ai || {};
  if (!ai.apiKey || !window.KhaytAiPrivacy.isFeatureEnabled(ai, 'reply')) {
    toast(t('ai.reply_need_key') || 'Enable AI assist (with your API key) in Settings first', 'error');
    return;
  }
  if (typeof KhaytAiReply === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const client = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
  const intents = KhaytAiReply.REPLY_INTENTS;

  const generate = async (intent, extra, statusEl) => {
    statusEl.textContent = t('ai.reply_drafting') || 'Drafting…';
    try {
      const system = KhaytAiReply.buildReplySystem({ shopName: shopField('biz') || 'Khayt', lang: settings.lang });
      const request = KhaytAiReply.buildReplyRequest({ order, client, intent, currency: cur, extra });
      const r = await khaytAiExtract({ apiKey: ai.apiKey, model: ai.model || 'claude-opus-5', task: 'reply', system, request, schema: KhaytAiReply.REPLY_SCHEMA });
      if (!r || !r.ok || !r.draft) return { ok: false, error: (r && r.error) || 'AI request failed' };
      return { ok: true, message: KhaytAiReply.pickMessage(r.draft) };
    } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
  };

  const intentOpts = intents.map(i =>
    `<option value="${escapeHtml(i.id)}">${escapeHtml(t('ai.reply_intent_' + i.id) || i.label)}</option>`).join('');

  openFormModal({
    title: t('ai.reply_title') || 'Draft message with AI',
    saveLabel: t('ai.reply_generate') || 'Generate',
    bodyHtml: `
      <label>${escapeHtml(t('ai.reply_intent') || 'What kind of message?')}</label>
      <select id="arIntent">${intentOpts}</select>
      <label style="margin-top:8px;">${escapeHtml(t('ai.reply_extra') || 'Extra note (optional)')}</label>
      <input type="text" id="arExtra" placeholder="${escapeHtml(t('ai.reply_extra_ph') || 'e.g. mention free delivery this week')}">
      <p id="arStatus" style="font-size:12px;color:var(--text-muted);min-height:14px;margin:8px 0 0;"></p>
      <textarea id="arDraft" rows="5" style="width:100%;margin-top:6px;display:none;"></textarea>
      <div id="arSend" style="display:none;gap:8px;flex-wrap:wrap;margin-top:8px;">
        <button type="button" class="btn small" id="arCopy">${escapeHtml(t('common.copy') || 'Copy')}</button>
        <button type="button" class="btn small primary" id="arWa">${escapeHtml(t('inv.share_whatsapp') || 'Share WhatsApp')}</button>
        ${client?.email ? `<button type="button" class="btn small" id="arEmail">${escapeHtml(t('ai.reply_email') || 'Email')}</button>` : ''}
      </div>`,
    onMount(modal) {
      const draftEl = modal.querySelector('#arDraft');
      modal.querySelector('#arCopy')?.addEventListener('click', async () => {
        if (await copyText(draftEl.value)) toast(t('common.copied') || 'Copied!', 'success');
        else toast(draftEl.value, 'info', 6000);
      });
      modal.querySelector('#arWa')?.addEventListener('click', async () => {
        const msg = draftEl.value;
        if (window.hubAPI?.shareWhatsApp) await window.hubAPI.shareWhatsApp({ phone: client?.phone || '', message: msg, pdfPath: null });
        else window.open(`https://wa.me/?text=${encodeURIComponent(msg)}`, '_blank');
      });
      modal.querySelector('#arEmail')?.addEventListener('click', () => {
        const subj = (shopField('biz') || 'Khayt') + ' — ' + (order.project || order.id);
        // encodeURIComponent the ADDRESS too. A client's email is not the shop's
        // text: the LAN intake form accepts one from anyone who can reach it and
        // stores it after nothing but trim+slice(500). An address ending
        // `...?bcc=someone@else` injected a header into the shop's own reply and
        // copied it to a stranger, in a compose window that looked normal.
        window.hubAPI?.openExternal?.(
          `mailto:${encodeURIComponent(client.email || '')}?subject=${encodeURIComponent(subj)}&body=${encodeURIComponent(draftEl.value)}`);
      });
    },
    // "Generate" fills the draft area for editing instead of closing.
    async onSave(modal) {
      const intent = modal.querySelector('#arIntent').value;
      const extra = modal.querySelector('#arExtra').value.trim();
      const status = modal.querySelector('#arStatus');
      const draftEl = modal.querySelector('#arDraft');
      const r = await generate(intent, extra, status);
      if (!r.ok) { status.textContent = '✗ ' + r.error; status.style.color = 'var(--danger)'; return false; }
      status.textContent = t('ai.reply_review') || 'Review & edit, then send:';
      status.style.color = 'var(--text-muted)';
      draftEl.value = r.message; draftEl.style.display = 'block';
      modal.querySelector('#arSend').style.display = 'flex';
      return false; // keep the modal open for editing/sending
    },
  });
}

/** Publish an order's status to Khayt Cloud as a public link (owner-curated,
 *  plaintext — only what's shown below; the rest of your data stays encrypted). */
/** Build the owner-curated portal payload for an order (plaintext, minimal).
 *
 *  The payload is `lib/portal-refresh.js`, so the Mac app publishes the same
 *  words to the same link instead of a second app's idea of them. What stays
 *  here is only what a host knows: the shop's name and address in the language
 *  it reads, and the five timeline words. */
function buildPortalPayload(order) {
  return KhaytPortalRefresh.payloadFor(order, {
    settings, clients,
    shopName: shopField('biz') || 'Khayt',
    shopAddress: shopField('addr') || '',
    stages: [
      t('track.received') || 'Received',
      t('track.printing') || 'Printing',
      t('track.finishing') || 'Finishing',
      t('track.done') || 'Done',
      t('track.ready') || 'Ready for pickup',
    ],
  });
}

/** Keep a published portal link current: re-publish when the order changes
 *  (e.g. status advances). No-op unless the order is published + cloud is on.
 *  Fire-and-forget; never blocks the caller. */
function republishPortalIfPublished(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  // The guards are `lib/portal-refresh.js`'s now — published at all, a token to
  // publish under, cloud on with a shop id, and a portal trial that has not run
  // out. They were written out here AND in `order-status.outboundFor`, which
  // never checked the trial, so the two disagreed about whether a move on a
  // published job reached anybody. One rule, asked by both.
  //
  // Still silent on a no: this fires on every status change, and a toast per
  // kanban drag would be its own bug.
  const req = KhaytPortalRefresh.requestFor(order, {
    settings, clients,
    shopName: shopField('biz') || 'Khayt',
    shopAddress: shopField('addr') || '',
    stages: [
      t('track.received') || 'Received',
      t('track.printing') || 'Printing',
      t('track.finishing') || 'Finishing',
      t('track.done') || 'Done',
      t('track.ready') || 'Ready for pickup',
    ],
    now: Date.now(),
  });
  if (!req) return;
  const c = settings.cloud || {};
  Promise.resolve(window.hubAPI.cloudPublish({
    url: c.url, shopId: c.shopId, token: c.token,
    pubToken: req.pubToken, kind: req.kind, payload: req.payload,
    customerEmail: req.customerEmail,
  })).catch((e) => console.error('portal auto-refresh:', e));
}

/** Owner view + reply for an order's portal message thread (cloud). */
async function openPortalMessages(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const c = settings.cloud || {};
  if (!(c.enabled && c.shopId) || !order.trackingToken) { toast(t('pm.need_publish') || 'Publish this order to the portal first', 'info'); return; }

  const render = async (modal) => {
    const body = modal.querySelector('#pmBody');
    let msgs = [], err = '';
    try {
      const r = await window.hubAPI.cloudPortalMessages({ url: c.url, shopId: c.shopId, token: order.trackingToken, authToken: c.token });
      if (r && r.ok) msgs = r.messages || [];
      // This read is authenticated now, so it can fail for a reason worth
      // acting on — a token that no longer works. Swallowing that showed the
      // same "No messages yet." as a thread nobody has written in.
      else err = (r && r.error) || (t('pm.load_failed') || 'Could not load messages');
    } catch (e) { err = String((e && e.message) || e); }
    const emptyLine = err
      ? `<div style="color:var(--danger);font-size:13px;">${escapeHtml(err)}</div>`
      : `<div style="color:var(--text-muted);font-size:13px;">${escapeHtml(t('pm.empty') || 'No messages yet.')}</div>`;
    const thread = msgs.length ? msgs.map(m => {
      const mine = m.from === 'shop';
      return `<div style="align-self:${mine ? 'flex-end' : 'flex-start'};max-width:80%;background:${mine ? 'var(--primary)' : 'var(--bg-elev)'};color:${mine ? '#fff' : 'var(--text)'};border:1px solid var(--border-soft);border-radius:12px;padding:7px 11px;font-size:13px;">${escapeHtml(m.text)}</div>`;
    }).join('') : emptyLine;
    body.innerHTML = `
      <div style="display:flex;flex-direction:column;gap:8px;max-height:300px;overflow-y:auto;margin-bottom:12px;">${thread}</div>
      <div style="display:flex;gap:8px;">
        <input id="pmText" type="text" maxlength="2000" placeholder="${escapeHtml(t('pm.reply_ph') || 'Write a reply…')}" style="flex:1;">
        <button id="pmSend" class="btn small primary">${escapeHtml(t('pm.send') || 'Send')}</button>
      </div>`;
    const send = async () => {
      const txt = body.querySelector('#pmText').value.trim();
      if (!txt) return;
      const r = await window.hubAPI.cloudPortalReply({ url: c.url, shopId: c.shopId, token: order.trackingToken, authToken: c.token, text: txt });
      if (r && r.ok) render(modal); else toast((r && r.error) || 'Failed', 'error');
    };
    body.querySelector('#pmSend').addEventListener('click', send);
    body.querySelector('#pmText').addEventListener('keydown', (e) => { if (e.key === 'Enter') send(); });
  };

  openFormModal({
    title: '💬 ' + (t('pm.title') || 'Portal messages') + ' · ' + escapeHtml(order.id),
    noSave: true,
    bodyHtml: `<div id="pmBody"><p style="color:var(--text-muted);">${escapeHtml(t('common.loading') || '…')}</p></div>`,
    onMount(modal) { render(modal); },
  });
}

/**
 * Where this shop stands on the free tier's portal trial.
 *
 * Guarded on the global because integrations.js is shared with the other
 * flavor, which has no commerce and loads no plan modules — same pattern as
 * KhaytTiers in build.js. A missing module means "no trial to enforce", which
 * is the safe direction: it can only ever leave the portal working.
 */
function portalTrialNow() {
  if (typeof KhaytPortalTrial === 'undefined') return null;
  const Trial = KhaytPortalTrial;
  const c = settings.cloud || {};
  const betaFree = (typeof KhaytCloudPlans !== 'undefined') ? KhaytCloudPlans.isBetaFree() : true;
  return Trial.portalTrialState({
    betaFree,
    subscribed: c.planActive === true,
    startedAt: c.portalTrialStartedAt || null,
    now: Date.now(),
  });
}

/**
 * Gate + clock start for publishing to the portal.
 *
 * Returns false and explains itself when the trial is over. It also STARTS the
 * clock, because first publish is the moment the trial is actually about — a
 * shop that connects the cloud and never publishes has not used the thing it
 * would be paying for, and charging its window down would be dishonest.
 *
 * During beta this cannot refuse and cannot start a clock; see lib/portal-trial.js.
 */
function portalTrialAllows() {
  const s = portalTrialNow();
  if (!s) return true;
  if (!s.available) {
    toast((t('trial.portal_over') || 'Your 30-day portal trial has ended — subscribe to keep publishing links'), 'error');
    return false;
  }
  const startAt = KhaytPortalTrial.trialStartOnPublish({
    betaFree: (typeof KhaytCloudPlans !== 'undefined') ? KhaytCloudPlans.isBetaFree() : true,
    subscribed: (settings.cloud || {}).planActive === true,
    startedAt: (settings.cloud || {}).portalTrialStartedAt || null,
    now: Date.now(),
  });
  if (startAt) {
    settings.cloud = settings.cloud || {};
    settings.cloud.portalTrialStartedAt = startAt;
    saveAll();
  }
  return true;
}

async function publishOrderToCloudPortal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;
  const c = settings.cloud || {};
  if (!(c.enabled && c.shopId)) { toast(t('cloud.portal_need_connect') || 'Connect Khayt Cloud first (Settings)', 'error'); return; }
  const pubToken = order.trackingToken;
  if (!pubToken) { toast(t('cloud.portal_no_token') || 'This order has no tracking token yet', 'error'); return; }
  if (!portalTrialAllows()) return;

  // For a quote, first let the owner attach an optional deposit + their own pay link.
  if (order.status === 'quote' && !order._skipDepositPrompt) {
    openFormModal({
      title: t('cloud.portal_quote_title') || 'Quote approval link',
      saveLabel: t('cloud.deposit_publish') || 'Publish link',
      bodyHtml: `
        <label>${escapeHtml(t('cloud.deposit_amount') || 'Deposit to request (optional)')}</label>
        <input id="qpDep" type="number" min="0" step="0.01" value="${escapeHtml(order.cloudDeposit != null ? order.cloudDeposit : '')}">
        <label style="margin-top:8px;">${escapeHtml(t('cloud.deposit_payurl') || 'Payment link (optional)')}</label>
        <input id="qpPay" type="url" placeholder="https://… your provider's pay link" value="${escapeHtml(order.cloudPayUrl || settings.cloud?.lastPayUrl || '')}">
        <p style="font-size:11.5px;color:var(--text-muted);margin-top:6px;">${escapeHtml(t('cloud.deposit_hint') || 'Paste a payment link from any provider. The customer pays there; "paid" updates via your provider webhook. Leave blank for no deposit.')}</p>`,
      onSave: async (modal) => {
        const dep = modal.querySelector('#qpDep').value.trim();
        const payUrl = modal.querySelector('#qpPay').value.trim();
        order.cloudDeposit = dep ? +dep : null;
        order.cloudPayUrl = payUrl || null;
        if (payUrl) { settings.cloud = settings.cloud || {}; settings.cloud.lastPayUrl = payUrl; }
        saveAll();
        order._skipDepositPrompt = true;
        await publishOrderToCloudPortal(orderId); // re-enter; now skips the prompt
        delete order._skipDepositPrompt;
      },
    });
    return;
  }

  const { kind, payload, customerEmail } = buildPortalPayload(order);
  // The dialog below speaks of a quote or an order in several places; the
  // module already decided which this is, so read it from there rather than
  // testing the status a second time.
  const isQuote = kind === 'quote';

  const r = await window.hubAPI.cloudPublish({ url: c.url, shopId: c.shopId, token: c.token, pubToken, kind, payload, customerEmail });
  if (!r.ok) { toast('✗ ' + (r.error || 'publish failed'), 'error'); return; }
  order.cloudPublished = true; saveAll(); // track so status changes auto-refresh the link

  const portalUrl = String(c.url || '').replace(/\/$/, '') + '/p/' + pubToken;
  let qrHtml = '';
  try {
    const qr = await window.hubAPI.generateQR(portalUrl, { width: 200, dataUrl: true });
    if (qr) qrHtml = `<img src="${escapeHtml(qr)}" alt="QR" style="width:200px;height:200px;display:block;margin:0 auto;">`;
  } catch (e) { /* silent */ }

  openFormModal({
    title: isQuote ? (t('cloud.portal_quote_title') || 'Quote approval link') : (t('cloud.portal_published_title') || 'Public status link'),
    noSave: true,
    sizeLg: false,
    bodyHtml: `
      <div style="text-align:center;padding:12px 0;">
        ${qrHtml}
        <p style="font-size:12px;color:var(--text-muted);margin:12px 0 6px;word-break:break-all;">${escapeHtml(portalUrl)}</p>
        <p style="font-size:11.5px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(isQuote ? (t('cloud.portal_quote_note') || 'The customer can Approve/Decline. Shares: shop name, ref, amount.') : (t('cloud.portal_shared_note') || 'Shares only: shop name, order #, status, due date. Updates when you re-publish.'))}</p>
        <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;">
          <button class="btn small" id="cpCopy">${escapeHtml(t('common.copy') || 'Copy URL')}</button>
          <button class="btn small primary" id="cpWa">${escapeHtml(t('inv.share_whatsapp') || 'Share WhatsApp')}</button>
          ${isQuote ? `<button class="btn small" id="cpCheck">${escapeHtml(t('cloud.portal_check') || 'Check response')}</button>` : ''}
          <button class="btn small danger" id="cpUnpub">${escapeHtml(t('cloud.portal_unpublish') || 'Unpublish')}</button>
        </div>
        <p id="cpResp" style="font-size:13px;margin-top:10px;min-height:16px;"></p>
      </div>`,
    onMount(modal) {
      modal.querySelector('#cpCopy')?.addEventListener('click', async () => {
        if (await copyText(portalUrl)) toast(t('common.copied') || 'Copied!', 'success');
        else toast(portalUrl, 'info', 6000);
      });
      modal.querySelector('#cpWa')?.addEventListener('click', async () => {
        const waMsg = `${(isQuote ? (t('cloud.portal_quote_msg') || 'Please review your quote') : (t('ord.portal_track_msg') || 'Track your order'))}: ${portalUrl}`;
        const cl = order.clientId ? clients.find(x => x.id === order.clientId) : null;
        if (window.hubAPI?.shareWhatsApp) await window.hubAPI.shareWhatsApp({ phone: cl?.phone || '', message: waMsg, pdfPath: null });
        else window.open(`https://wa.me/?text=${encodeURIComponent(waMsg)}`, '_blank');
      });
      modal.querySelector('#cpCheck')?.addEventListener('click', async () => {
        const resp = modal.querySelector('#cpResp');
        resp.textContent = t('cloud.portal_checking') || 'Checking…'; resp.style.color = 'var(--text-muted)';
        const lst = await window.hubAPI.cloudPublishedList({ url: c.url, shopId: c.shopId, token: c.token });
        if (!lst.ok) { resp.textContent = '✗ ' + (lst.error || 'failed'); resp.style.color = 'var(--danger)'; return; }
        const item = (lst.items || []).find(x => x.token === pubToken);
        const act = item && item.action;
        const paid = item && item.payment && item.payment.status === 'paid';
        const paidNote = paid ? ('  💰 ' + (t('cloud.portal_deposit_paid') || 'deposit paid')) : '';
        if (!act || !act.type) {
          resp.textContent = (paid ? ('✓ ' + (t('cloud.portal_deposit_paid') || 'Deposit paid')) : (t('cloud.portal_no_response') || 'No response yet'));
          resp.style.color = paid ? 'var(--success)' : 'var(--text-muted)';
          return;
        }
        const approved = act.type === 'approve';
        resp.textContent = (approved ? '✓ ' : '✗ ') + (approved ? (t('cloud.portal_approved') || 'Customer approved the quote') : (t('cloud.portal_declined') || 'Customer declined the quote')) + paidNote;
        resp.style.color = approved ? 'var(--success)' : 'var(--danger)';
        // Close the loop: an approved quote advances the order to Pending via the
        // normal status-change path (history, webhooks, re-renders all fire).
        if (approved && order.status === 'quote' && typeof updateStatus === 'function') {
          updateStatus(order.id, 'pending');
          resp.textContent = '✓ ' + (t('cloud.portal_approved_advanced') || 'Customer approved — order moved to Pending') + paidNote;
        }
      });
      modal.querySelector('#cpUnpub')?.addEventListener('click', async () => {
        const u = await window.hubAPI.cloudUnpublish({ url: c.url, shopId: c.shopId, token: c.token, pubToken });
        if (u.ok) { order.cloudPublished = false; saveAll(); toast(t('cloud.portal_unpublished') || 'Link unpublished', 'success'); }
        else toast('✗ ' + (u.error || 'failed'), 'error');
      });
    },
  });
}

async function openQuoteApprovalLinkModal(orderId) {
  const order = printLog.find(o => o.id === orderId);
  if (!order) return;

  const lanInfo = await window.hubAPI?.getLanUrl?.();
  if (!lanInfo?.ok) {
    openFormModal({
      title: t('ord.quote_approval_link_title') || 'Quote Approval Link',
      noSave: true,
      sizeLg: false,
      bodyHtml: `
        <div style="text-align:center;padding:16px 0;">
          <div style="font-size:32px;margin-bottom:12px;">⚠</div>
          <p style="color:var(--warning);font-weight:600;margin-bottom:8px;">${escapeHtml(t('lan.not_running') || 'LAN server is not running')}</p>
          <p style="font-size:13px;color:var(--text-muted);margin-bottom:16px;">${escapeHtml(t('lan.start_hint') || 'Start the LAN server in Settings first')}</p>
          <button type="button" class="btn primary" data-act="open-settings-from-modal">${escapeHtml(t('nav.settings') || 'Go to Settings')}</button>
        </div>`,
    });
    return;
  }

  const url = buildLanQuoteApprovalUrl(lanInfo.url, order);
  let qrHtml = '';
  try {
    const qrDataUrl = await window.hubAPI.generateQR(url, { width: 200, dataUrl: true });
    if (qrDataUrl) qrHtml = `<img src="${escapeHtml(qrDataUrl)}" alt="QR" style="width:200px;height:200px;display:block;margin:0 auto;">`;
  } catch (e) { /* silent */ }

  openFormModal({
    title: t('ord.quote_approval_link_title') || 'Quote Approval Link',
    noSave: true,
    sizeLg: false,
    bodyHtml: `
      <div style="text-align:center;padding:12px 0;">
        ${qrHtml || '<p style="color:var(--text-muted);">QR unavailable</p>'}
        <p style="font-size:12px;color:var(--text-muted);margin:12px 0 6px;word-break:break-all;">${escapeHtml(url)}</p>
        <div style="display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-top:8px;">
          <button class="btn small" id="quoteApprovalCopy">${escapeHtml(t('common.copy') || 'Copy URL')}</button>
          <button class="btn small primary" id="quoteApprovalWa">${escapeHtml(t('inv.share_whatsapp') || 'Share WhatsApp')}</button>
        </div>
      </div>`,
    onMount(modal) {
      modal.querySelector('#quoteApprovalCopy')?.addEventListener('click', async () => {
        if (await copyText(url)) toast(t('common.copied') || 'Copied!', 'success');
        else toast(url, 'info', 6000);
      });
      modal.querySelector('#quoteApprovalWa')?.addEventListener('click', async () => {
        const waMsg = `${t('ord.quote_approve_msg') || 'Please review and approve your quote'}: ${url}`;
        const cl = order.clientId ? clients.find(c => c.id === order.clientId) : null;
        const phone = cl?.phone || '';
        if (window.hubAPI?.shareWhatsApp) {
          await window.hubAPI.shareWhatsApp({ phone, message: waMsg, pdfPath: null });
        } else {
          window.open(`https://wa.me/?text=${encodeURIComponent(waMsg)}`, '_blank');
        }
      });
    },
  });
}

async function clearAllLogs() {
  const ok = await confirmModal(t('log.clear_q'), { danger: true });
  if (!ok) return;
  printLog = [];
  saveAll();
  renderLogs(); renderKanban(); renderAnalytics();
  toast(t('log.cleared'), 'success');
}

const CARRIER_TRACKING_URLS = {
  aramex:     n => `https://www.aramex.com/express/track?mode=0&ShipmentNumber=${n}`,
  dhl:        n => `https://www.dhl.com/en/express/tracking.html?AWB=${n}&brand=DHL`,
  fedex:      n => `https://www.fedex.com/fedextrack/?trknbr=${n}`,
  ups:        n => `https://www.ups.com/track?loc=en_US&tracknum=${n}`,
  'saudi post': n => `https://www.splonline.com.sa/en/track-your-shipment/?awb=${n}`,
  spl:        n => `https://www.splonline.com.sa/en/track-your-shipment/?awb=${n}`,
  smsa:       n => `https://www.smsaexpress.com/en/tracking?trackno=${n}`,
  dpd:        n => `https://tracking.dpd.de/status/en_US/parcel/${n}`,
  'j&t':      n => `https://www.jtexpress.sa/index/query/giftSearch.html?billcode=${n}`,
};

function getCarrierTrackingUrl(courierName, trackingNumber) {
  if (!courierName || !trackingNumber) return null;
  const key = courierName.toLowerCase().trim();
  const fn = CARRIER_TRACKING_URLS[key] ||
    Object.entries(CARRIER_TRACKING_URLS).find(([k]) => key.includes(k))?.[1];
  return fn ? fn(trackingNumber) : null;
}


/* ── Feature 10: Telegram Notification Settings ─────────────── */

function sendTelegramForOrder(order, newStatus) {
  // The message is lib/telegram-message.js's, so the Mac app says the same
  // thing — it had no way to, which is why it refused to finish a job for any
  // shop with a bot configured.
  const TG = (typeof globalThis !== 'undefined' && globalThis.KhaytTelegramMessage)
    || (() => { try { return require('../lib/telegram-message.js'); } catch (e) { return null; } })();
  if (!TG) return;
  const out = TG.forStatus(order, newStatus, { settings, fmtPrice });
  if (!out) return;
  window.hubAPI?.sendTelegram?.(out)
    .catch(e => console.warn('Telegram notify failed:', e));
}

/* ── Printer alerting ───────────────────────────────────────────
 * Diffs each printer poll against the previous snapshot (pure logic in
 * lib/printer-alerts.js) and fires the resulting alerts through the EXISTING
 * Telegram / email / webhook transports — no new transport is introduced. */
let _printerAlertState = {};
let _printerAlertPrevCache = {};

// Per-machine phase tracker for print-done/failed desktop notifications. We only
// notify on a transition OUT of a "printing" phase we actually observed, so the
// app never fires a spurious "complete" on the first poll of an idle printer.
let _printPhase = {};

/**
 * Fire a local desktop notification when a monitored printer finishes or fails a
 * print. Purely local/offline (telemetry → OS notification), opt-out via
 * settings.notifyPrintDone === false. Self-contained: derives the previous phase
 * from _printPhase rather than the alert cache, so it's robust even if the alert
 * engine isn't loaded.
 */
function notifyPrintTransitions(currCache) {
  if (typeof Notification === 'undefined') return;
  if (settings && settings.notifyPrintDone === false) return;
  const curr = currCache || {};
  Object.keys(curr).forEach((mid) => {
    const c = curr[mid];
    if (!c || c.error === undefined && !c.state && c.progress == null) return;
    const st = String(c.state || '').toLowerCase();
    const printing = /print|run|busy/i.test(st) && !/error|fault|halt/i.test(st);
    const isError = !!c.error || /error|fault|halt|attention|fail/i.test(st);
    const isDone = /finish|complete|success|done|standby/i.test(st) || (!printing && !isError && Number(c.progress) >= 99);
    const prev = _printPhase[mid];
    if (printing) { _printPhase[mid] = 'printing'; return; }
    const machine = (typeof machines !== 'undefined') ? machines.find((m) => m.id === mid) : null;
    const name = (machine && (machine.name || machine.label)) || t('notif.print_a_printer') || 'Your printer';
    const fn = c.filename ? String(c.filename).replace(/[\r\n\t]/g, ' ').slice(0, 120) : '';
    if (prev === 'printing' && isDone) {
      _printPhase[mid] = 'done';
      _firePrintNotification('✅ ' + (t('notif.print_done_title', { name }) || (name + ' — print complete')), fn);
    } else if (prev === 'printing' && isError) {
      _printPhase[mid] = 'error';
      _firePrintNotification('⚠️ ' + (t('notif.print_fail_title', { name }) || (name + ' — print failed')), fn || (c.error ? String(c.error).slice(0, 120) : ''));
    }
  });
}

function _firePrintNotification(title, body) {
  try { new Notification(title, { body: body || undefined, tag: 'hub-print-done' }); }
  catch (e) { /* notifications unavailable — non-fatal */ }
}

function dispatchPrinterAlerts(currCache) {
  // Local print-done/failed desktop notification (independent of the Telegram/
  // webhook alert engine below, and of whether it's even loaded).
  try { notifyPrintTransitions(currCache); } catch (e) { /* non-fatal */ }

  const compute = (typeof computePrinterAlerts === 'function')
    ? computePrinterAlerts
    : (window.KhaytPrinterAlerts && window.KhaytPrinterAlerts.computePrinterAlerts);
  if (!compute) return;
  let result;
  try {
    result = compute(_printerAlertPrevCache, currCache || {}, settings, Date.now(), {
      alertState: _printerAlertState,
      machines,
    });
  } catch (e) {
    console.warn('computePrinterAlerts failed:', e);
    _printerAlertPrevCache = currCache || {};
    return;
  }
  _printerAlertState = result.state;
  _printerAlertPrevCache = currCache || {};
  for (const alert of result.alerts) firePrinterAlert(alert);
}

function firePrinterAlert(alert) {
  // tgSafe: strip control chars and truncate to prevent message manipulation
  const tgSafe = s => String(s ?? '').replace(/[\r\n\t]/g, ' ').slice(0, 200);
  const icon = alert.type === 'error' ? '❌' : alert.type === 'offline' ? '📴' : '⏸';
  const message = `${icon} ${tgSafe(alert.message)}`;

  // Telegram (reuses the order-notification transport)
  const tg = settings.telegram;
  if (tg && tg.botToken && tg.chatId) {
    window.hubAPI?.sendTelegram?.({ botToken: tg.botToken, chatId: tg.chatId, message })
      .catch(e => console.warn('Telegram printer alert failed:', e));
  }

  // Webhook (reuses fireWebhook with a dedicated event name)
  fireWebhook('printer_alert', {
    machineId: alert.machineId,
    type: alert.type,
    state: alert.state,
    filename: alert.filename,
    progress: alert.progress,
    message: alert.message,
    at: new Date().toISOString(),
  });

  // Email digest recipient (reuses hub:send-email; only when an SMTP/provider is configured)
  const cfg = settings.emailConfig;
  const to = (settings.emailDigest && settings.emailDigest.recipientEmail) || settings.email;
  if (cfg && cfg.provider && cfg.provider !== 'none' && to) {
    // Renamed, not shadowed — see the note in `emailOrderToClient`. This alert
    // has thrown before sending on every printer alert since #822.
    const shop = shopName() || 'Khayt';
    const subject = `${shop} — Printer ${alert.type} alert`;
    const body = `<div style="font-family:sans-serif;max-width:500px;margin:0 auto;padding:20px;">
      <h2 style="color:#5E2E14;">${escapeHtml(shop)}</h2>
      <p>${escapeHtml(message)}</p>
    </div>`;
    window.hubAPI?.sendEmail?.({ to, subject, body, smtpConfig: cfg })
      .catch(e => console.warn('Email printer alert failed:', e));
  }
}

function checkTelegramLowStock() {
  // The conditions and the words are `lib/low-stock-alert.js` now, and WHICH
  // spools are low is `KhaytOrderDeduction.isLowStock` — the same rule the
  // shelf badges use. This function carried its own copy of both: a `< 200`
  // threshold read straight from settings, which is not what `isLowStock`
  // decides, so a spool could be badged low on the shelf and never warned
  // about (or warned about and not badged).
  const low = (inventory || []).filter(s => KhaytOrderDeduction.isLowStock(s, settings));
  const warning = KhaytLowStockAlert.wouldWarn({ settings, low });
  if (!warning.send) return;
  window.hubAPI?.sendTelegram?.({
    botToken: warning.botToken, chatId: warning.chatId, message: warning.message,
  }).catch(e => console.warn('Telegram low-stock notify failed:', e));
}

/* ── Feature 11: iCal Export ────────────────────────────────── */
async function exportIcalFeed() {
  const lanUrl = await window.hubAPI?.getLanUrl?.().catch(() => null);
  if (!lanUrl?.ok) { toast(t('ical.need_server') || 'Start LAN server first to use iCal', 'error'); return; }
  if (!lanUrl.calendarToken) {
    toast(t('ical.need_token') || 'Restart the LAN server to generate a calendar link', 'warning');
    return;
  }
  const icalUrl = `${lanUrl.url}/calendar.ics?token=${encodeURIComponent(lanUrl.calendarToken)}`;
  await copyAndToast(icalUrl, t('ical.copied') || 'Calendar subscription link copied');
  window.hubAPI?.openExternal?.(icalUrl);
}

/* ── Feature 12: Referral Attribution ──────────────────────── */
function renderReferralAnalytics() {
  const el = document.getElementById('acquisitionSourcesContainer');
  if (!el) return;

  // The known list seeds the chart, but the DENOMINATOR counts every source present —
  // so a value missing from the list (orders created through the online intake/quote path
  // are written with source:'online') inflated the total, never appeared as a bar, and
  // silently understated every other channel. Build the display list from what is
  // actually there, so percentages sum to 100%.
  const sources = ['instagram','referral','walk_in','website','exhibition','salla','zid','intake_form','online','other'];
  const counts = {};
  sources.forEach(s => { counts[s] = 0; });
  for (const o of printLog) {
    const s = o.source || 'other';
    counts[s] = (counts[s] || 0) + 1;
  }
  // Anything still unknown gets its own bar rather than vanishing from the chart.
  for (const key of Object.keys(counts)) {
    if (!sources.includes(key)) sources.push(key);
  }

  const total = Object.values(counts).reduce((a, b) => a + b, 0) || 1;
  const colors = {
    instagram:'#e1306c', referral:'#22c55e', walk_in:'#3b82f6',
    website:'#f59e0b',   exhibition:'#a855f7', salla:'#10b981',
    zid:'#6366f1',       intake_form:'#f97316', online:'#0ea5e9', other:'#6b7280',
  };

  const bars = sources.filter(s => counts[s] > 0)
    .sort((a, b) => counts[b] - counts[a])
    .map(s => {
      const pct = Math.round((counts[s] / total) * 100);
      return `<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
        <span style="min-width:100px;font-size:12px;text-align:end;">${escapeHtml(s.replace(/_/g,' '))}</span>
        <div style="flex:1;background:var(--border);border-radius:3px;height:12px;overflow:hidden;">
          <div style="width:${pct}%;height:100%;background:${colors[s] || '#888'};border-radius:3px;"></div>
        </div>
        <span style="min-width:40px;font-size:11px;color:var(--text-muted);">${counts[s]} (${pct}%)</span>
      </div>`;
    }).join('');

  // Top referrers (clients whose referralCode appears on orders as referredBy)
  const referralMap = {};
  for (const o of printLog) {
    if (o.referredBy) referralMap[o.referredBy] = (referralMap[o.referredBy] || 0) + 1;
  }
  const topReferrers = Object.entries(referralMap)
    .sort((a, b) => b[1] - a[1]).slice(0, 5)
    .map(([cid, cnt]) => {
      const cl = clients.find(c => c.id === cid);
      return `<tr><td>${cl ? escapeHtml(localName(cl)) : escapeHtml(cid)}</td><td>${cnt}</td></tr>`;
    }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;padding:14px;">
      <h4 style="margin-bottom:10px;">${escapeHtml(t('ref.acquisition_sources'))}</h4>
      ${bars || `<span style="color:var(--text-muted);font-size:12px;">${escapeHtml(t('ref.no_data'))}</span>`}
    </div>
    ${topReferrers ? `<div class="card" style="padding:14px;">
      <h4 style="margin-bottom:10px;">${escapeHtml(t('ref.top_referrers'))}</h4>
      <table><thead><tr><th>${escapeHtml(t('ref.client'))}</th><th>${escapeHtml(t('ref.referrals'))}</th></tr></thead><tbody>${topReferrers}</tbody></table>
    </div>` : ''}`;
}

/* ── Feature 13: Change Order Workflow ──────────────────────── */

/* ── Feature 14: Print Failure Photo Capture ────────────────── */

/* ── Feature 15: Shipping Carrier Integration ───────────────── */
function trackShipment(trackingNumber, carrier) {
  if (!trackingNumber) { toast(t('ship.no_tracking'), 'error'); return; }
  let url = '';
  const tn = encodeURIComponent(trackingNumber.trim());
  const c  = (carrier || '').toLowerCase();
  if (c === 'aramex') {
    url = `https://www.aramex.com/track/results?ShipmentNumber=${tn}`;
  } else if (c === 'saudipost' || c === 'saudi_post' || c === 'saudi post') {
    url = `https://www.saudipost.com.sa/en/tools/track?num=${tn}`;
  } else if (c === 'dhl') {
    url = `https://www.dhl.com/en/express/tracking.html?AWB=${tn}`;
  } else if (c === 'fedex') {
    url = `https://www.fedex.com/fedextrack/?trknbr=${tn}`;
  } else {
    toast(t('ship.copy_and_check') + ': ' + trackingNumber, 'info', 6000);
    return;
  }
  window.hubAPI?.openExternal?.(url) || window.open(url, '_blank');
}
(function (global) {
  /* ── Customer order intake (inbound requests → draft quotes) ──────
   * Customers submit a request at {cloudUrl}/intake/{shopId}; the owner pulls
   * the inbox here and turns a request into a draft quote (+ a linked client). */
  function cloudCfgForIntake() {
    const c = (typeof settings !== 'undefined' && settings.cloud) || {};
    return (c.shopId && c.token && c.url) ? c : null;
  }

  async function copyIntakeLink() {
    const c = cloudCfgForIntake();
    if (!c) { toast(t('intake.connect_first'), 'error'); return; }
    const link = `${String(c.url).replace(/\/+$/, '')}/intake/${c.shopId}`;
    if (await copyText(link)) toast(t('intake.link_copied'), 'success');
    else toast(link, 'info', 6000);
  }

  function intakeRequestRow(it) {
    const p = it.payload || {};
    const when = it.createdAt ? new Date(it.createdAt).toLocaleString() : '';
    const meta = [
      p.qty ? `× ${escapeHtml(p.qty)}` : '',
      p.material ? `🧵 ${escapeHtml(p.material)}` : '',
      p.name ? `👤 ${escapeHtml(p.name)}` : '',
      p.contact ? `✉ ${escapeHtml(p.contact)}` : '',
    ].filter(Boolean).join('  ·  ');
    return `<div class="card" data-intake="${escapeHtml(it.id)}" style="padding:12px;margin-bottom:10px;">
      <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:8px;margin-bottom:6px;">
        <strong style="font-size:14px;">${escapeHtml(p.title || (p.description || '').slice(0, 60) || '—')}</strong>
        <span style="font-size:11px;color:var(--text-muted);white-space:nowrap;">${escapeHtml(when)}</span>
      </div>
      ${p.description ? `<div style="font-size:13px;white-space:pre-wrap;margin-bottom:6px;">${escapeHtml(p.description)}</div>` : ''}
      ${meta ? `<div style="font-size:12.5px;color:var(--text-muted);">${meta}</div>` : ''}
      ${p.link ? `<div style="font-size:12.5px;margin-top:4px;"><a href="#" data-intake-link="${escapeHtml(p.link)}" style="color:var(--primary);">${escapeHtml(p.link)}</a></div>` : ''}
      ${p.photo ? `<img src="${escapeHtml(p.photo)}" alt="" style="max-width:160px;border-radius:8px;margin-top:8px;border:1px solid var(--border-soft);">` : ''}
      <div style="display:flex;gap:8px;margin-top:10px;">
        <button class="btn primary small" data-intake-import="${escapeHtml(it.id)}">${escapeHtml(t('intake.import'))}</button>
        <button class="btn ghost small" data-intake-dismiss="${escapeHtml(it.id)}">${escapeHtml(t('intake.dismiss'))}</button>
      </div>
    </div>`;
  }

  async function openOrderRequestsModal() {
    const c = cloudCfgForIntake();
    if (!c) { toast(t('intake.connect_first'), 'error'); return; }
    let items = [];
    try {
      const r = await window.hubAPI.cloudIntakeList({ url: c.url, shopId: c.shopId, token: c.token });
      if (!r || !r.ok) throw new Error((r && r.error) || 'failed');
      items = r.items || [];
    } catch (e) { toast(`${t('intake.load_fail')} ${e.message}`, 'error'); return; }

    openFormModal({
      title: `🛎 ${t('intake.requests')} (${items.length})`,
      noSave: true,
      bodyHtml: items.length
        ? `<div id="intakeList">${items.map(intakeRequestRow).join('')}</div>`
        : `<p style="color:var(--text-muted);">${escapeHtml(t('intake.empty'))}</p>`,
      onMount(modal) {
        const byId = (id) => items.find(x => x.id === id);
        modal.querySelectorAll('[data-intake-link]').forEach(a =>
          a.addEventListener('click', (e) => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.intakeLink); }));
        modal.querySelectorAll('[data-intake-import]').forEach(btn =>
          btn.addEventListener('click', async () => {
            const it = byId(btn.dataset.intakeImport);
            if (it) { await importIntakeAsQuote(it, c); modal.querySelector('[data-act="cancel"]')?.click(); }
          }));
        modal.querySelectorAll('[data-intake-dismiss]').forEach(btn =>
          btn.addEventListener('click', async () => {
            await dismissIntake(btn.dataset.intakeDismiss, c);
            modal.querySelector(`[data-intake="${CSS.escape(btn.dataset.intakeDismiss)}"]`)?.remove();
          }));
      },
    });
  }

  // Find-or-create a client from the request's name/contact.
  function clientFromIntake(p) {
    const name = (p.name || '').trim();
    const contact = (p.contact || '').trim();
    if (!name && !contact) return null;
    const isEmail = /@/.test(contact);
    if (contact) {
      const ex = clients.find(c => isEmail
        ? String(c.email || '').trim().toLowerCase() === contact.toLowerCase()
        : String(c.phone || '').trim() === contact);
      if (ex) return ex.id;
    }
    const created = {
      id: uid('CLI'), nameEn: name || contact, nameAr: '',
      phone: isEmail ? '' : contact, email: isEmail ? contact : '', source: 'online',
    };
    clients.push(created);
    return created.id;
  }

  async function importIntakeAsQuote(it, c) {
    const p = it.payload || {};
    const clientId = clientFromIntake(p);
    const now = new Date();
    const seq = (typeof nextQuoteSeq === 'function') ? nextQuoteSeq() : String(now.getTime()).slice(-4);
    const prefix = (settings.quotePrefix || 'QUO');
    const notes = [
      p.description || '',
      p.qty ? `Qty: ${p.qty}` : '',
      p.material ? `Material: ${p.material}` : '',
      p.link ? `Model: ${p.link}` : '',
      p.contact ? `Contact: ${p.contact}` : '',
    ].filter(Boolean).join('\n');
    const order = {
      id: `${prefix}-${now.getFullYear()}-${seq}`,
      date: localDateStr(now),
      timestamp: now.toISOString(),
      project: p.title || p.description?.slice(0, 60) || t('intake.requests'),
      clientId: clientId || null,
      material: p.material || '',
      printTime: 0,
      price: 0,
      status: 'quote',
      statusHistory: [{ status: 'quote', at: now.toISOString() }],
      paymentStatus: 'unpaid',
      paidAmount: 0,
      notes: notes,
      internalNotes: `↳ ${t('intake.requests')}`,
      attachedFiles: [],
      parts: [],
      tags: ['portal'],
      quoteSentAt: null,
      quoteVersion: 1,
      quoteRevisions: [],
      source: 'online',
      trackingToken: (() => { const b = new Uint8Array(16); crypto.getRandomValues(b); return Array.from(b, x => x.toString(16).padStart(2, '0')).join(''); })(),
    };
    printLog.unshift(order);
    await dismissIntake(it.id, c, true); // remove from the cloud inbox (best-effort)
    saveAll();
    toast(t('intake.imported'), 'success');
    if (typeof switchTab === 'function') switchTab('logs-tab');
  }

  async function dismissIntake(id, c, silent) {
    try {
      const r = await window.hubAPI.cloudIntakeDelete({ url: c.url, shopId: c.shopId, token: c.token, id });
      if (!r || !r.ok) throw new Error((r && r.error) || 'failed');
    } catch (e) { if (!silent) toast(e.message, 'error'); }
  }

  global.BNPL_CATALOG = BNPL_CATALOG;
  const api = {
    openOrderRequestsModal,
    copyIntakeLink,
    autoSendEmailNotification,
    checkAndSendDigest,
    fireWebhook,
    generateSurveyPage,
    openRecordSurveyModal,
    getCarrierTrackingUrl,
    openBnplModal,
    startLanServer,
    updateWebhookUrlDisplay,
    webhookSubscriptions,
    resumePendingWebhooks,
    resendWebhookDelivery,
    disableWebhookSubscription,
    loadLanQr,
    refreshLanIntakePinLive,
    reconcileLanServerStatus,
    startTunnelFromSettings,
    exportAccountingCSV,
    renderOrderComments,
    exportOrderStatusPage,
    autoExportStatusPage,
    openSavedStatusPage,
    openCustomerPortalModal,
    aiDraftReply,
    publishOrderToCloudPortal,
    republishPortalIfPublished,
    openPortalMessages,
    openQuoteApprovalLinkModal,
    clearAllLogs,
    sendTelegramForOrder,
    checkTelegramLowStock,
    dispatchPrinterAlerts,
    firePrinterAlert,
    exportIcalFeed,
    renderReferralAnalytics,
    trackShipment,
    // operations-extras.js guards on `typeof deliverWebhook === 'function'`,
    // which was always false from outside this IIFE, so that path never
    // delivered a webhook.
    deliverWebhook,
  };
  Object.assign(global, api);
  // NOTE: do NOT set global.KhaytIntegrations here — that name is owned by the
  // market registry (lib/integrations-registry.js: MARKETS/forLocale/…), which
  // loads first. Assigning the feature api to it clobbered the registry and broke
  // KhaytIntegrations.forLocale() (settings market selectors). Feature functions
  // are already exposed as globals via Object.assign(global, api) above.
  if (typeof module !== 'undefined' && module.exports) module.exports = { BNPL_CATALOG, ...api };
})(typeof globalThis !== 'undefined' ? globalThis : window);
