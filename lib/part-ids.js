'use strict';

/**
 * A stable id for every part of a job, given once and kept.
 *
 * ── WHY ──────────────────────────────────────────────────────────────────
 *
 * Parts written by the desktop calculator before it minted ids
 * (`renderer/build.js snapshotPartFromForm`) have none. The Mac made one up
 * with `UUID()` on EVERY read (`Order.Part`), so a part opened in a sheet had
 * a different id by the time it was saved, and the Mac had to find it again
 * by its place in the job — which a reload or a reorder breaks. Three of the
 * shop's twenty-two parts were like that on Nov 16.
 *
 * The fix is to give such a part an id once and write it into the book. The
 * id is made from what is already there, never from a clock or a random
 * source, so two computers that do this to the same book at the same time
 * write the SAME id: sync then sees one record sent twice (its fingerprint
 * leaves out `rev` and `updatedAt`, `lib/sync.js`), not two edits to choose
 * between.
 *
 * ── THE ID, EXACTLY ──────────────────────────────────────────────────────
 *
 * Pinned by `test/part-ids.test.js`; the Mac runs the same vectors through
 * its bundled copy (`PartIdsParityTests`), so V8 and JavaScriptCore are held
 * to one answer.
 *
 *   text = orderId + U+001F + index (base 10) + U+001F + stableJson(part without `id`)
 *   id   = 'PRT-' + cyrb53(text, seed 0) in base 36, left-padded with '0' to 11
 *
 * `stableJson` is JSON with every object's keys sorted by UTF-16 code unit
 * (the default `Array.prototype.sort`), no whitespace, numbers and strings
 * as `JSON.stringify` writes them (so 1.0 is `1`, and non-ASCII text such as
 * Arabic is written as itself, not escaped), and a key whose value is
 * `undefined` or a function left out, as `JSON.stringify` leaves it out.
 * cyrb53 hashes UTF-16 code units (`charCodeAt`), which the language fixes.
 *
 * The index is in the text so two identical parts of one job get two ids. A
 * made id that another part of the same job already holds gets `-<index>`
 * appended; that cannot happen by chance in practice, but if it did the
 * answer would still be the same on every computer.
 */
(function (global) {

  const SEP = '\u001f';

  function stableJson(value) {
    if (value === null || typeof value !== 'object') {
      const s = JSON.stringify(value);
      return s === undefined ? 'null' : s;
    }
    if (Array.isArray(value)) {
      return '[' + value.map((v) => (v === undefined || typeof v === 'function') ? 'null' : stableJson(v)).join(',') + ']';
    }
    const keys = Object.keys(value).filter((k) => value[k] !== undefined && typeof value[k] !== 'function').sort();
    return '{' + keys.map((k) => JSON.stringify(k) + ':' + stableJson(value[k])).join(',') + '}';
  }

  /** cyrb53 (public domain, bryc): a 53-bit hash of a string's UTF-16 code units. */
  function cyrb53(str, seed) {
    let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
    for (let i = 0; i < str.length; i++) {
      const ch = str.charCodeAt(i);
      h1 = Math.imul(h1 ^ ch, 2654435761);
      h2 = Math.imul(h2 ^ ch, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
    h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
    h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return 4294967296 * (2097151 & h2) + (h1 >>> 0);
  }

  /** The text the id is a hash of. Exposed so a test can pin it. */
  function idText(orderId, index, part) {
    const rest = {};
    for (const k of Object.keys(part || {})) if (k !== 'id') rest[k] = part[k];
    return String(orderId) + SEP + String(index) + SEP + stableJson(rest);
  }

  /** The id a part without one is given. Pure. */
  function partIdFor(orderId, index, part) {
    const h = cyrb53(idText(orderId, index, part), 0).toString(36);
    return 'PRT-' + ('00000000000' + h).slice(-11);
  }

  const hasId = (p) => typeof p.id === 'string' && p.id !== '';

  /**
   * Give every part of one job that has no id the id it is owed. MUTATES
   * `order.parts` in place; returns the ids given, `[{ index, id }]`, empty
   * when nothing was missing. A part that has an id is never touched; an
   * entry that is not an object is left alone.
   */
  function assignOrder(order) {
    const given = [];
    if (!order || typeof order !== 'object' || !Array.isArray(order.parts)) return given;
    const orderId = order.id == null ? '' : String(order.id);
    const taken = new Set();
    for (const p of order.parts) if (p && typeof p === 'object' && hasId(p)) taken.add(p.id);
    order.parts.forEach((p, index) => {
      if (!p || typeof p !== 'object' || Array.isArray(p) || hasId(p)) return;
      let id = partIdFor(orderId, index, p);
      if (taken.has(id)) id = id + '-' + index;
      taken.add(id);
      p.id = id;
      given.push({ index, id });
    });
    return given;
  }

  /**
   * Every job in `orders`, as `assignOrder`. Returns `[{ orderId, index, id }]`.
   * Idempotent: run again on its own output, it returns `[]`.
   */
  function assignPartIds(orders) {
    const out = [];
    for (const o of Array.isArray(orders) ? orders : []) {
      for (const g of assignOrder(o)) out.push({ orderId: o.id == null ? '' : String(o.id), index: g.index, id: g.id });
    }
    return out;
  }

  const api = { stableJson, cyrb53, idText, partIdFor, assignOrder, assignPartIds };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPartIds = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
