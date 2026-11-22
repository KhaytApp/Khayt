/**
 * lib/lan-intake.js is the intake form and the submission rule, lifted out of
 * lib/lan-server.js so the Mac app can serve the same form and record the same
 * entry.
 *
 * THE PROOF METHOD: the original page template and the original submission
 * block are copied below VERBATIM from the handlers (the one edit is the
 * require path of privacy.js, which is relative to the file it sits in) and
 * run against the same inputs the module is handed. Byte-identical pages and
 * deep-equal entries, over generated forms, or a diff on a concrete input.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const LanAuth = require('../lib/lan-auth.js');
const LanIntake = require('../lib/lan-intake.js');

// ── The originals, verbatim ─────────────────────────────────────────────────
const intakeSharedStyles = '*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;min-height:100vh;padding:24px 16px}.container{max-width:520px;margin:0 auto}.header{text-align:center;margin-bottom:28px}.header h1{font-size:1.5rem;font-weight:700;color:#f1f5f9;margin-bottom:4px}.header p{color:#94a3b8;font-size:.9rem}.card{background:#1e293b;border-radius:16px;padding:24px;margin-bottom:16px}.form-group{margin-bottom:16px}label{display:block;font-size:.8rem;font-weight:600;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:.05em}input,textarea,select{width:100%;background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:.9rem;outline:none;transition:border-color .2s}input:focus,textarea:focus,select:focus{border-color:#6366f1}textarea{resize:vertical;min-height:100px}select option{background:#1e293b}.req{color:#f87171}button[type=submit]{width:100%;background:#6366f1;color:#fff;border:none;border-radius:10px;padding:13px;font-size:1rem;font-weight:600;cursor:pointer;transition:background .2s}button[type=submit]:hover{background:#4f46e5}button[type=submit]:disabled{background:#334155;cursor:not-allowed}.thankyou{display:none;text-align:center;padding:40px 24px}.thankyou h2{font-size:1.3rem;color:#6366f1;margin-bottom:12px}.thankyou p{color:#94a3b8;line-height:1.6}.error-msg{color:#f87171;font-size:.8rem;margin-top:6px;display:none}';
const renderIntakeFormPage = (shopName, currency, quoteEnabled) => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Intake — ${shopName}</title><style>${intakeSharedStyles}</style></head><body><div class="container"><div class="header"><h1>${shopName}</h1><p>Submit a new order request</p></div><div class="card"><form id="intakeForm"><div class="form-group"><label>Name <span class="req">*</span></label><input type="text" name="name" required maxlength="200" placeholder="Your full name"></div><div class="form-group"><label>Email</label><input type="email" name="email" maxlength="500" placeholder="your@email.com"></div><div class="form-group"><label>Phone</label><input type="tel" name="phone" maxlength="500" placeholder="+966 5x xxx xxxx"></div>${quoteEnabled ? '<div class="form-group"><label>Your 3D model <span style="font-weight:400;color:#6b7280;">(optional — get an indicative price now)</span></label><input type="file" id="modelFile" accept=".stl,.obj,.3mf,.gcode,.gco"><div id="modelResult" style="display:none;margin-top:8px;padding:10px 12px;border-radius:8px;font-size:.9rem;line-height:1.5;"></div><p style="margin:6px 0 0;font-size:.78rem;color:#6b7280;">Your file is read to work out a price and is not stored. We will ask for it again if you go ahead.</p></div>' : ''}<div class="form-group"><label>Project Description <span class="req">*</span></label><textarea name="description" required maxlength="2000" placeholder="Describe your 3D printing project in detail..."></textarea></div><div class="form-group"><label>Reference / Link</label><input type="url" name="referenceLink" maxlength="500" placeholder="https://..."></div><div class="form-group"><label>Preferred Material</label><input type="text" name="material" maxlength="500" placeholder="e.g. PLA, PETG, Resin"></div><div class="form-group"><label>Budget Range</label><select name="budget"><option value="">— Select —</option><option value="&lt;100">Less than 100${currency ? ' ' + currency : ''}</option><option value="100-500">100 – 500${currency ? ' ' + currency : ''}</option><option value="500-1000">500 – 1,000${currency ? ' ' + currency : ''}</option><option value="1000+">1,000+${currency ? ' ' + currency : ''}</option></select></div><div class="form-group"><label>Preferred Due Date</label><input type="date" name="dueDate" maxlength="500"></div><div class="form-group" style="margin-top:4px;"><label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;"><input type="checkbox" name="consent" id="intakeConsent" required style="width:auto;margin:3px 0 0;"><span style="font-size:.85rem;line-height:1.5;">I agree that ${shopName} may store my contact details to process this request. Your details are kept by ${shopName} and are not sold or shared. You may ask them to access or delete your data at any time.</span></label></div><div class="error-msg" id="errMsg">An error occurred. Please try again.</div><button type="submit">Submit Request</button></form><div class="thankyou" id="thankYou"><h2>Thank you!</h2><p>Your request has been received. We'll get back to you as soon as possible.</p></div></div></div><script>var estimateRef='';var mf=document.getElementById('modelFile');if(mf){mf.addEventListener('change',async function(){var box=document.getElementById('modelResult');var f=this.files&&this.files[0];estimateRef='';if(!f){box.style.display='none';return;}
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
const originalTooMany = () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Too many requests</title><style>${intakeSharedStyles}</style></head><body><div class="container"><div class="card"><h2 style="margin-bottom:12px;color:#f1f5f9">Too many requests</h2><p style="color:#94a3b8;line-height:1.6">Please wait a while before trying again.</p></div></div></body></html>`;

/**
 * The submission block as it stands in the `/api/intake` handler, with the
 * handler's surroundings shimmed: `res` records what was sent, the store, the
 * estimate ledger and the id are the fixtures, and the clock is frozen so
 * `submittedAt` can be compared at all.
 */
async function originalSubmission(body, fx) {
  const sent = { status: null, body: null };
  const res = { writeHead(s) { sent.status = s; }, end(b) { sent.body = b; } };
  const parseLanJsonBody = (b) => JSON.parse(b);
  const sanitizeLanHttpUrl = LanAuth.sanitizeLanHttpUrl;
  const STORE = () => ({ settings: { shopName: fx.shopName } });
  const recallEstimate = () => fx.quoted;
  const uniqueLanId = () => fx.id;
  const RealDate = globalThis.Date;
  class FrozenDate extends RealDate {
    constructor(...a) { super(...(a.length ? a : [fx.nowIso])); }
    static now() { return new RealDate(fx.nowIso).getTime(); }
  }
  globalThis.Date = FrozenDate;
  let recorded = null;
  try {
    // An inner function, so the block's own `return`s (its refusals) leave
    // the block and not this wrapper.
    await (async () => {
    const parsed = parseLanJsonBody(body, {});
    // Validate required fields
    const name = typeof parsed.name === 'string' ? parsed.name.trim().slice(0, 200) : '';
    const description = typeof parsed.description === 'string' ? parsed.description.trim().slice(0, 2000) : '';
    if (!name) {
      res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ error: 'name is required' }));
      return;
    }
    if (!description) {
      res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ error: 'description is required' }));
      return;
    }
    // Optional fields — sanitize
    const sanitize = (v) => typeof v === 'string' ? v.trim().slice(0, 500) : undefined;
    const email = sanitize(parsed.email);
    const phone = sanitize(parsed.phone);
    const material = sanitize(parsed.material);
    const budget = sanitize(parsed.budget);
    const dueDate = sanitize(parsed.dueDate);
    const referenceLink = sanitizeLanHttpUrl(parsed.referenceLink);
    // PDPL: the intake form is the one place a customer submits their OWN data,
    // so explicit consent is required and recorded immutably with the exact
    // notice wording they saw. See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.
    let consent = null;
    try {
      const privacyLib = require('../lib/privacy.js');
      const shopName = STORE().settings?.shopName || 'this shop';
      consent = privacyLib.consentRecord(parsed.consent === true || parsed.consent === 'true', shopName, 'en');
    } catch (_) { consent = null; }
    if (!consent) {
      res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ error: 'Please agree to the privacy notice to submit your request.' }));
      return;
    }
    // Store in renderer-compatible waiting-list format
    const entry = {
      id: uniqueLanId('intake'),
      project: description.slice(0, 80),  // first 80 chars as project name
      clientName: name,
      notes: description,
      email, phone, material, budget, referenceLink,
      reminderDate: dueDate || null,
      priority: 'normal',
      status: 'active',
      estValue: 0,
      source: 'intake_form',
      submittedAt: new Date().toISOString(),
      consent,
    };
    // If we priced a model for this visitor, attach OUR figure — looked up
    // by reference, never taken from the body. A browser can post any
    // number it likes; the shop must see what the server actually said.
    const quoted = recallEstimate(parsed.estimateRef);
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
        shownAt: new Date().toISOString(),
      };
      // What the mesh said might go wrong, recorded with the request
      // rather than shown to the visitor. This is the moment it is
      // worth something: the shop is deciding whether to take a job at
      // a price a stranger has already been shown, and "a fifth of
      // this needs supports" is exactly the thing that turns an
      // acceptable price into an unacceptable one.
      if (quoted.risk) entry.modelQuote.risk = quoted.risk;
    }
    // Remove undefined keys
    Object.keys(entry).forEach(k => entry[k] === undefined && delete entry[k]);
    recorded = entry;
    })();
  } finally {
    globalThis.Date = RealDate;
  }
  if (sent.status != null) return { ok: false, status: sent.status, error: JSON.parse(sent.body).error };
  return { ok: true, entry: recorded };
}

// ── Generated inputs ────────────────────────────────────────────────────────
function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
const pick = (r, list) => list[Math.floor(r() * list.length)];
const strings = ['', '  ', 'Ali', '  Sara al-Otaibi  ', 'x'.repeat(250), 'ملف <b>&</b>', 'a\nb', 'https://ex.com/p?q=1', 'javascript:alert(1)', 'ftp://x'];
function genBody(r) {
  const b = {};
  const maybe = (k, v) => { if (r() < 0.8) b[k] = v; };
  // Weighted towards a valid form: a generator that refuses nine in ten
  // compares the refusals well and the entries hardly at all.
  const valid = ['Ali', '  Sara al-Otaibi  ', 'ملف <b>&</b>', 'x'.repeat(250)];
  maybe('name', r() < 0.75 ? pick(r, valid) : pick(r, strings.concat([null, 12, ['a']])));
  maybe('description', r() < 0.75 ? pick(r, valid) : pick(r, strings.concat([null, 7, 'd'.repeat(2500)])));
  maybe('email', pick(r, strings));
  maybe('phone', pick(r, strings.concat([5])));
  maybe('material', pick(r, strings));
  maybe('budget', pick(r, ['', '<100', '100-500', '1000+', 9]));
  maybe('dueDate', pick(r, ['', '2027-02-01', 'soon', null]));
  maybe('referenceLink', pick(r, strings.concat([null, 3])));
  if (r() < 0.6) b.consent = pick(r, [true, 'true']); else maybe('consent', pick(r, [false, 'false', 'yes', 1, null]));
  maybe('estimateRef', pick(r, ['', 'ref-1', 'ref-2']));
  return b;
}
function genQuoted(r) {
  if (r() < 0.5) return null;
  const q = { ok: r() < 0.8, price: Math.round(r() * 100000) / 100, currency: pick(r, ['SAR', 'USD', undefined]),
    qty: 1 + Math.floor(r() * 5), grams: Math.round(r() * 800), hours: Math.round(r() * 300) / 10,
    exact: r() < 0.5, slicer: pick(r, ['OrcaSlicer', undefined, 'Cura']) };
  if (r() < 0.4) q.risk = { overhangPct: Math.round(r() * 100) };
  return q;
}

test('the intake page is byte-identical to the handler\'s template', () => {
  for (const shop of ['Khayt', 'Al Noor &amp; Sons', 'متجر', '']) {
    for (const currency of ['', 'SAR', 'USD', '€']) {
      for (const quote of [true, false]) {
        assert.equal(LanIntake.formPage(shop, currency, quote), renderIntakeFormPage(shop, currency, quote),
          `${shop}/${currency}/${quote}`);
      }
    }
  }
  assert.equal(LanIntake.tooManyPage(), originalTooMany());
});

test('a submission becomes the same entry, or the same refusal, as the handler made', async () => {
  const r = rng(20260916);
  let accepted = 0, refused = 0;
  for (let i = 0; i < 600; i++) {
    const body = genBody(r);
    const fx = { shopName: pick(r, ['Khayt', 'Al Noor', '']), id: `intake-${i}`, nowIso: '2027-01-15T09:16:00.000Z',
      quoted: genQuoted(r) };
    const expected = await originalSubmission(JSON.stringify(body), fx);
    const got = LanIntake.submission(body, { shopName: fx.shopName, id: fx.id, nowIso: fx.nowIso, quoted: fx.quoted });
    assert.deepEqual(got, expected, `case ${i}: ${JSON.stringify(body)}`);
    if (got.ok) accepted++; else refused++;
  }
  // Both branches exercised, or the comparison proves nothing.
  assert.ok(accepted > 50 && refused > 50, `accepted ${accepted}, refused ${refused}`);
});

test('the refusals read as they always have', () => {
  const now = { nowIso: '2027-01-15T09:16:00.000Z', id: 'i', shopName: 'S' };
  assert.deepEqual(LanIntake.submission({ description: 'd', consent: true }, now), { ok: false, status: 400, error: 'name is required' });
  assert.deepEqual(LanIntake.submission({ name: 'n', consent: true }, now), { ok: false, status: 400, error: 'description is required' });
  assert.deepEqual(LanIntake.submission({ name: 'n', description: 'd' }, now),
    { ok: false, status: 400, error: 'Please agree to the privacy notice to submit your request.' });
  const ok = LanIntake.submission({ name: 'n', description: 'd', consent: 'true', referenceLink: 'javascript:x' }, now);
  assert.equal(ok.ok, true);
  assert.equal(ok.entry.referenceLink, undefined, 'a non-http link was kept');
  assert.equal(ok.entry.consent.text, 'I agree that S may store my contact details to process this request.');
});

test('the rate bucket advances as the server\'s bumpRate did', () => {
  let rec = null;
  const t0 = 1_000_000;
  for (let i = 0; i < 20; i++) {
    const step = LanIntake.bumpRate(rec, t0 + i, 20);
    assert.equal(step.allowed, true, `call ${i + 1}`);
    rec = step.rec;
  }
  assert.equal(LanIntake.bumpRate(rec, t0 + 30, 20).allowed, false, 'the 21st was allowed');
  // The window passes and the bucket empties.
  const later = LanIntake.bumpRate(rec, t0 + LanIntake.SUBMIT_WINDOW_MS + 1, 20);
  assert.equal(later.allowed, true);
  assert.equal(later.rec.count, 1);
});
