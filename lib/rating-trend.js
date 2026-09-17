'use strict';

/**
 * What customers have said about the work, month by month.
 *
 * A finished job can carry `survey.rating`, one to five. The Reports screen
 * draws the last six months of that as a line and captions it with a count and
 * an average.
 *
 * The caption was computed from a different set of jobs than the line. The line
 * covered six months; the count and the average covered **every rating the shop
 * had ever collected**. A shop two years in, whose work has got better, saw six
 * dots at 4.8 under the words "Avg 3.2 / 5" — a figure that contradicts every
 * point above it and is not wrong so much as an answer to a question nobody
 * asked. The caption describes the window now.
 *
 * The other half is which jobs count at all. A rated job was taken only if it
 * carried `completedAt`. That timestamp is stamped when a job is moved to
 * completed, so a book written before it existed, an imported one, or a job
 * that went straight to `delivered` has a rating and no `completedAt` — and a
 * rating a customer actually gave was dropped. It falls back to the job's own
 * date, the way the rest of Khayt reads a finish date.
 *
 * The caller supplies the months it wants to draw, because how many to show is
 * a decision about a chart rather than about ratings.
 */
(function (global) {

  /** How many ratings there must be before a trend is worth drawing. */
  const MIN_RESPONSES = 3;

  /** The lowest and highest a rating can be. */
  const MIN_RATING = 1;
  const MAX_RATING = 5;

  /**
   * The month a rated job belongs to, as `YYYY-MM`.
   *
   * `completedAt` is an ISO timestamp and is converted through the reader's own
   * clock, because that is the month the shop thinks the job finished in. A
   * plain `YYYY-MM-DD` date is sliced instead of parsed: parsing it would put
   * it at midnight UTC and move it a day for half the world.
   */
  function monthOf(order) {
    const stamp = order && order.completedAt;
    if (stamp && String(stamp).length > 10) {
      const d = new Date(stamp);
      if (!isNaN(d)) {
        return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
      }
    }
    const fallback = String((stamp || (order && order.date) || ''));
    return /^\d{4}-\d{2}/.test(fallback) ? fallback.slice(0, 7) : '';
  }

  /** The rating on a job, or null when it carries none. */
  function ratingOf(order) {
    const raw = order && order.survey && order.survey.rating;
    const n = +raw;
    if (!raw || !Number.isFinite(n)) return null;
    if (n < MIN_RATING || n > MAX_RATING) return null;
    return n;
  }

  /**
   * The ratings a shop has, bucketed into the months asked for.
   *
   * `months` is an ordered list of `YYYY-MM` keys. Returns:
   *
   *   - `points` — one entry per month asked for, `average` null where that
   *     month had no responses, so the caller can leave a gap.
   *   - `responses` and `average` — **over the months asked for**, which is
   *     what the caption under the chart is describing.
   *   - `allTimeResponses` — every rating in the book, for a caller that wants
   *     to say so explicitly rather than by accident.
   *   - `enough` — whether there are enough responses in the window to be
   *     worth drawing at all.
   */
  function trend(orders, months, opts) {
    const options = opts || {};
    const min = options.minResponses == null ? MIN_RESPONSES : +options.minResponses;
    const keys = Array.isArray(months) ? months : [];

    const bucket = new Map();
    keys.forEach(k => bucket.set(k, { total: 0, count: 0 }));

    let allTimeResponses = 0;
    (orders || []).forEach(o => {
      const rating = ratingOf(o);
      if (rating == null) return;
      allTimeResponses += 1;
      const b = bucket.get(monthOf(o));
      if (!b) return;
      b.total += rating;
      b.count += 1;
    });

    let responses = 0;
    let total = 0;
    const points = keys.map(key => {
      const b = bucket.get(key);
      responses += b.count;
      total += b.total;
      return { month: key, responses: b.count, average: b.count > 0 ? b.total / b.count : null };
    });

    return {
      points,
      responses,
      average: responses > 0 ? total / responses : null,
      allTimeResponses,
      enough: responses >= min,
    };
  }

  const api = { MIN_RESPONSES, MIN_RATING, MAX_RATING, monthOf, ratingOf, trend };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytRatingTrend = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
