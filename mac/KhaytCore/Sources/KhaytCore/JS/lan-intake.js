'use strict';

/**
 * The customer's way in: the intake form and what a submission becomes.
 *
 * Lifted out of `lib/lan-server.js` — the page template, the "too many
 * requests" page and the block that turned a posted form into a waiting-list
 * entry all lived inside the `/intake` and `/api/intake` handlers beside
 * Node's `http` — so that the native Mac app, which has no Node, can serve
 * the SAME form and record the SAME entry. The Node server draws from this
 * module now; `test/lan-intake.test.js` holds it to the original handlers,
 * copied verbatim.
 *
 * PURE. The clock, the id and the consent rule are handed in: a submission
 * that asked `Date.now()` itself would record a different `submittedAt` on
 * the two sides of a test, and the id is the host's to mint (`uniqueLanId`
 * on Node, a UUID on the Mac). Sessions, cookies and rate buckets stay in the
 * host — they are plumbing with a socket address in them, not a rule.
 *
 * The page takes `shopName` and `currency` ALREADY ESCAPED, exactly as the
 * handler passed them, because escaping twice is as wrong as not at all.
 */
(function (global) {

  const LanAuth = global.KhaytLanAuth
    || (typeof require === 'function' ? require('./lan-auth.js') : null);
  const Privacy = global.KhaytPrivacy
    || (typeof require === 'function' ? require('./privacy.js') : null);

  /** Visitors may open the form this many times per window before a 429. */
  const SESSION_GRANT_LIMIT = 40;
  /** …and submit this many. */
  const SUBMIT_LIMIT = 20;
  const SUBMIT_WINDOW_MS = 60 * 60 * 1000;
  /** A form session lasts this long; the cookie carries the same lifetime. */
  const SESSION_MS = 4 * 60 * 60 * 1000;
  const COOKIE = 'khayt_intake';

  // ── The pages, verbatim ─────────────────────────────────────────────────
const intakeSharedStyles = '*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;min-height:100vh;padding:24px 16px}.container{max-width:520px;margin:0 auto}.header{text-align:center;margin-bottom:28px}.header h1{font-size:1.5rem;font-weight:700;color:#f1f5f9;margin-bottom:4px}.header p{color:#94a3b8;font-size:.9rem}.card{background:#1e293b;border-radius:16px;padding:24px;margin-bottom:16px}.form-group{margin-bottom:16px}label{display:block;font-size:.8rem;font-weight:600;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:.05em}input,textarea,select{width:100%;background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:.9rem;outline:none;transition:border-color .2s}input:focus,textarea:focus,select:focus{border-color:#6366f1}textarea{resize:vertical;min-height:100px}select option{background:#1e293b}.req{color:#f87171}button[type=submit]{width:100%;background:#6366f1;color:#fff;border:none;border-radius:10px;padding:13px;font-size:1rem;font-weight:600;cursor:pointer;transition:background .2s}button[type=submit]:hover{background:#4f46e5}button[type=submit]:disabled{background:#334155;cursor:not-allowed}.thankyou{display:none;text-align:center;padding:40px 24px}.thankyou h2{font-size:1.3rem;color:#6366f1;margin-bottom:12px}.thankyou p{color:#94a3b8;line-height:1.6}.error-msg{color:#f87171;font-size:.8rem;margin-top:6px;display:none}';
const renderIntakeFormPage = (shopName, currency, quoteEnabled) => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Intake — ${shopName}</title><style>${intakeSharedStyles}</style></head><body><div class="container"><div class="header"><h1>${shopName}</h1><p>Submit a new order request</p></div><div class="card"><form id="intakeForm"><div class="form-group"><label>Name <span class="req">*</span></label><input type="text" name="name" required maxlength="200" placeholder="Your full name"></div><div class="form-group"><label>Email</label><input type="email" name="email" maxlength="500" placeholder="your@email.com"></div><div class="form-group"><label>Phone</label><input type="tel" name="phone" maxlength="500" placeholder="+966 5x xxx xxxx"></div>${quoteEnabled ? '<div class="form-group"><label>Your 3D model <span style="font-weight:400;color:#6b7280;">(optional — get an indicative price now)</span></label><input type="file" id="modelFile" accept=".stl,.obj,.3mf,.gcode,.gco"><div id="modelResult" style="display:none;margin-top:8px;padding:10px 12px;border-radius:8px;font-size:.9rem;line-height:1.5;"></div><p style="margin:6px 0 0;font-size:.78rem;color:#6b7280;">Your file is read to work out a price and is not stored. We will ask for it again if you go ahead.</p></div>' : ''}<div class="form-group"><label>Project Description <span class="req">*</span></label><textarea name="description" required maxlength="2000" placeholder="Describe your 3D printing project in detail..."></textarea></div><div class="form-group"><label>Reference / Link</label><input type="url" name="referenceLink" maxlength="500" placeholder="https:${'/'}/..."></div><div class="form-group"><label>Preferred Material</label><input type="text" name="material" maxlength="500" placeholder="e.g. PLA, PETG, Resin"></div><div class="form-group"><label>Budget Range</label><select name="budget"><option value="">— Select —</option><option value="&lt;100">Less than 100${currency ? ' ' + currency : ''}</option><option value="100-500">100 – 500${currency ? ' ' + currency : ''}</option><option value="500-1000">500 – 1,000${currency ? ' ' + currency : ''}</option><option value="1000+">1,000+${currency ? ' ' + currency : ''}</option></select></div><div class="form-group"><label>Preferred Due Date</label><input type="date" name="dueDate" maxlength="500"></div><div class="form-group" style="margin-top:4px;"><label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;"><input type="checkbox" name="consent" id="intakeConsent" required style="width:auto;margin:3px 0 0;"><span style="font-size:.85rem;line-height:1.5;">I agree that ${shopName} may store my contact details to process this request. Your details are kept by ${shopName} and are not sold or shared. You may ask them to access or delete your data at any time.</span></label></div><div class="error-msg" id="errMsg">An error occurred. Please try again.</div><button type="submit">Submit Request</button></form><div class="thankyou" id="thankYou"><h2>Thank you!</h2><p>Your request has been received. We'll get back to you as soon as possible.</p></div></div></div><script>var estimateRef='';var mf=document.getElementById('modelFile');if(mf){mf.addEventListener('change',async function(){var box=document.getElementById('modelResult');var f=this.files&&this.files[0];estimateRef='';if(!f){box.style.display='none';return;}
var say=function(html,bg,fg){box.innerHTML=html;box.style.background=bg;box.style.color=fg;box.style.display='block';};
if(f.size>32*1024*1024){say('That file is larger than 32 MB — send it to us another way and we will price it by hand.','#fef3c7','#92400e');return;}
say('Reading your model…','#f3f4f6','#374151');
try{var r=await fetch('/api/intake/estimate?name='+encodeURIComponent(f.name),{method:'POST',credentials:'include',headers:{'Content-Type':'application/octet-stream'},body:f});var j=await r.json().catch(function(){return{};});
if(!j.ok){var why={'off':'We are not quoting online just now — send your request and we will come back to you.','not-configured':'We are not quoting online just now — send your request and we will come back to you.','no-numbers':'We could not read that file. Send your request anyway and we will take a look.','unsupported':'We can read STL, OBJ, 3MF and G-code files.','too-large':'That file is too large to price here.','no-price':'We could not price that automatically. Send your request and we will come back to you.'};say(why[j.reason]||why['no-price'],'#fef3c7','#92400e');return;}
estimateRef=j.ref||'';
var money=j.price.toFixed(2)+(j.currency?(' '+j.currency):'');
var head=j.exact?('<b>About '+money+'</b>'):('<b>Roughly '+money+'</b>');
var detail=j.exact?('Based on your sliced file'+(j.slicer?(' from '+j.slicer):'')+' — about '+j.grams+' g and '+j.hours+' h of printing.'):('Estimated from the shape of your model — about '+j.grams+' g and '+j.hours+' h of printing. Nobody has sliced this file yet, so the real figure can differ.');
/* Shapes with very thin or very detailed surfaces defeat a geometric estimate: measured against a real slicer they land anywhere from +58% to -66%. Showing the usual soft caveat there would be dishonest, so this one is louder and the panel turns amber. */
var shaky=(j.reliable===false);
var warn=shaky?'<br><b>This shape is hard to price automatically</b> — thin or highly detailed models can differ a long way from this figure. Send your request and we will price it properly.':'';
say(head+'<br>'+detail+warn+'<br><span style="font-size:.8rem;">This is an indication, not a confirmed quote. We will confirm before any work starts.</span>',shaky?'#fef3c7':'#ecfdf5',shaky?'#92400e':'#065f46');}
catch(ex){say('We could not price that just now. Send your request and we will come back to you.','#fef3c7','#92400e');}});}
document.getElementById('intakeForm').addEventListener('submit',async function(e){e.preventDefault();const btn=this.querySelector('button[type=submit]');const err=document.getElementById('errMsg');err.style.display='none';btn.disabled=true;btn.textContent='Submitting…';const data={};new FormData(this).forEach((v,k)=>{if(v)data[k]=v;});data.consent=document.getElementById('intakeConsent').checked;if(estimateRef)data.estimateRef=estimateRef;try{const r=await fetch('/api/intake',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});if(r.ok){this.style.display='none';document.getElementById('thankYou').style.display='block';}else{const j=await r.json().catch(()=>({}));err.textContent=j.error||'Submission failed.';err.style.display='block';btn.disabled=false;btn.textContent='Submit Request';}}catch(ex){err.textContent='Network error. Please try again.';err.style.display='block';btn.disabled=false;btn.textContent='Submit Request';}});<\/script></body></html>`;

  /** `/intake` — the form. `shopName` and `currency` escaped by the caller. */
  function formPage(shopName, currency, quoteEnabled) {
    return renderIntakeFormPage(shopName, currency, quoteEnabled);
  }

  /** The page a visitor gets when the form has been opened too often. */
  function tooManyPage() {
    return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Too many requests</title><style>${intakeSharedStyles}</style></head><body><div class="container"><div class="card"><h2 style="margin-bottom:12px;color:#f1f5f9">Too many requests</h2><p style="color:#94a3b8;line-height:1.6">Please wait a while before trying again.</p></div></div></body></html>`;
  }

  /**
   * One per-address rate bucket, advanced: the server's `bumpRate` on a
   * record instead of a Map. Returns the record to keep and whether this
   * call was within the limit.
   */
  function bumpRate(rec, now, limit, windowMs = SUBMIT_WINDOW_MS) {
    const r = rec ? { count: rec.count, resetAt: rec.resetAt } : { count: 0, resetAt: now + windowMs };
    if (now >= r.resetAt) { r.count = 0; r.resetAt = now + windowMs; }
    if (r.count >= limit) return { allowed: false, rec: r };
    r.count += 1;
    return { allowed: true, rec: r };
  }

  /**
   * What a posted form becomes — or why it is refused.
   *
   * `parsed` is the JSON body. `opts.shopName` is the shop's name for the
   * consent record (unescaped), `opts.nowIso` the shop's clock, `opts.id` the
   * entry id the host minted, `opts.quoted` the estimate the host recalled by
   * reference (never a figure from the body). Returns `{ ok: true, entry }`
   * or `{ ok: false, status, error }` with the customer-facing message the
   * server has always sent.
   */
  function submission(parsed, opts) {
    const o = opts || {};
    const p = parsed && typeof parsed === 'object' ? parsed : {};
    const nowIso = o.nowIso || new Date().toISOString();
    // Validate required fields
    const name = typeof p.name === 'string' ? p.name.trim().slice(0, 200) : '';
    const description = typeof p.description === 'string' ? p.description.trim().slice(0, 2000) : '';
    if (!name) return { ok: false, status: 400, error: 'name is required' };
    if (!description) return { ok: false, status: 400, error: 'description is required' };
    // Optional fields — sanitize
    const sanitize = (v) => typeof v === 'string' ? v.trim().slice(0, 500) : undefined;
    const email = sanitize(p.email);
    const phone = sanitize(p.phone);
    const material = sanitize(p.material);
    const budget = sanitize(p.budget);
    const dueDate = sanitize(p.dueDate);
    const referenceLink = LanAuth.sanitizeLanHttpUrl(p.referenceLink);
    // PDPL: the intake form is the one place a customer submits their OWN data,
    // so explicit consent is required and recorded immutably with the exact
    // notice wording they saw. See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.
    let consent = null;
    try {
      consent = Privacy.consentRecord(p.consent === true || p.consent === 'true', o.shopName || 'this shop', 'en', nowIso);
    } catch (_) { consent = null; }
    if (!consent) {
      return { ok: false, status: 400, error: 'Please agree to the privacy notice to submit your request.' };
    }
    // Store in renderer-compatible waiting-list format
    const entry = {
      id: o.id,
      project: description.slice(0, 80),  // first 80 chars as project name
      clientName: name,
      notes: description,
      email, phone, material, budget, referenceLink,
      reminderDate: dueDate || null,
      priority: 'normal',
      status: 'active',
      estValue: 0,
      source: 'intake_form',
      submittedAt: nowIso,
      consent,
    };
    // If we priced a model for this visitor, attach OUR figure — looked up
    // by reference, never taken from the body. A browser can post any
    // number it likes; the shop must see what the server actually said.
    const quoted = o.quoted;
    if (quoted && quoted.ok) {
      entry.estValue = quoted.price;
      entry.modelQuote = {
        price: quoted.price,
        currency: quoted.currency,
        qty: quoted.qty,
        grams: quoted.grams,
        hours: quoted.hours,
        // Carried through so the shop can see at a glance whether this
        // came off a slicer or off a guess about geometry.
        exact: quoted.exact,
        slicer: quoted.slicer,
        binding: false,
        shownAt: nowIso,
      };
      // What the mesh said might go wrong, recorded with the request
      // rather than shown to the visitor.
      if (quoted.risk) entry.modelQuote.risk = quoted.risk;
    }
    // Remove undefined keys
    Object.keys(entry).forEach(k => entry[k] === undefined && delete entry[k]);
    return { ok: true, entry };
  }

  const api = {
    formPage, tooManyPage, submission, bumpRate,
    SESSION_GRANT_LIMIT, SUBMIT_LIMIT, SUBMIT_WINDOW_MS, SESSION_MS, COOKIE,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLanIntake = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
