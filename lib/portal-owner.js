'use strict';
/**
 * The shop's side of the customer portal (KhaytPortalOwner): publishing a
 * job's link, taking it down, reading what the customer did with it, and the
 * conversation behind it.
 *
 * `lib/portal-refresh.js` already decides WHAT a link says and whether a move
 * owes it a republish. This is the rest of what `renderer/integrations.js`
 * decided inline around it — lifted so the Mac, which cannot run that file,
 * asks the same questions and gets the same answers:
 *
 *   portalUrl     the link a customer is sent
 *   paths         the owner routes (khayt-cloud docs/api-contract.md)
 *   trialGate     may this shop publish now, and does publishing start a clock
 *   depositForm   a quote's optional deposit and pay link, as typed
 *   responseFor   what the customer did with a quote: approve, decline, pay
 *   errorFor      a refusal from the cloud, in words a shop can act on
 *   linkNote      the 200 that published but did not link the customer
 *
 * ── THREE THINGS THE INLINE VERSION GOT WRONG ─────────────────────────────
 *
 * 1. THE LINK WAS CONCATENATED. `c.url.replace(/\/$/, '') + '/p/' + token`:
 *    one trailing slash removed, the token pasted raw. A server address typed
 *    with two slashes produced `//p/…`, and a token is opaque, so it is
 *    encoded here like every other path segment the cloud client builds.
 * 2. A DEPOSIT WAS WHATEVER WAS TYPED. `dep ? +dep : null` stored NaN for
 *    "abc" and a negative for "-50", and the portal then asked the customer
 *    for "NaN" or a refund. Now a finite amount above zero, or none.
 * 3. A PAY LINK WAS ANY TEXT. The quote's pay link went onto a public page
 *    unchecked — `javascript:` included. Only an http(s) address is kept,
 *    which is the test `portal-refresh.js` already applied to the balance's
 *    pay link and not to the quote's.
 *
 * Pure: no DOM, no network, no clock but the one passed in. Shared by the
 * desktop and, bundled, the Mac.
 */
(function (global) {
  const sibling = (name) => (typeof globalThis !== 'undefined' ? globalThis[name] : undefined);
  const seg = (v) => encodeURIComponent(String(v == null ? '' : v));

  /** The page a customer is sent: `<cloud>/p/<token>`. */
  function portalUrl(baseUrl, pubToken) {
    const base = String(baseUrl || '').trim().replace(/\/+$/, '');
    const tok = String(pubToken || '');
    if (!base || !tok) return '';
    return base + '/p/' + seg(tok);
  }

  /** The owner routes, each one segment-encoded. */
  const paths = {
    list: (shopId) => `/v1/shops/${seg(shopId)}/published`,
    item: (shopId, tok) => `/v1/shops/${seg(shopId)}/published/${seg(tok)}`,
    // The OWNER's thread route, never the customer's `/v1/p/{t}/messages`:
    // that one is gated on the customer's own session (PORTAL_READ_GATE), and
    // `lib/cloud-client.js portalMessages` explains why there is no fallback.
    messages: (shopId, tok) => `/v1/shops/${seg(shopId)}/published/${seg(tok)}/messages`,
    reply: (shopId, tok) => `/v1/shops/${seg(shopId)}/published/${seg(tok)}/message`,
  };

  /**
   * May this shop publish now, and should publishing start the trial clock?
   *
   * `integrations.js portalTrialAllows`, without the toast and the save: the
   * decision to WRITE `portalTrialStartedAt` is the caller's, made explicit
   * by `startAt` being non-null. A missing trial module means no trial to
   * enforce — the direction that can only leave the portal working.
   */
  function trialGate(cloud, now) {
    const Trial = sibling('KhaytPortalTrial');
    if (!Trial) return { allowed: true, startAt: null, state: null };
    const Plans = sibling('KhaytCloudPlans');
    const c = cloud || {};
    const input = {
      betaFree: Plans ? Plans.isBetaFree() : true,
      subscribed: c.planActive === true,
      startedAt: c.portalTrialStartedAt || null,
      now,
    };
    const s = Trial.portalTrialState(input);
    if (!s.available) return { allowed: false, startAt: null, state: s };
    return { allowed: true, startAt: Trial.trialStartOnPublish(input), state: s };
  }

  /** An http(s) address, or ''. */
  function httpUrl(v) {
    const s = String(v == null ? '' : v).trim();
    return /^https?:\/\/[^\s]+$/i.test(s) ? s : '';
  }

  /**
   * A quote's deposit and pay link, as typed into the publish dialog.
   *
   * { ok, cloudDeposit, cloudPayUrl, lastPayUrl } — `cloudDeposit` null for
   * none, `lastPayUrl` set only when a link was given (the dialog remembers
   * the last one for next time). `ok:false` with `error` for a deposit that is
   * not a positive number or a link that is not an http(s) address.
   */
  function depositForm(depositText, payUrlText) {
    const depRaw = String(depositText == null ? '' : depositText).trim();
    const payRaw = String(payUrlText == null ? '' : payUrlText).trim();
    let cloudDeposit = null;
    if (depRaw) {
      // A plain decimal, or one with proper thousands grouping — and nothing
      // else. Every comma was stripped, so "12,50" (a decimal comma) became
      // 1250 and "1,5" became 15; `Number` also took "0x10" as 16. A comma
      // that is not a thousands separator is refused, not guessed at.
      const plain = /^\d+(\.\d+)?$/.test(depRaw);
      const grouped = /^\d{1,3}(,\d{3})+(\.\d+)?$/.test(depRaw);
      if (!plain && !grouped) return { ok: false, error: 'deposit' };
      const n = Number(depRaw.replace(/,/g, ''));
      if (!Number.isFinite(n) || n < 0) return { ok: false, error: 'deposit' };
      const cents = Math.round(n * 100) / 100;
      // Under a cent rounds to nothing: say so rather than store no deposit.
      if (n > 0 && cents === 0) return { ok: false, error: 'deposit' };
      cloudDeposit = cents > 0 ? cents : null;
    }
    const cloudPayUrl = payRaw ? httpUrl(payRaw) : '';
    if (payRaw && !cloudPayUrl) return { ok: false, error: 'pay_url' };
    return { ok: true, cloudDeposit, cloudPayUrl: cloudPayUrl || null, lastPayUrl: cloudPayUrl || null };
  }

  /**
   * What the customer did with this link: the "Check response" answer.
   *
   * `items` is `GET /published`'s list. `response` is 'none' | 'approved' |
   * 'declined'; `paid` is the payment provider's word. `advance` is true when
   * an approval should move the job on — only for a job still a quote, as the
   * desktop moved it, through the shop's own status rule.
   *
   * THE CLOUD CALLS A DECLINE `reject`. This read only `decline`, the word the
   * retired PHP backend used, so against the live cloud a customer who
   * declined a quote was reported as "no response yet" on the Mac and the
   * desktop alike (found Nov 12 2026 while adding `stale`). Both words are a
   * decline.
   *
   * `stale` is true when the decline answered an EARLIER version of the quote:
   * the shop has since re-published the same link with a different amount,
   * currency, items or validity, and the customer has not answered the new
   * one. The cloud works that out (`actionStale` on the item, Khayt Cloud
   * #209); nothing here computes a signature. `response` stays 'declined', so
   * every count and filter that asks for a decline is unchanged, and only the
   * wording looks at `stale`.
   */
  function responseFor(items, pubToken, order) {
    const list = Array.isArray(items) ? items : [];
    const item = list.find((x) => x && String(x.token) === String(pubToken || '')) || null;
    if (!item) return { found: false, response: 'none', paid: false, advance: false, stale: false };
    const act = item.action && typeof item.action === 'object' ? item.action : null;
    const paid = !!(item.payment && item.payment.status === 'paid');
    const type = act && act.type ? String(act.type) : '';
    const declined = type === 'reject' || type === 'decline';
    const response = type === 'approve' ? 'approved' : (declined ? 'declined' : 'none');
    const advance = response === 'approved' && !!order && order.status === 'quote';
    const stale = response === 'declined' && item.actionStale === true;
    return { found: true, response, paid, advance, stale, note: act && act.note ? String(act.note) : '' };
  }

  /**
   * A refusal from the cloud, as a key the caller words and a fallback.
   *
   * { code, text }: `code` is one of 'viewer' | 'other_shop' | 'too_large' |
   * 'not_this_shop' | 'rate' | 'bad_request' | 'server', and `text` is the
   * server's own reason when it gave one.
   */
  function errorFor(status, body) {
    const said = body && typeof body === 'object' && typeof body.error === 'string' ? body.error : '';
    const code = status === 403 ? 'viewer'
      : status === 409 ? 'other_shop'
      : status === 413 ? 'too_large'
      : status === 404 ? 'not_this_shop'
      : status === 429 ? 'rate'
      : status === 400 ? 'bad_request'
      : 'server';
    return { code, text: said || `HTTP ${status}` };
  }

  /**
   * Published, but the customer's email was not linked — the shop's daily
   * allowance of new customer addresses is spent. The link still works; the
   * customer just cannot sign in to it today. Null when there is nothing to say.
   */
  function linkNote(body) {
    if (!body || typeof body !== 'object') return null;
    if (body.customerEmailLinked === false) return String(body.note || 'link_cap');
    return null;
  }

  /** The thread, newest last, each message a { from, text, at } the screen can trust. */
  function threadFrom(body) {
    const list = body && Array.isArray(body.messages) ? body.messages : [];
    return list
      .filter((m) => m && typeof m.text === 'string' && m.text.trim())
      .map((m) => ({ from: m.from === 'shop' ? 'shop' : 'customer', text: String(m.text), at: Number(m.at) || 0 }))
      .sort((a, b) => a.at - b.at);
  }

  // ── A PORTAL PAYMENT, RECORDED ON THE JOB ONCE ────────────────────────────
  //
  // `responseFor(...).paid` was only ever SAID: "deposit paid" on the sheet,
  // and the shop then typed the same money in by hand. This writes it, through
  // the shop's own payment rule (`KhaytOrderPayment.recordPayment`), so the
  // status, the cap at what was billed and every effect a payment owes are the
  // ones a payment typed in gets.
  //
  // EXACTLY ONCE. Each payment is keyed — the provider's reference when it
  // gave one, else the moment the cloud took it — and the key goes on the job
  // (`portalPayments`) in the same write as the money. A second "Check
  // response", the Mac's own timer, or the other app reading the same item
  // after a sync all find the key and change nothing.
  //
  // NOT TWICE WHEN THE SHOP GOT THERE FIRST. A deposit already typed in by
  // hand — same amount, dated within `MATCH_DAYS` of the portal's — is noted
  // against the key and not added again. The job's paid figure is a running
  // total, not a list of payments, so the amount and the date are what can be
  // matched.
  //
  // THE JOB'S OWN CURRENCY. The portal asks for the job's own figures
  // (`portal-refresh.js` builds `depositAmount` from `cloudDeposit` and
  // `amount` from the job's gross), so the payment is in them too and goes
  // onto `paidAmount` as it is. The stored `fxRate` is copied onto the note so
  // the base-currency figure is the one the job was saved at. Revenue is never
  // touched here: it is read net of tax from the job by the reports, as for
  // any payment.

  /** Two payments this many days apart, of one amount, are the same one. */
  const MATCH_DAYS = 3;
  /** How many portal payments a job remembers. */
  const KEEP_PAYMENTS = 50;

  const cents = (n) => Math.round((+n || 0) * 100) / 100;

  /** `YYYY-MM-DD`, local, of a time in milliseconds; '' for none. */
  function localDay(ms) {
    const n = Number(ms);
    if (!Number.isFinite(n) || n <= 0) return '';
    const d = new Date(n);
    const p = (v) => String(v).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  /** Whole days between two `YYYY-MM-DD` days, or null. */
  function daysApart(a, b) {
    const da = Date.parse(String(a || '').slice(0, 10) + 'T00:00:00');
    const db = Date.parse(String(b || '').slice(0, 10) + 'T00:00:00');
    if (!Number.isFinite(da) || !Number.isFinite(db)) return null;
    return Math.abs(Math.round((da - db) / 86400000));
  }

  /**
   * The key one portal payment is recorded under: the provider's reference,
   * else the moment the cloud took it, else the link itself.
   */
  function paymentKey(pubToken, payment) {
    const p = payment || {};
    const ref = String(p.ref == null ? '' : p.ref).trim();
    if (ref) return 'ref:' + ref;
    if (Number(p.at) > 0) return 'at:' + String(pubToken || '') + ':' + Number(p.at);
    return 'tok:' + String(pubToken || '');
  }

  /**
   * The amount a portal payment was for: the provider's figure when it gave
   * one, else the deposit the link asked for. 0 when neither says.
   */
  function paymentAmount(payment, order) {
    const said = String(payment && payment.amount != null ? payment.amount : '').trim().replace(/,/g, '');
    const n = /^\d+(\.\d+)?$/.test(said) ? Number(said) : NaN;
    if (Number.isFinite(n) && n > 0) return cents(n);
    const asked = +(order && order.cloudDeposit);
    return Number.isFinite(asked) && asked > 0 ? cents(asked) : 0;
  }

  /**
   * Record a payment the customer made through the portal, once.
   *
   * `items`/`pubToken` as for `responseFor`. `ctx`: `{ today, settings }` —
   * `today` the local `YYYY-MM-DD` for a payment with no time of its own.
   *
   * MUTATES `order` (as `recordPayment` does) for every outcome but `none`
   * and `already`. Returns `{ outcome, amount, key, effects, notices }`:
   *
   *   none       nothing paid on this link
   *   already    this payment is on the job; nothing changed
   *   recorded   the payment was added; `effects` are recordPayment's
   *   matched    the shop had typed it in by hand; noted, not added
   *   settled    the job owed nothing more; noted, not added
   *   no_amount  paid, but neither the provider nor the link says how much;
   *              noted, so it is said once and not on every look
   *
   * `amount` is in the job's own currency. `effects` is empty except for
   * `recorded`, where the caller performs them as for any payment; for the
   * other noted outcomes the caller saves.
   */
  function recordPortalPayment(items, pubToken, order, ctx) {
    const c = ctx || {};
    const none = { outcome: 'none', amount: 0, key: '', effects: [], notices: [] };
    if (!order || typeof order !== 'object') return none;
    const list = Array.isArray(items) ? items : [];
    const item = list.find((x) => x && String(x.token) === String(pubToken || '')) || null;
    const payment = item && item.payment && typeof item.payment === 'object' ? item.payment : null;
    if (!payment || payment.status !== 'paid') return none;

    const key = paymentKey(pubToken, payment);
    const seen = Array.isArray(order.portalPayments) ? order.portalPayments : [];
    if (seen.some((p) => p && p.key === key)) {
      return { outcome: 'already', amount: 0, key, effects: [], notices: [] };
    }

    const amount = paymentAmount(payment, order);
    const day = localDay(payment.at) || c.today || '';
    const note = (outcome, recorded) => {
      const entry = { key, outcome, amount, recorded: cents(recorded), day };
      const Money = sibling('KhaytOrderMoney');
      const code = Money && typeof Money.orderCurrency === 'function'
        ? Money.orderCurrency(order, { settings: c.settings || {}, clients: c.clients || [] })
        : order.currency;
      if (code) entry.currency = String(code);
      if (order.fxRate != null && Number.isFinite(+order.fxRate)) entry.fxRate = +order.fxRate;
      if (payment.ref) entry.ref = String(payment.ref).slice(0, 120);
      order.portalPayments = seen.concat([entry]).slice(-KEEP_PAYMENTS);
    };

    if (!(amount > 0)) {
      note('no_amount', 0);
      return { outcome: 'no_amount', amount: 0, key, effects: [], notices: [] };
    }

    const Pay = sibling('KhaytOrderPayment');
    const paid = +order.paidAmount || 0;
    const byHand = [+order.paidAmount, +order.depositAmount]
      .some((v) => Number.isFinite(v) && v > 0 && Math.abs(v - amount) <= 0.01);
    const apart = daysApart(order.paidAt, day);
    if (paid > 0 && byHand && apart != null && apart <= MATCH_DAYS) {
      note('matched', 0);
      return { outcome: 'matched', amount, key, effects: [], notices: [] };
    }

    // `cashDue(...).cash` is the most the job's paid figure can reach (billed,
    // less credit notes and gift cards); what is left is that, less what is in.
    const room = Pay && typeof Pay.cashDue === 'function' ? Pay.cashDue(order, c).cash - paid : Infinity;
    if (!Pay || !(room > 0.005)) {
      note('settled', 0);
      return { outcome: 'settled', amount, key, effects: [], notices: [] };
    }

    const r = Pay.recordPayment(order, { amount: cents(paid + amount), method: 'other', paidAt: day || null },
      { today: c.today, settings: c.settings });
    note('recorded', (+order.paidAmount || 0) - paid);
    return { outcome: 'recorded', amount: cents((+order.paidAmount || 0) - paid), key,
      effects: r.effects, notices: r.notices || [] };
  }

  /**
   * Take back a portal payment that was recorded — the shop had typed the same
   * deposit in by hand, further apart than `MATCH_DAYS`, so it was counted
   * twice.
   *
   * What was ADDED comes off the job's paid figure and the status is derived
   * again. The note STAYS, with `outcome: 'undone'`: its key is what tells a
   * later check (this app's timer, the other app) that this payment has been
   * seen, so removing it would have the next look record it all over again.
   * No webhook or email: nothing new was received.
   *
   * MUTATES `order`. `{ ok, amount }` — `ok:false` when there is no recorded
   * payment under `key` (already undone, or never recorded).
   */
  function undoPortalPayment(order, key, ctx) {
    const c = ctx || {};
    const seen = order && Array.isArray(order.portalPayments) ? order.portalPayments : [];
    const entry = seen.find((p) => p && p.key === key && p.outcome === 'recorded');
    if (!entry) return { ok: false, amount: 0 };
    const back = cents(entry.recorded);
    const paid = Math.max(0, cents((+order.paidAmount || 0) - back));
    order.paidAmount = paid;
    if (!(paid > 0)) { order.paidAt = null; order.paymentMethod = null; }
    const Pay = sibling('KhaytOrderPayment');
    if (Pay && typeof Pay.statusOf === 'function') order.paymentStatus = Pay.statusOf(order, c);
    entry.outcome = 'undone';
    if (c.now) entry.undoneAt = String(c.now);
    return { ok: true, amount: back };
  }

  const api = { portalUrl, paths, trialGate, depositForm, responseFor, errorFor, linkNote, threadFrom, httpUrl,
    recordPortalPayment, undoPortalPayment, paymentKey, paymentAmount, MATCH_DAYS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPortalOwner = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
