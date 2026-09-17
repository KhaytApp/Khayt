'use strict';

/**
 * Where a shop's customers came from.
 *
 * A client record carries a `source`. The customer form offers six:
 * `instagram`, `referral`, `walk_in`, `website`, `exhibition`, `other`. The
 * analytics chart drew a bar per source and the revenue beside it, iterating
 * that same six.
 *
 * It was not the only writer. Importing an order request from the intake form
 * creates the customer with `source: 'online'` — a seventh value the chart had
 * never heard of. It counted them into a bucket it then never read, so **every
 * customer who came in through the shop's own intake form, and all of their
 * revenue, was missing from the chart that claims to say where customers come
 * from**. The same value reached the customer list's badge as
 * `t('cl.source_online')`, which no locale had, so the badge printed the
 * literal string `cl.source_online` beside the customer's name.
 *
 * So the list lives here, `online` is in it, and `normalize()` folds anything
 * else onto `other` rather than dropping it. Losing a customer from a chart is
 * worse than filing them under "Other": the shop reads that chart to decide
 * where to spend, and a source that shows nothing looks like a source that
 * brought nothing.
 *
 * `test/client-sources-agree.test.js` is the other half. It fails if any code
 * writes a source this list does not have, and if any locale is missing a name
 * for one — the two ways this broke.
 *
 * ── THE REVENUE, WHICH WAS COUNTING THINGS THE REST OF THE SCREEN DOES NOT ──
 * Every other revenue rollup on the Reports screen takes finished, unvoided,
 * business-scoped jobs. This chart took finished jobs and nothing else, so a
 * voided order and a job the shop had marked personal both counted as money a
 * source had brought in. It takes the same filters as its neighbours now, from
 * the caller, because what counts as "business" is a setting the renderer
 * holds and this module should not reimplement.
 */
(function (global) {

  /**
   * Every source a client record can carry, in the order the form offers them.
   *
   * `online` is not on the form and cannot be picked: it is stamped by the
   * intake import, which is why it was missed. `other` stays last, because it
   * is the fallback rather than a choice like the others.
   */
  const SOURCES = [
    'instagram', 'referral', 'walk_in', 'website', 'online', 'exhibition', 'other',
  ];

  /** Where a client with no source, or an unrecognised one, is filed. */
  const DEFAULT_SOURCE = 'other';

  const KNOWN = new Set(SOURCES);

  /**
   * Fold a stored source onto one this app can name and draw.
   *
   * Anything unknown becomes `other` rather than a bucket of its own. That is
   * deliberate: an unknown source drawn under its own raw key would put an
   * untranslated string in front of a shop, and one silently dropped loses a
   * customer from the count. "Other" is true, readable, and visible.
   */
  function normalize(value) {
    const raw = String(value == null ? '' : value).trim();
    if (!raw) return DEFAULT_SOURCE;
    return KNOWN.has(raw) ? raw : DEFAULT_SOURCE;
  }

  /** True when the stored value is one this app knows by name. */
  function isKnown(value) {
    const raw = String(value == null ? '' : value).trim();
    return raw !== '' && KNOWN.has(raw);
  }

  function num(v) {
    const n = +v;
    return Number.isFinite(n) ? n : 0;
  }

  /**
   * How many customers came from each source, and what they have spent.
   *
   * `data.clients` and `data.orders` are the book's own arrays.
   *
   * `deps` supplies the things only a host knows:
   *   - `revenueOf(order)`      net revenue in the shop's base currency
   *   - `isFinished(order)`     whether the work is done, both spellings
   *   - `countsForBusiness(o)`  whether the job is the shop's business at all
   *
   * Every one has a safe default, so a host that has not wired a dependency
   * gets zero revenue rather than a wrong figure or a throw.
   *
   * Returns `{ rows, totalClients, totalRevenue }`. `rows` holds only sources
   * at least one customer carries, biggest first, ties broken by the canonical
   * order so two renders of one book never disagree.
   */
  function byClient(data, deps) {
    const d = data || {};
    const h = deps || {};
    const revenueOf = typeof h.revenueOf === 'function' ? h.revenueOf : () => 0;
    const isFinished = typeof h.isFinished === 'function' ? h.isFinished : () => false;
    const countsForBusiness = typeof h.countsForBusiness === 'function'
      ? h.countsForBusiness
      : () => true;

    const counts = new Map();
    const revenue = new Map();
    SOURCES.forEach(s => { counts.set(s, 0); revenue.set(s, 0); });

    const sourceById = new Map();
    (d.clients || []).forEach(c => {
      if (!c) return;
      const src = normalize(c.source);
      counts.set(src, counts.get(src) + 1);
      if (c.id) sourceById.set(c.id, src);
    });

    let totalRevenue = 0;
    (d.orders || []).forEach(o => {
      if (!o || !o.clientId) return;
      // The same three the rest of the screen applies. Counting a voided order
      // or a personal job here made this chart's money disagree with the
      // revenue printed above it.
      if (!isFinished(o)) return;
      if (o.voidedAt) return;
      if (!countsForBusiness(o)) return;
      const src = sourceById.get(o.clientId);
      // An order whose customer has been deleted belongs to no source. It is
      // left out rather than filed under "Other", which would claim a source
      // brought in money it did not.
      if (!src) return;
      const amount = num(revenueOf(o));
      revenue.set(src, revenue.get(src) + amount);
      totalRevenue += amount;
    });

    const order = new Map(SOURCES.map((s, i) => [s, i]));
    const rows = SOURCES
      .filter(s => counts.get(s) > 0)
      .map(s => ({ source: s, count: counts.get(s), revenue: revenue.get(s) }))
      .sort((a, b) => (b.count - a.count) || (order.get(a.source) - order.get(b.source)));

    return {
      rows,
      totalClients: (d.clients || []).filter(Boolean).length,
      totalRevenue,
    };
  }

  const api = { SOURCES, DEFAULT_SOURCE, normalize, isKnown, byClient };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytClientSources = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
