'use strict';
/**
 * A link the shop sends for an approved quote, which the customer pays on the
 * shop's own web store (KhaytQuotePayLink).
 *
 * ── WHAT THIS IS FOR ──────────────────────────────────────────────────────
 *
 * The shop prices a custom print in Khayt and the customer says yes. Until
 * now the yes was followed by a bank transfer and a screenshot. The store
 * (athartuwaiq3d.com, a Medusa store taking cards) can take the money
 * properly — address, delivery priced by city, card — if it is told what was
 * agreed. This module writes that down as a signed token the store trusts:
 *
 *     https://store/sa/ar/pay/{token}
 *
 * The contract is the STORE's document, `docs/quote-pay-link.md` in its
 * repository, and its test vector is pinned in `test/quote-pay-link.test.js`.
 * Change the two together.
 *
 * ── PURE, AND IT DOES NOT SIGN ────────────────────────────────────────────
 *
 * The token is a compact JWT, HS256. The Mac runs this file in JavaScriptCore,
 * which has no HMAC, so the device does that one step (CryptoKit on the Mac,
 * `crypto` on the desktop) over `signingInput(claims)` and hands the bytes
 * back to `tokenFrom`. Everything that decides WHAT is signed is here, so the
 * two apps cannot disagree about a price. The secret never enters this file.
 *
 * ── THE RULES, AND WHY EACH ONE IS HERE ───────────────────────────────────
 *
 * THE LINES ADD UP TO THE QUOTE, IN WHOLE HALALAS. A job has one price; what
 * each part costs is a share of it (the invoice works the same shares out,
 * `lib/invoice-document.js`). Shares are floats, and a store charges integers:
 * rounded one by one, three parts of a 100.00 job charge 99.99 or 100.01 and
 * the payment no longer settles the job. So the parts are rounded by largest
 * remainder against the exact total, and a line whose total does not divide
 * by its quantity is sent as ONE line of the whole amount with the count in
 * its description. Nothing is ever rounded in a way that changes the sum.
 *
 * DELIVERY IS NOT SENT. The store prices delivery by the customer's city at
 * its checkout. A delivery charge typed on the quote is left out, and
 * `deliveryOnQuote` says how much that was so the device can tell the shop
 * before it sends (Turki, 12 Nov 2026).
 *
 * EVERY LINE CARRIES A WEIGHT. The store prices the parcel from
 * `weight_grams`: a real weight per piece for a part, 0 for a fee (nothing to
 * ship). Omitted means "guess one kilo", and the store treats omitted and 0 as
 * different quotes — so it is always sent, and a part with no weight (an
 * unsliced model) blocks the link rather than letting a guess undercharge a
 * heavy parcel.
 *
 * ONLY THE NAME GOES WITH IT. A token is signed, not sealed: whoever holds
 * the link can read it, and it sits in a URL. So the customer's name is sent
 * and their email and phone are not (Turki, 12 Nov 2026); the store asks for
 * those at checkout.
 *
 * NOT WHEN THE SHOP CHARGES TAX. The store's quote lines are pre-tax with no
 * tax added. A shop with a tax rate would be paid short, or twice, depending
 * on its mode, so the link is not offered there at all.
 */
(function (global) {

  const sibling = (name, file) => global[name]
    || (typeof require === 'function' ? (function () { try { return require(file); } catch (e) { return null; } })() : null);

  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  const str = (v) => String(v == null ? '' : v).trim();
  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };

  /** The format number the store reads (`v`). */
  const VERSION = 1;
  /** How long a link lasts, in seconds. The store refuses anything longer. */
  const LIFETIME_S = 7 * 24 * 60 * 60;
  const CURRENCY = 'SAR';
  const SHIPPING = 'lamha';
  const MAX_ITEMS = 50;
  const MAX_TOKEN = 8192;
  const MAX_WEIGHT = 1000000;
  const MAX_QTY = 10000;
  const MAX_UNIT = 100000000;
  const ID_SHAPE = /^[A-Za-z0-9._:-]{1,64}$/;
  const SECRET_MIN = 32;
  /** `{"alg":"HS256","typ":"JWT"}`, base64url. Fixed, so it is a constant. */
  const HEADER = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';

  /** SAR to halalas, without the float error of `x * 100`. */
  const halalas = (amount) => Math.round(num(amount) * 100);

  /* ── WHAT THE LINK WOULD CHARGE ───────────────────────────────────────── */

  const isAgreed = (p) => p.agreedPrice !== undefined && p.agreedPrice !== null && p.agreedPrice !== ''
    && Number.isFinite(+p.agreedPrice) && +p.agreedPrice >= 0;
  const qtyOf = (p) => Math.max(1, Math.floor(num(p && p.qty)) || 1);

  /**
   * The money on a job, split the way the store needs it: what the fees come
   * to, what is left for the parts, and what delivery was on the quote (which
   * is NOT sent). All in halalas.
   */
  function sums(order) {
    const o = isObj(order) ? order : {};
    const price = halalas(o.price);
    const delivery = Math.max(0, halalas(o.shippingCost));
    const extras = (Array.isArray(o.extraLines) ? o.extraLines : [])
      .filter(isObj).map((l) => ({ label: str(l.label), amount: halalas(l.amount) }))
      .filter((l) => l.amount !== 0);
    const rush = halalas(o.rushFeeAmount);
    const fees = extras.reduce((s, l) => s + l.amount, 0) + rush;
    return { price, delivery, extras, rush, total: price - delivery, parts: price - delivery - fees };
  }

  /**
   * Whole numbers that add up to `total`, in proportion to `weights`: each
   * gets its floor, and the units left over go to the largest remainders
   * (earliest first on a tie, so the answer is the same on every device).
   */
  function shareOut(total, weights) {
    const n = weights.length;
    if (!n) return [];
    const sum = weights.reduce((s, w) => s + Math.max(0, w), 0);
    const exact = weights.map((w) => (sum > 0 ? (Math.max(0, w) / sum) * total : total / n));
    const out = exact.map((x) => Math.floor(x));
    let left = total - out.reduce((s, x) => s + x, 0);
    const order = exact.map((x, i) => [x - Math.floor(x), i]).sort((a, b) => (b[0] - a[0]) || (a[1] - b[1]));
    for (let k = 0; left > 0 && k < order.length; k++, left--) out[order[k][1]] += 1;
    return out;
  }

  /** One line of text saying what a part is made of. */
  function specOf(part, pieces) {
    const p = isObj(part) ? part : {};
    const bits = [str(p.material), str(p.color || p.colour)].filter(Boolean);
    // Said in the line itself when the count could not go in `quantity`.
    if (pieces > 1) bits.push('× ' + pieces);
    return bits.join(', ').slice(0, 500);
  }

  /**
   * The lines the store is asked to charge, and whether they can be sent.
   *
   * `{ items, problems }`. `problems` is a list of reasons the lines cannot be
   * trusted (`no_parts`, `no_weight`, `negative`, `too_many`, `amount`); a
   * device shows a link only when it is empty. `items` is the store's shape:
   * `{ title, spec?, quantity, unit_amount, weight_grams }`.
   *
   * `words` gives the two fee names a customer reads, in the customer's
   * language: `{ rush, extra }`.
   */
  function linesFor(order, words) {
    const o = isObj(order) ? order : {};
    const w = isObj(words) ? words : {};
    const s = sums(o);
    const problems = [];
    const parts = (Array.isArray(o.parts) ? o.parts : []).filter(isObj);
    if (!parts.length) problems.push('no_parts');
    if (s.parts < 0 || s.rush < 0 || s.extras.some((l) => l.amount < 0)) problems.push('negative');

    // The parts' shares, as the invoice works them out: a part with a price
    // the customer agreed is billed at that figure, the rest share what is
    // left by cost. The invoice shows these at list price with the discount
    // as its own row; the store has no such row, so here they are scaled to
    // what is actually charged and then made exact.
    const agreed = parts.map((p) => (isAgreed(p) ? +p.agreedPrice * qtyOf(p) * 100 : null));
    const agreedSum = agreed.reduce((t, a) => t + (a || 0), 0);
    const costed = parts.map((p, i) => (agreed[i] === null ? Math.max(0, num(p.baseCost)) : 0));
    const costedSum = costed.reduce((t, c) => t + c, 0);
    const costedCount = agreed.filter((a) => a === null).length;
    const pool = Math.max(0, s.parts);
    const rest = Math.max(0, pool - Math.min(agreedSum, pool));
    const weights = parts.map((p, i) => {
      if (agreed[i] !== null) return agreedSum > pool && agreedSum > 0 ? (agreed[i] / agreedSum) * pool : agreed[i];
      if (costedSum > 0) return (costed[i] / costedSum) * rest;
      return costedCount ? rest / costedCount : 0;
    });
    const shares = shareOut(pool, weights);

    const items = [];
    parts.forEach((p, i) => {
      const qty = qtyOf(p);
      const grams = Math.round(num(p.printWeight));
      if (!(grams >= 1)) { if (!problems.includes('no_weight')) problems.push('no_weight'); }
      const whole = shares[i] % qty === 0 && qty <= MAX_QTY;
      const line = {
        title: (str(p.name) || str(o.project) || '—').slice(0, 200),
        quantity: whole ? qty : 1,
        unit_amount: whole ? shares[i] / qty : shares[i],
        weight_grams: Math.min(MAX_WEIGHT, Math.max(0, whole ? grams : grams * qty)),
      };
      const spec = specOf(p, whole ? 1 : qty);
      if (spec) line.spec = spec;
      items.push(line);
    });
    // Fees: their own lines, nothing to ship.
    s.extras.forEach((l) => items.push({
      title: (l.label || str(w.extra) || 'Extra charge').slice(0, 200), quantity: 1, unit_amount: l.amount, weight_grams: 0,
    }));
    if (s.rush !== 0) {
      items.push({ title: (str(w.rush) || 'Rush fee').slice(0, 200), quantity: 1, unit_amount: s.rush, weight_grams: 0 });
    }
    // Key order is the store's, so a token reads like its test vector.
    const ordered = items.map((it) => {
      const out = { title: it.title };
      if (it.spec) out.spec = it.spec;
      out.quantity = it.quantity; out.unit_amount = it.unit_amount; out.weight_grams = it.weight_grams;
      return out;
    });

    if (ordered.length > MAX_ITEMS) problems.push('too_many');
    if (ordered.some((it) => !Number.isInteger(it.unit_amount) || it.unit_amount < 0 || it.unit_amount > MAX_UNIT)) {
      if (!problems.includes('negative')) problems.push('amount');
    }
    return { items: ordered, problems };
  }

  /** What the lines come to, in halalas. */
  const totalOf = (items) => (Array.isArray(items) ? items : [])
    .reduce((t, it) => t + num(it.unit_amount) * num(it.quantity), 0);

  /* ── MAY A LINK BE OFFERED ────────────────────────────────────────────── */

  /**
   * Is the store link set up on this device? `config` is
   * `{ storeUrl, hasSecret }` — the device says whether it HOLDS a secret, it
   * never passes one in here.
   */
  function configured(config) {
    const c = isObj(config) ? config : {};
    return !!storeBase(c.storeUrl) && c.hasSecret === true;
  }

  /** `https://host` (with any path the shop typed), no trailing slash; '' if it is not https. */
  function storeBase(url) {
    const u = str(url).replace(/\/+$/, '');
    return /^https:\/\/[A-Za-z0-9.-]+(:\d+)?(\/[^\s?#]*)?$/.test(u) ? u : '';
  }

  /** A secret a device may sign with: the store refuses a shorter one. */
  const secretIsUsable = (secret) => typeof secret === 'string' && secret.length >= SECRET_MIN;

  /**
   * Why a pay link cannot be offered for this job: a list of reasons, empty
   * when it can. The first is the one to show.
   *
   *   not_set_up     no store address or no secret on this device
   *   not_a_quote    the job did not begin as a quote the customer accepted
   *   closed         cancelled, voided or credited
   *   paid           nothing is owed, or something has already been paid
   *                  (the store charges the WHOLE quote)
   *   milestones     billed in stages, which the store cannot do
   *   currency       the job is not priced in riyals
   *   tax            the shop charges tax (see the note at the top)
   *   reference      the job's id or number cannot be sent as it is
   *   …and the reasons of `linesFor`
   *
   * `ctx` is `{ settings, clients, config }`.
   */
  function blockers(order, ctx) {
    const o = isObj(order) ? order : {};
    const c = isObj(ctx) ? ctx : {};
    const out = [];
    if (!configured(c.config)) out.push('not_set_up');
    if (o.status === 'quote' || !(o.quoteAcceptedAt || o.clientApprovedAt)) out.push('not_a_quote');
    if (o.status === 'cancelled' || o.voidedAt || o.creditedAt) out.push('closed');
    const paidSomething = num(o.paidAmount) > 0 || num(o.giftCardDiscount) > 0 || o.paymentStatus === 'paid';
    if (paidSomething || !(sums(o).total > 0)) out.push('paid');
    if (Array.isArray(o.milestoneInvoices) && o.milestoneInvoices.length) out.push('milestones');

    const Money = sibling('KhaytOrderMoney', './order-money.js');
    const currency = Money && typeof Money.orderCurrency === 'function'
      ? str(Money.orderCurrency(o, { settings: c.settings, clients: c.clients }))
      : str(o.currency || (c.settings && c.settings.currency));
    if (currency.toUpperCase() !== CURRENCY) out.push('currency');

    const Tax = sibling('KhaytTax', './tax.js');
    const profile = Tax && typeof Tax.profileFromSettings === 'function' ? Tax.profileFromSettings(c.settings || {}) : null;
    if (profile && Array.isArray(profile.rates) && profile.rates.length) out.push('tax');

    // Refused, never rewritten: a cleaned id could be another job's.
    if (!ID_SHAPE.test(String(o.id == null ? '' : o.id)) || !refOf(o)) out.push('reference');
    for (const p of linesFor(o).problems) if (!out.includes(p)) out.push(p);
    return out;
  }

  /** The reference a customer reads: the job's number, else its id. 1–40 characters or ''. */
  function refOf(order) {
    const o = isObj(order) ? order : {};
    const ref = str((typeof o.jobNumber === 'string' && o.jobNumber) || o.id);
    return ref.length >= 1 && ref.length <= 40 ? ref : '';
  }

  /* ── WHAT IS SIGNED ───────────────────────────────────────────────────── */

  /**
   * The claims for a job, or null when `blockers` is not empty.
   *
   * `ctx`: `{ settings, clients, config, nowSeconds, lastIssuedAt?, words?,
   * customerName?, leadDays? }`.
   *
   * `iat` is now — and always LATER than the link sent before
   * (`lastIssuedAt`), because the store refuses two different quotes with the
   * same `quote_id` and `iat`, and a re-send within the same second would be
   * exactly that.
   */
  function claimsFor(order, ctx) {
    const o = isObj(order) ? order : {};
    const c = isObj(ctx) ? ctx : {};
    if (blockers(o, c).length) return null;
    const now = Math.floor(num(c.nowSeconds));
    if (!(now > 0)) return null;
    const iat = Math.max(now, Math.floor(num(c.lastIssuedAt)) + 1);
    const claims = {
      v: VERSION,
      quote_id: String(o.id),
      ref: refOf(o),
      currency: CURRENCY,
      prices_include_vat: false,
      items: linesFor(o, c.words).items,
    };
    const lead = isObj(c.leadDays) ? c.leadDays : null;
    if (lead && Number.isInteger(lead.min) && Number.isInteger(lead.max)
        && lead.min >= 0 && lead.max >= lead.min && lead.max <= 365) {
      claims.lead_time_days = { min: lead.min, max: lead.max };
    }
    // The name and nothing else (see the note at the top).
    const name = str(c.customerName).slice(0, 120);
    if (name) claims.customer = { name };
    claims.shipping = SHIPPING;
    claims.iat = iat;
    claims.exp = iat + LIFETIME_S;
    return claims;
  }

  /** What delivery was on the quote, in riyals: the figure the link leaves out. 0 when there was none. */
  const deliveryOnQuote = (order) => sums(order).delivery / 100;

  /** What the link charges before the store adds delivery, in riyals. */
  const amountOf = (claims) => totalOf(claims && claims.items) / 100;

  /* ── THE TOKEN ────────────────────────────────────────────────────────── */

  /** UTF-8 bytes of a string. Hand-written: JavaScriptCore has no TextEncoder. */
  function utf8(text) {
    const out = [];
    const s = String(text);
    for (let i = 0; i < s.length; i++) {
      let cp = s.charCodeAt(i);
      if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
        const lo = s.charCodeAt(i + 1);
        if (lo >= 0xdc00 && lo <= 0xdfff) { cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00); i++; }
      } else if (cp >= 0xd800 && cp <= 0xdfff) {
        cp = 0xfffd; // a lone half: what every UTF-8 encoder writes
      }
      if (cp >= 0xdc00 && cp <= 0xdfff) cp = 0xfffd;
      if (cp < 0x80) out.push(cp);
      else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
      else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
    }
    return out;
  }

  const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  /** base64url without padding (RFC 4648 section 5), from bytes. */
  function base64url(bytes) {
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
      out += B64[a >> 2] + B64[((a & 3) << 4) | ((b === undefined ? 0 : b) >> 4)];
      if (b !== undefined) out += B64[((b & 15) << 2) | ((c === undefined ? 0 : c) >> 6)];
      if (c !== undefined) out += B64[c & 63];
    }
    return out;
  }

  /**
   * The ASCII string the device runs HMAC-SHA256 over, with the secret's
   * UTF-8 bytes as the key: `header.payload`. The payload is the claims as
   * JSON with no spaces, in the order `claimsFor` built them.
   */
  function signingInput(claims) {
    if (!isObj(claims)) return '';
    return HEADER + '.' + base64url(utf8(JSON.stringify(claims)));
  }

  /**
   * The finished token: the signing input and the 32 HMAC bytes the device
   * computed (an array of numbers, or their base64url text). '' when either
   * is not what it should be, or the token is longer than the store reads.
   */
  function tokenFrom(input, signature) {
    const head = str(input);
    if (head.indexOf(HEADER + '.') !== 0 || head.split('.').length !== 2) return '';
    let sig = '';
    if (typeof signature === 'string') sig = /^[A-Za-z0-9_-]{43}$/.test(signature) ? signature : '';
    else if (signature && signature.length === 32) sig = base64url(Array.prototype.slice.call(signature).map((b) => b & 255));
    if (!sig) return '';
    const token = head + '.' + sig;
    return token.length < MAX_TOKEN ? token : '';
  }

  /**
   * The link to send: `{store}/sa/{ar|en}/pay/{token}`. The token is
   * URL-safe as it is and must not be percent-encoded. Arabic unless the
   * customer is known to read English.
   */
  function urlFor(storeUrl, locale, token) {
    const base = storeBase(storeUrl);
    if (!base || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(str(token))) return '';
    return `${base}/sa/${str(locale).toLowerCase().indexOf('en') === 0 ? 'en' : 'ar'}/pay/${token}`;
  }

  /**
   * What the job remembers about the link it sent, so the next send is later
   * than this one and the device can say when it runs out:
   * `{ issuedAt, expiresAt, amount }` (seconds, seconds, riyals).
   */
  function recordOf(claims) {
    if (!isObj(claims)) return null;
    return { issuedAt: claims.iat, expiresAt: claims.exp, amount: amountOf(claims) };
  }

  const api = {
    VERSION, LIFETIME_S, CURRENCY, SECRET_MIN, MAX_ITEMS, HEADER,
    configured, storeBase, secretIsUsable, blockers, refOf, sums, shareOut, linesFor, totalOf,
    claimsFor, deliveryOnQuote, amountOf, utf8, base64url, signingInput, tokenFrom, urlFor, recordOf,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytQuotePayLink = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
