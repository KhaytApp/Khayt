'use strict';
/**
 * Keeping a shop's tags to one spelling each.
 *
 * Tags are typed into a comma-separated box with nothing to guide them, so
 * "resin", "Resin" and " resin" are three tags. The filter bar keys on the exact
 * string, which means a shop that has drifted sees three chips for one idea and
 * each of them finds a third of its own files. Nothing errors; the library just
 * quietly stops being searchable, and the more files there are the worse it is.
 *
 * A `<datalist>` cannot fix this: it matches the WHOLE value of an input, and
 * this input holds a list. So the box gets the shop's existing tags as chips
 * beside it, and what is typed is reconciled against them here.
 *
 * ── THE RULE ───────────────────────────────────────────────────────────────
 * A tag that matches one already in use, ignoring case and surrounding space,
 * IS that tag and adopts its spelling. Anything else is new and is kept exactly
 * as typed — this normalises collisions, it does not impose a house style. A
 * shop that wants "PLA+" and "pla+" to be different things is doing something
 * unusual, but lower-casing everything would also turn "ABS" into "abs", and
 * being quietly rewritten is worse than being merged with what you meant.
 *
 * Pure: no DOM, no fs.
 */
(function (global) {

  const key = (s) => String(s == null ? '' : s).trim().toLowerCase();

  /**
   * Reconcile typed tags against the ones a shop already uses.
   *
   * @param {string|string[]} raw     the tags box, or an array
   * @param {string[]} [known]        every tag already in use, any order
   * @returns {string[]} trimmed, non-empty, de-duplicated case-insensitively,
   *   in the order they were given, each spelled the way the shop already
   *   spells it where that exists.
   */
  function normaliseTags(raw, known) {
    const canon = new Map();
    for (const k of (known || [])) {
      const kk = key(k);
      // First spelling seen wins, so the answer does not depend on the order a
      // caller happened to collect the shop's tags in.
      if (kk && !canon.has(kk)) canon.set(kk, String(k).trim());
    }

    const parts = Array.isArray(raw)
      ? raw
      : String(raw == null ? '' : raw).split(',');

    const out = [];
    const seen = new Set();
    for (const part of parts) {
      const trimmed = String(part == null ? '' : part).trim();
      if (!trimmed) continue;
      const kk = key(trimmed);
      if (seen.has(kk)) continue;       // "resin, Resin" is one tag, not two
      seen.add(kk);
      out.push(canon.get(kk) || trimmed);
    }
    return out;
  }

  /**
   * Distinct tags across records, most-used first, folded by case.
   *
   * The filter bar counted the exact string, so a drifted shop saw one chip per
   * spelling and each found only its own share of the files. Folding here means
   * the chip says what the shop means and its count is the real one; the label
   * shown is the spelling used most, since that is the one they have settled on.
   *
   * @param {Array<{tags?: string[]}>} records
   * @returns {Array<[string, number]>} [label, count], most used first
   */
  function tagCounts(records) {
    const byKey = new Map();   // key -> Map(spelling -> count)
    for (const r of (records || [])) {
      // A record naming one tag twice in two spellings counts once for it.
      const once = new Set();
      for (const tg of (r && r.tags) || []) {
        const kk = key(tg);
        if (!kk || once.has(kk)) continue;
        once.add(kk);
        if (!byKey.has(kk)) byKey.set(kk, new Map());
        const spellings = byKey.get(kk);
        const s = String(tg).trim();
        spellings.set(s, (spellings.get(s) || 0) + 1);
      }
    }
    const rows = [];
    for (const spellings of byKey.values()) {
      let total = 0, best = '', bestN = -1;
      for (const [s, n] of spellings) {
        total += n;
        if (n > bestN) { bestN = n; best = s; }
      }
      rows.push([best, total]);
    }
    rows.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    return rows;
  }

  /** Does this record carry that tag, whatever either side's spelling? */
  const hasTag = (record, tag) =>
    ((record && record.tags) || []).some((t) => key(t) === key(tag));

  const api = { normaliseTags, tagCounts, hasTag, tagKey: key };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytTags = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
