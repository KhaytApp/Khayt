const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  DEFAULTS,
  followUpConfig,
  daysUntilExpiry,
  isFollowUpEligible,
  cooldownElapsed,
  isDueForFollowUp,
  selectQuotesDueForFollowUp,
  markFollowUpPatch,
} = require('../lib/quote-followup');

// Fixed "now": 2026-06-16T12:00:00 local time.
const NOW = new Date(2026, 5, 16, 12, 0, 0);
// A day string relative to NOW (offset in whole days).
const ymd = (offsetDays) => {
  const d = new Date(2026, 5, 16 + offsetDays);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};
const quote = (over = {}) => ({ id: 'Q1', status: 'quote', quoteExpiresAt: ymd(1), ...over });

test('followUpConfig falls back to DEFAULTS and respects overrides', () => {
  assert.deepEqual(followUpConfig(undefined), { enabled: false, ...DEFAULTS });
  const cfg = followUpConfig({ quoteFollowUp: { enabled: true, windowDays: 5, cooldownDays: 0 } });
  assert.equal(cfg.enabled, true);
  assert.equal(cfg.windowDays, 5);
  assert.equal(cfg.cooldownDays, 0);
  assert.equal(cfg.graceDays, DEFAULTS.graceDays); // untouched
});

test('followUpConfig ignores invalid (negative / NaN) values', () => {
  const cfg = followUpConfig({ quoteFollowUp: { windowDays: -3, maxCount: 'abc' } });
  assert.equal(cfg.windowDays, DEFAULTS.windowDays);
  assert.equal(cfg.maxCount, DEFAULTS.maxCount);
});

test('daysUntilExpiry computes signed whole-day diff at local midnight', () => {
  assert.equal(daysUntilExpiry(quote({ quoteExpiresAt: ymd(0) }), NOW), 0);
  assert.equal(daysUntilExpiry(quote({ quoteExpiresAt: ymd(2) }), NOW), 2);
  assert.equal(daysUntilExpiry(quote({ quoteExpiresAt: ymd(-1) }), NOW), -1);
  assert.equal(daysUntilExpiry(quote({ quoteExpiresAt: null }), NOW), null);
  assert.equal(daysUntilExpiry(quote({ quoteExpiresAt: 'not-a-date' }), NOW), null);
});

test('isFollowUpEligible only accepts open, unaccepted, non-void quotes', () => {
  assert.equal(isFollowUpEligible(quote()), true);
  assert.equal(isFollowUpEligible(quote({ status: 'pending' })), false);
  assert.equal(isFollowUpEligible(quote({ quoteAcceptedAt: '2026-06-15T00:00:00Z' })), false);
  assert.equal(isFollowUpEligible(quote({ voidedAt: '2026-06-15T00:00:00Z' })), false);
  assert.equal(isFollowUpEligible(null), false);
});

test('cooldownElapsed: never-sent or stale send returns true, recent returns false', () => {
  assert.equal(cooldownElapsed(quote(), NOW, 2), true); // never sent
  const recent = new Date(2026, 5, 15, 12, 0, 0).toISOString(); // 1 day ago
  assert.equal(cooldownElapsed(quote({ followUpSentAt: recent }), NOW, 2), false);
  const old = new Date(2026, 5, 13, 12, 0, 0).toISOString(); // 3 days ago
  assert.equal(cooldownElapsed(quote({ followUpSentAt: old }), NOW, 2), true);
  // Malformed timestamp -> treat as never sent.
  assert.equal(cooldownElapsed(quote({ followUpSentAt: 'garbage' }), NOW, 2), true);
});

const cfg = followUpConfig({}); // defaults: window 2, grace 1, cooldown 2, max 2

test('windowing: due inside the pre-expiry window, not before', () => {
  assert.equal(isDueForFollowUp(quote({ quoteExpiresAt: ymd(2) }), cfg, NOW), true);  // edge
  assert.equal(isDueForFollowUp(quote({ quoteExpiresAt: ymd(1) }), cfg, NOW), true);
  assert.equal(isDueForFollowUp(quote({ quoteExpiresAt: ymd(0) }), cfg, NOW), true);  // today
  assert.equal(isDueForFollowUp(quote({ quoteExpiresAt: ymd(3) }), cfg, NOW), false); // too early
});

test('windowing: due during post-expiry grace, gives up afterwards', () => {
  assert.equal(isDueForFollowUp(quote({ quoteExpiresAt: ymd(-1) }), cfg, NOW), true);  // grace edge
  assert.equal(isDueForFollowUp(quote({ quoteExpiresAt: ymd(-2) }), cfg, NOW), false); // too late
});

test('dedupe: respects cooldown and max count', () => {
  // Followed up yesterday -> cooldown blocks.
  const recent = new Date(2026, 5, 15, 12, 0, 0).toISOString();
  assert.equal(isDueForFollowUp(quote({ followUpSentAt: recent, followUpCount: 1 }), cfg, NOW), false);
  // Followed up 3 days ago, count 1 -> due again.
  const old = new Date(2026, 5, 13, 12, 0, 0).toISOString();
  assert.equal(isDueForFollowUp(quote({ followUpSentAt: old, followUpCount: 1 }), cfg, NOW), true);
  // Hit the cap -> never due even if cooldown elapsed.
  assert.equal(isDueForFollowUp(quote({ followUpSentAt: old, followUpCount: 2 }), cfg, NOW), false);
});

test('dedupe: configurable cooldown of 0 allows immediate re-send', () => {
  const cfg0 = followUpConfig({ quoteFollowUp: { cooldownDays: 0, maxCount: 5 } });
  const recent = new Date(2026, 5, 16, 11, 0, 0).toISOString(); // 1h ago
  assert.equal(isDueForFollowUp(quote({ followUpSentAt: recent, followUpCount: 1 }), cfg0, NOW), true);
});

test('selectQuotesDueForFollowUp filters and sorts by soonest expiry', () => {
  const orders = [
    quote({ id: 'far', quoteExpiresAt: ymd(10) }),        // too early
    quote({ id: 'soon', quoteExpiresAt: ymd(2) }),        // due
    quote({ id: 'today', quoteExpiresAt: ymd(0) }),       // due
    quote({ id: 'expired', quoteExpiresAt: ymd(-1) }),    // due (grace)
    quote({ id: 'gone', quoteExpiresAt: ymd(-5) }),       // too late
    quote({ id: 'accepted', quoteExpiresAt: ymd(1), quoteAcceptedAt: 'x' }), // accepted
    quote({ id: 'capped', quoteExpiresAt: ymd(1), followUpCount: 2 }),       // capped
    { id: 'job', status: 'pending', quoteExpiresAt: ymd(1) },                // not a quote
  ];
  const due = selectQuotesDueForFollowUp(orders, {}, NOW);
  assert.deepEqual(due.map((q) => q.id), ['expired', 'today', 'soon']);
});

test('selectQuotesDueForFollowUp tolerates non-array input and does not mutate', () => {
  assert.deepEqual(selectQuotesDueForFollowUp(null, {}, NOW), []);
  const orders = [quote({ id: 'a' })];
  const snapshot = JSON.stringify(orders);
  selectQuotesDueForFollowUp(orders, {}, NOW);
  assert.equal(JSON.stringify(orders), snapshot);
});

test('markFollowUpPatch increments count and stamps ISO time', () => {
  const p1 = markFollowUpPatch(quote(), NOW);
  assert.equal(p1.followUpCount, 1);
  assert.equal(p1.followUpSentAt, NOW.toISOString());
  const p2 = markFollowUpPatch(quote({ followUpCount: 1 }), NOW);
  assert.equal(p2.followUpCount, 2);
});
