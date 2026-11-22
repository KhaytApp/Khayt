'use strict';
/**
 * What the server told a visitor, so the figure attached to their submitted
 * request is OUR number rather than one their browser posted back at us.
 *
 * A browser can put any JSON it likes in a POST body. If the intake form sent
 * its own price along with the submission, a customer could file a request that
 * says the shop quoted them 5 riyals for a two-day print — and the shop would be
 * reading that number off their own screen, in their own waiting list, with
 * nothing to say it was never ours.
 *
 * So the price never travels through the customer. The estimate endpoint keeps
 * the result here and hands back an opaque reference; the submission cites the
 * reference and the server looks the real figure up.
 *
 * Entries expire, and are bound to the visitor they were issued to — a reference
 * overheard on a shared network is not a licence to attach a stale price to
 * someone else's request. Lives in its own module so those two rules can be
 * tested; inside the request handler they could not be.
 */

const DEFAULT_TTL_MS = 4 * 60 * 60 * 1000;

function createEstimateLedger(opts = {}) {
  const ttl = Number.isFinite(opts.ttlMs) ? opts.ttlMs : DEFAULT_TTL_MS;
  // Injected so a test can advance time without sleeping, and so this module
  // stays free of the wall clock.
  const now = typeof opts.now === 'function' ? opts.now : () => Date.now();
  const newId = typeof opts.newId === 'function' ? opts.newId : null;
  const map = new Map();
  let seq = 0;

  /** Drop everything past its TTL. Called on write, so no timer is needed. */
  function sweep(at) {
    for (const [k, v] of map) if (at - v.at > ttl) map.delete(k);
  }

  return {
    /** @returns {string} the reference to hand back to the visitor. */
    remember(result, ip) {
      const at = now();
      sweep(at);
      const ref = newId ? newId() : `est_${at.toString(36)}_${(seq += 1).toString(36)}`;
      map.set(ref, { at, ip: ip || '', result });
      return ref;
    },

    /**
     * @returns the stored result, or null if the reference is unknown, expired,
     * or was issued to a different visitor.
     */
    recall(ref, ip) {
      if (typeof ref !== 'string' || !ref) return null;
      const rec = map.get(ref);
      if (!rec) return null;
      if (now() - rec.at > ttl) { map.delete(ref); return null; }
      // Bound to the visitor it was issued to, the same way the intake session
      // is. An empty stored ip means we never knew, and matches nothing.
      if (rec.ip !== (ip || '')) return null;
      return rec.result;
    },

    get size() { return map.size; },
  };
}

module.exports = { createEstimateLedger, DEFAULT_TTL_MS };
