'use strict';
(function () {

/**
 * The customer portal's free-tier trial.
 *
 * docs/KHAYT-CLOUD-FEATURES-AND-PRICING.md §4 gives the portal to free shops for
 * a fixed window rather than forever or not at all: it is what a shop's own
 * customers see, so a shop should watch it work with real customers before
 * deciding to pay for it.
 *
 * ── Two rules that shape everything below ───────────────────────────────────
 *
 * 1. **The clock does not run during beta.** While KhaytCloudPlans.BETA_FREE is
 *    on, every plan is free and the portal is simply available. Counting down
 *    now would take away something shops already have, which §4 forbids in the
 *    same breath as it sets the prices.
 *
 * 2. **Beta use does not burn the trial.** A shop that published portals for a
 *    year of beta must not find its trial already expired on the day billing
 *    starts — that is precisely the "discovered a price after committing" this
 *    pricing was arranged to avoid. So the clock starts at the shop's first
 *    publish *as a live free-plan shop*, never earlier.
 *
 * The consequence is that `trialStartedAt` is not set during beta at all, and
 * `state` reports 'beta' rather than a countdown. Everything is in place; none
 * of it bites yet.
 *
 * This is a trust-based trial, not DRM. The store is end-to-end encrypted, so
 * the server cannot verify a date it cannot read, and a local clock can be moved
 * by anyone who wants to. It is built to be correct and fair for people acting
 * in good faith, and deliberately not built to be tamper-proof — the one guard
 * is that a backdated clock cannot *extend* the window past its full length.
 *
 * Pure (no DOM/globals) so it can be unit-tested and reused.
 */

/** How long the free tier keeps the portal once the clock is running. */
const TRIAL_DAYS = 30;

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Parse a timestamp to ms, or null if it is missing/unusable.
 *
 * Epoch NUMBERS have to be handled explicitly: `Date.parse(String(1755043200000))`
 * is NaN, so a numeric `now` would silently fall through to the real clock and
 * every answer would be about today instead of the instant asked about.
 */
function parseTime(v) {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const ms = (v instanceof Date) ? v.getTime() : Date.parse(String(v));
  return Number.isFinite(ms) ? ms : null;
}

/**
 * Whole days elapsed between two instants, never negative.
 *
 * Clamping at zero is the clock guard: if `now` is before the start the shop has
 * moved its clock back, and the honest reading of that is "no time has passed",
 * not "negative time has passed" — which would otherwise hand out more than
 * TRIAL_DAYS.
 */
function daysBetween(startMs, nowMs) {
  return Math.max(0, Math.floor((nowMs - startMs) / DAY_MS));
}

/**
 * Work out where a shop stands.
 *
 * @param {object} o
 * @param {boolean} o.betaFree     KhaytCloudPlans.isBetaFree()
 * @param {boolean} o.subscribed   on a paid plan, in good standing
 * @param {string}  o.startedAt    ISO time the trial clock started, if it has
 * @param {Date|number|string} o.now
 * @param {number}  o.trialDays    override for tests
 *
 * @returns {{state, available, daysLeft, daysUsed, trialDays, startedAt}}
 *   state — 'beta' | 'subscribed' | 'not_started' | 'active' | 'expired'
 *   available — may this shop publish a portal right now?
 */
function portalTrialState(o) {
  o = o || {};
  const trialDays = Number.isFinite(o.trialDays) ? o.trialDays : TRIAL_DAYS;
  const base = { trialDays, startedAt: o.startedAt || null, daysUsed: 0, daysLeft: trialDays };

  // Rule 1. Nothing else can be true while this is.
  if (o.betaFree) return { ...base, state: 'beta', available: true, startedAt: o.startedAt || null };

  // A paying shop has no trial to be in.
  if (o.subscribed) return { ...base, state: 'subscribed', available: true };

  const startMs = parseTime(o.startedAt);
  // Rule 2 in practice: the clock has not started, so the full window remains.
  if (startMs === null) return { ...base, state: 'not_started', available: true };

  const nowMs = parseTime(o.now) ?? Date.now();
  const daysUsed = daysBetween(startMs, nowMs);
  const daysLeft = Math.max(0, trialDays - daysUsed);
  return {
    ...base,
    state: daysLeft > 0 ? 'active' : 'expired',
    available: daysLeft > 0,
    daysUsed,
    daysLeft,
  };
}

/**
 * Should publishing start the clock, and with what timestamp?
 *
 * Returns an ISO string to store, or null to leave the shop's state alone. It
 * only ever fires for a live, unsubscribed shop that has not started — so it is
 * a no-op during beta (rule 1) and a no-op for a subscriber.
 *
 * Kept separate from portalTrialState so the decision to WRITE is explicit at
 * the call site rather than a side effect of asking a question.
 */
function trialStartOnPublish(o) {
  const s = portalTrialState(o);
  if (s.state !== 'not_started') return null;
  const nowMs = parseTime((o || {}).now) ?? Date.now();
  return new Date(nowMs).toISOString();
}

/** Is this a state worth putting on screen? Beta and subscribed are not. */
function isTrialVisible(state) {
  return state === 'active' || state === 'expired';
}

const api = { TRIAL_DAYS, portalTrialState, trialStartOnPublish, isTrialVisible };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPortalTrial = api;

})();
