'use strict';

/**
 * What a COPY of a job or a product carries, and what it leaves behind.
 *
 * ⌘D on a Mac makes another one of the thing in front of you. For a job that
 * means "the same work again for the same customer" — the parts, who it is
 * for, what was written about it — and NOT the history of the first one: its
 * payments, its invoice number, its dates, the runs it went through on a
 * printer, what it actually weighed. A copy that kept any of those would be a
 * second record of money or work that happened once.
 *
 * ── A JOB IS NOT COPIED, IT IS TAKEN AGAIN ────────────────────────────────
 *
 * `job()` does not return a record. It returns the INPUT `lib/order-new.js`
 * `newOrder` takes, so the copy is created by exactly the rule that creates
 * every other job: a fresh id from the shop's counter, an invoice number only
 * if it is a job rather than a quote, status `pending` or `quote`, no
 * payment, no dates beyond today's. Building the record here instead would be
 * a second answer to "what is a new job", free to drift from the first. The
 * host shows it in its new-job form first, so nothing is written — and no
 * invoice number is consumed — until the shop presses Save.
 *
 * A product has no counter, so `product()` returns the record itself with the
 * id the host minted (`uid('PROD')` is not pure) — minus what belongs to the
 * original alone: its pictures and papers (files on disk the original's record
 * names; a copy pointing at the same files would take them with it when either
 * is deleted), its SKU, its sync stamps and its listing state.
 *
 * Pure: no clock, no randomness, no I/O. Inputs are never mutated.
 */
(function (global) {

  const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const str = (v) => (typeof v === 'string' ? v : '');
  /** JSON-shaped values only — which is all a book holds. */
  const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

  /**
   * A part's own history — written while the job ran, true of that run only.
   * `id` too: two jobs must not share a part id.
   */
  const PART_RUN_KEYS = [
    'id', 'partStatus', 'partMachineId', 'startedAt', 'completedAt', 'printedAt',
    'actualWeight', 'actualPrintTime', 'actualGrams', 'failedAt', 'qcStatus',
  ];

  /** The fields a job copy takes from its original, as `newOrder` reads them. */
  const JOB_CARRIED = ['project', 'clientId', 'clientRef', 'currency', 'productId'];
  /** What was written about the job. Carried: it is part of the work, not of its history. */
  const JOB_NOTES = ['notes', 'internalNotes', 'invoiceNotes'];

  /** One part, without the run it went through. */
  function freshPart(p) {
    const out = {};
    for (const k of Object.keys(p)) {
      if (PART_RUN_KEYS.includes(k)) continue;
      out[k] = clone(p[k]);
    }
    return out;
  }

  /**
   * The new-job input for another of `order`.
   *
   * A quote copies as a quote (`asQuote`) — a quote still waiting for its
   * answer is the one case where the copy is most likely a second option to
   * send the same customer. Anything else copies as a new job.
   */
  function job(order) {
    const o = isObj(order) ? order : {};
    const input = {};
    for (const k of JOB_CARRIED) {
      if (o[k] !== undefined && o[k] !== null && o[k] !== '') input[k] = clone(o[k]);
    }
    for (const k of JOB_NOTES) input[k] = str(o[k]);
    input.project = str(o.project);
    input.parts = arrayOf(o.parts).filter(isObj).map(freshPart);
    const components = arrayOf(o.components).filter((c) => isObj(c) && c.consumableId);
    if (components.length) input.components = clone(components);
    if (+o.assemblyQty > 0) input.assemblyQty = +o.assemblyQty;
    input.discountPct = Math.min(100, Math.max(0, +o.discountPct || 0));
    input.shippingCost = Math.max(0, +o.shippingCost || 0);
    // A percentage line keeps only its percentage: the amount it resolved to
    // was the ORIGINAL's price, and the copy is priced again.
    const extras = arrayOf(o.extraLines).filter(isObj).map((l) => {
      const c = clone(l);
      if (c.pct !== undefined && c.pct !== null) delete c.amount;
      return c;
    });
    if (extras.length) input.extraLines = extras;
    input.asQuote = o.status === 'quote';
    return input;
  }

  /** A product's own files and stamps — see the header. */
  const PRODUCT_DROPPED = [
    'id', 'rev', 'updatedAt', 'createdAt', 'images', 'imagePath', 'thumbnail',
    'docs', 'sku', 'storefrontHidden',
  ];

  /**
   * Another of `product`, under `ctx.id`, created `ctx.today`.
   *
   * `ctx.suffix` is the host's word for "copy", in the shop's language; it is
   * appended to every name the product has, so the copy is never mistaken for
   * the original in a list.
   */
  function product(original, ctx) {
    const p = isObj(original) ? original : {};
    const c = isObj(ctx) ? ctx : {};
    if (!str(c.id)) throw new Error('KhaytRecordDuplicate.product needs an id');
    const out = {};
    for (const k of Object.keys(p)) {
      if (PRODUCT_DROPPED.includes(k)) continue;
      out[k] = clone(p[k]);
    }
    out.id = c.id;
    if (str(c.today)) out.createdAt = c.today;
    const suffix = str(c.suffix).trim();
    if (suffix) {
      for (const k of Object.keys(out)) {
        // `name`, `nameEn`, `nameAr`, `name_fr`… — every language's name.
        if (!/^name([A-Z_].*)?$/.test(k)) continue;
        const v = str(out[k]).trim();
        if (v) out[k] = `${v} ${suffix}`;
      }
    }
    return out;
  }

  const api = { PART_RUN_KEYS, PRODUCT_DROPPED, job, product };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytRecordDuplicate = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
