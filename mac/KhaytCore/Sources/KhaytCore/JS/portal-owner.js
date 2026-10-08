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
      const n = Number(depRaw.replace(/,/g, ''));
      if (!Number.isFinite(n) || n < 0) return { ok: false, error: 'deposit' };
      cloudDeposit = n > 0 ? Math.round(n * 100) / 100 : null;
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
   */
  function responseFor(items, pubToken, order) {
    const list = Array.isArray(items) ? items : [];
    const item = list.find((x) => x && String(x.token) === String(pubToken || '')) || null;
    if (!item) return { found: false, response: 'none', paid: false, advance: false };
    const act = item.action && typeof item.action === 'object' ? item.action : null;
    const paid = !!(item.payment && item.payment.status === 'paid');
    const type = act && act.type ? String(act.type) : '';
    const response = type === 'approve' ? 'approved' : (type === 'decline' ? 'declined' : 'none');
    const advance = response === 'approved' && !!order && order.status === 'quote';
    return { found: true, response, paid, advance, note: act && act.note ? String(act.note) : '' };
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

  const api = { portalUrl, paths, trialGate, depositForm, responseFor, errorFor, linkNote, threadFrom, httpUrl };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPortalOwner = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
