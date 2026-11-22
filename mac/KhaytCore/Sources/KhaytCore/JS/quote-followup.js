'use strict';
(function () {

/**
 * Quote follow-up automation — pure selector logic.
 *
 * Unapproved quotes silently expire = lost revenue. This module decides which
 * quotes are "due" for a gentle follow-up nudge, given the orders list, the
 * relevant settings, and the current time. It is intentionally side-effect free
 * so it can be unit-tested in isolation and reused by both the dashboard and the
 * optional auto-nudge timer.
 *
 * A quote is due for follow-up when ALL of the following hold:
 *   (a) status === 'quote'
 *   (b) not accepted (no quoteAcceptedAt) and not voided
 *   (c) it has a quoteExpiresAt date that falls within `windowDays` from `now`
 *       (i.e. it expires within the window, OR has already expired but not by
 *       more than `graceDays` — so a freshly-expired quote can still be nudged)
 *   (d) it has not already been followed up "recently" — dedupe by
 *       `followUpSentAt` (cooldown) and capped by `followUpMaxCount`.
 *
 * Date fields (quoteExpiresAt) are stored as 'YYYY-MM-DD' day strings in Khayt;
 * we compare them at local midnight. `followUpSentAt` is a full ISO timestamp.
 */

const DAY_MS = 86400000;

/** Default windowing/dedupe settings. */
const DEFAULTS = {
  windowDays: 2,        // start nudging this many days before expiry
  graceDays: 1,         // keep nudging up to this many days AFTER expiry
  cooldownDays: 2,      // min days between two follow-ups for the same quote
  maxCount: 2,          // never send more than this many follow-ups per quote
};

/**
 * Read follow-up tuning from a settings object, falling back to DEFAULTS.
 * @param {object} [settings]
 */
function followUpConfig(settings) {
  const f = (settings && settings.quoteFollowUp) || {};
  const pick = (v, d) => (Number.isFinite(+v) && +v >= 0 ? +v : d);
  return {
    enabled: !!f.enabled,
    windowDays: pick(f.windowDays, DEFAULTS.windowDays),
    graceDays: pick(f.graceDays, DEFAULTS.graceDays),
    cooldownDays: pick(f.cooldownDays, DEFAULTS.cooldownDays),
    maxCount: pick(f.maxCount, DEFAULTS.maxCount),
  };
}

/** Local-midnight Date for a 'YYYY-MM-DD' day string, or null. */
function dayStartFromYmd(ymd) {
  if (!ymd || typeof ymd !== 'string') return null;
  const d = new Date(ymd + 'T00:00:00');
  return Number.isNaN(d.getTime()) ? null : d;
}

/** Local-midnight Date for an arbitrary Date/timestamp. */
function startOfDay(now) {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d;
}

/**
 * Whole-day signed difference: days from `now` until the quote expires.
 * Positive = expires in the future, 0 = expires today, negative = already expired.
 * @param {object} quote
 * @param {Date|number} now
 * @returns {number|null} null when the quote has no usable expiry date
 */
function daysUntilExpiry(quote, now) {
  const exp = dayStartFromYmd(quote && quote.quoteExpiresAt);
  if (!exp) return null;
  return Math.round((exp - startOfDay(now)) / DAY_MS);
}

/**
 * Is this quote eligible for follow-up at all (status / accepted / voided)?
 * @param {object} q
 */
function isFollowUpEligible(q) {
  if (!q || q.status !== 'quote') return false;
  if (q.quoteAcceptedAt) return false;   // already approved
  if (q.voidedAt) return false;          // cancelled
  return true;
}

/**
 * Has the cooldown since the last follow-up elapsed?
 * @param {object} q
 * @param {Date|number} now
 * @param {number} cooldownDays
 */
function cooldownElapsed(q, now, cooldownDays) {
  if (!q.followUpSentAt) return true;    // never followed up
  const last = new Date(q.followUpSentAt);
  if (Number.isNaN(last.getTime())) return true;
  return (new Date(now) - last) >= cooldownDays * DAY_MS;
}

/**
 * Decide whether a single quote is due for a follow-up nudge right now.
 * @param {object} quote
 * @param {object} cfg  resolved config (see followUpConfig)
 * @param {Date|number} now
 * @returns {boolean}
 */
function isDueForFollowUp(quote, cfg, now) {
  if (!isFollowUpEligible(quote)) return false;
  const days = daysUntilExpiry(quote, now);
  if (days === null) return false;
  // Within the pre-expiry window OR within the post-expiry grace period.
  if (days > cfg.windowDays) return false;       // too early
  if (days < -cfg.graceDays) return false;       // too long expired — give up
  if ((+quote.followUpCount || 0) >= cfg.maxCount) return false; // capped
  if (!cooldownElapsed(quote, now, cfg.cooldownDays)) return false;
  return true;
}

/**
 * Select all quotes from an orders list that are due for a follow-up nudge.
 * Sorted by soonest expiry first. Pure — does not mutate input.
 * @param {object[]} orders  the full printLog / orders array
 * @param {object} settings  app settings (reads settings.quoteFollowUp.*)
 * @param {Date|number} [now]
 * @returns {object[]}
 */
function selectQuotesDueForFollowUp(orders, settings, now = Date.now()) {
  const cfg = followUpConfig(settings);
  const list = Array.isArray(orders) ? orders : [];
  return list
    .filter((q) => isDueForFollowUp(q, cfg, now))
    .sort((a, b) =>
      String(a.quoteExpiresAt || '').localeCompare(String(b.quoteExpiresAt || '')));
}

/**
 * Build the immutable patch to apply to a quote after a follow-up is sent.
 * The caller is responsible for assigning these onto the order and persisting.
 * @param {object} quote
 * @param {Date|number} [now]
 * @returns {{ followUpSentAt: string, followUpCount: number }}
 */
function markFollowUpPatch(quote, now = Date.now()) {
  return {
    followUpSentAt: new Date(now).toISOString(),
    followUpCount: (+(quote && quote.followUpCount) || 0) + 1,
  };
}

const api = {
  DEFAULTS,
  followUpConfig,
  daysUntilExpiry,
  isFollowUpEligible,
  cooldownElapsed,
  isDueForFollowUp,
  selectQuotesDueForFollowUp,
  markFollowUpPatch,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') {
  globalThis.KhaytQuoteFollowUp = api;
}

})();
