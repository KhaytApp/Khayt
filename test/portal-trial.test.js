'use strict';

// The customer portal's free-tier trial (docs/KHAYT-CLOUD-FEATURES-AND-PRICING.md §4).
//
// The tests that matter most here are the ones asserting the trial does NOT
// bite: it is easy to write a correct countdown that quietly takes a working
// feature away from every shop the day it ships, and that is the failure this
// module is arranged to prevent.

const { test } = require('node:test');
const assert = require('node:assert/strict');

const T = require('../lib/portal-trial.js');
const Plans = require('../lib/cloud-plans.js');

const iso = (ms) => new Date(ms).toISOString();
const DAY = 24 * 60 * 60 * 1000;
const T0 = Date.parse('2026-08-13T00:00:00.000Z');

test('the trial is 30 days', () => {
  assert.equal(T.TRIAL_DAYS, 30);
});

// ── rule 1: the clock does not run during beta ──────────────────────────────

test('during beta the portal is simply available, whatever else is true', () => {
  for (const startedAt of [null, iso(T0 - 400 * DAY)]) {
    const s = T.portalTrialState({ betaFree: true, startedAt, now: T0 });
    assert.equal(s.state, 'beta');
    assert.equal(s.available, true,
      'counting down during beta would take away a feature shops already have');
  }
});

test('beta use does not burn the trial — a year of beta still leaves 30 days', () => {
  // The shop published portals throughout beta. Billing goes live. It must not
  // discover its trial expired on day one, which is exactly the "found out
  // about a price after committing" the pricing was arranged to avoid.
  const duringBeta = T.trialStartOnPublish({ betaFree: true, startedAt: null, now: T0 - 365 * DAY });
  assert.equal(duringBeta, null, 'publishing during beta must not start the clock');

  const atLaunch = T.portalTrialState({ betaFree: false, startedAt: null, now: T0 });
  assert.equal(atLaunch.state, 'not_started');
  assert.equal(atLaunch.daysLeft, 30);
  assert.equal(atLaunch.available, true);
});

test('the live flag is the one that matters — it tracks cloud-plans', () => {
  // If BETA_FREE is ever flipped without this module being revisited, the
  // countdown starts for real. That is intended, but it should be a decision.
  assert.equal(Plans.isBetaFree(), true);
  assert.equal(T.portalTrialState({ betaFree: Plans.isBetaFree(), now: T0 }).state, 'beta');
});

// ── the clock, once it is running ───────────────────────────────────────────

test('a live free shop counts down whole days', () => {
  const startedAt = iso(T0);
  for (const [days, left] of [[0, 30], [1, 29], [29, 1], [30, 0], [31, 0], [400, 0]]) {
    const s = T.portalTrialState({ betaFree: false, startedAt, now: T0 + days * DAY });
    assert.equal(s.daysLeft, left, `day ${days} should leave ${left}`);
    assert.equal(s.daysUsed, days);
  }
});

test('part of a day is not a day — 23h59m in, the first day is not spent', () => {
  const startedAt = iso(T0);
  const s = T.portalTrialState({ betaFree: false, startedAt, now: T0 + DAY - 60_000 });
  assert.equal(s.daysUsed, 0);
  assert.equal(s.daysLeft, 30);
});

test('the portal stays available on the last day and closes when it hits zero', () => {
  const startedAt = iso(T0);
  const onDay29 = T.portalTrialState({ betaFree: false, startedAt, now: T0 + 29 * DAY });
  assert.equal(onDay29.state, 'active');
  assert.equal(onDay29.available, true);

  const onDay30 = T.portalTrialState({ betaFree: false, startedAt, now: T0 + 30 * DAY });
  assert.equal(onDay30.state, 'expired');
  assert.equal(onDay30.available, false);
});

test('a backdated clock cannot extend the window past its full length', () => {
  // Not DRM — the store is E2E encrypted, so no server can check a date it
  // cannot read. This only ensures the arithmetic cannot hand out MORE than the
  // trial by going negative.
  const startedAt = iso(T0);
  const s = T.portalTrialState({ betaFree: false, startedAt, now: T0 - 500 * DAY });
  assert.equal(s.daysUsed, 0);
  assert.equal(s.daysLeft, 30, 'never more than the full window');
  assert.equal(s.available, true);
});

test('a malformed or missing start is treated as not started, never as expired', () => {
  for (const startedAt of ['', 'not a date', null, undefined, 'NaN']) {
    const s = T.portalTrialState({ betaFree: false, startedAt, now: T0 });
    assert.equal(s.state, 'not_started', `${JSON.stringify(startedAt)} must not read as expired`);
    assert.equal(s.available, true, 'bad data must never lock a shop out of its own portal');
  }
});

// ── subscribers ─────────────────────────────────────────────────────────────

test('a subscriber has no trial, even with an old start date on file', () => {
  const s = T.portalTrialState({ betaFree: false, subscribed: true, startedAt: iso(T0 - 900 * DAY), now: T0 });
  assert.equal(s.state, 'subscribed');
  assert.equal(s.available, true);
});

test('a shop that subscribes after expiry gets its portal back', () => {
  const startedAt = iso(T0 - 90 * DAY);
  const before = T.portalTrialState({ betaFree: false, startedAt, now: T0 });
  assert.equal(before.available, false);
  const after = T.portalTrialState({ betaFree: false, subscribed: true, startedAt, now: T0 });
  assert.equal(after.available, true, 'paying must restore the feature immediately');
});

// ── starting the clock ──────────────────────────────────────────────────────

test('the clock starts on the first publish by a live, unsubscribed shop', () => {
  const at = T.trialStartOnPublish({ betaFree: false, startedAt: null, now: T0 });
  assert.equal(at, iso(T0));
});

test('starting is idempotent — a later publish never restarts or extends it', () => {
  const startedAt = iso(T0);
  assert.equal(T.trialStartOnPublish({ betaFree: false, startedAt, now: T0 + 5 * DAY }), null);
  assert.equal(T.trialStartOnPublish({ betaFree: false, startedAt, now: T0 + 90 * DAY }), null,
    'an expired trial must not silently restart on the next publish');
});

test('a subscriber publishing does not start a trial clock', () => {
  assert.equal(T.trialStartOnPublish({ betaFree: false, subscribed: true, startedAt: null, now: T0 }), null);
});

// ── what to show ────────────────────────────────────────────────────────────

test('only a running or finished trial is worth showing', () => {
  assert.equal(T.isTrialVisible('active'), true);
  assert.equal(T.isTrialVisible('expired'), true);
  assert.equal(T.isTrialVisible('beta'), false, 'the plans block already says free during beta');
  assert.equal(T.isTrialVisible('subscribed'), false);
  assert.equal(T.isTrialVisible('not_started'), false, 'nothing has happened yet');
});
