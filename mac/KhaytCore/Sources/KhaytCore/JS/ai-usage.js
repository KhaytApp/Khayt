'use strict';
(function () {

/**
 * AI spend tracking — what the owner's own API key has actually cost, per
 * feature, per month.
 *
 * WHY: the AI features are bring-your-own-key. Every response already carries a
 * `usage` block (input/output/cache token counts) and the app threw it away, so
 * a shop had no way to tell whether the assistant cost them two riyals this
 * month or two hundred. That is a decision they should get to make, and they
 * cannot make it without the number. Anthropic's own console shows a total; it
 * cannot show which Khayt feature spent it.
 *
 * Pure (no DOM, no network, no clock of its own — `now` is injected) so the
 * arithmetic is unit-testable.
 */

/**
 * USD per million tokens, by model. Cache reads bill at ~0.1x input and cache
 * writes at ~1.25x, which is why they are tracked separately rather than folded
 * into the input count.
 *
 * These are a local estimate for the owner's benefit, NOT a bill. Anthropic's
 * console is authoritative; prices change and this table will drift.
 */
const PRICING = {
  'claude-opus-5':     { input: 5.00, output: 25.00 },
  'claude-opus-4-8':   { input: 5.00, output: 25.00 },
  'claude-opus-4-7':   { input: 5.00, output: 25.00 },
  'claude-opus-4-6':   { input: 5.00, output: 25.00 },
  'claude-sonnet-5':   { input: 3.00, output: 15.00 },
  'claude-sonnet-4-6': { input: 3.00, output: 15.00 },
  'claude-haiku-4-5':  { input: 1.00, output: 5.00 },
};

/** Fallback when the owner has typed a model we have no price for. */
const DEFAULT_PRICING = PRICING['claude-opus-5'];

const CACHE_READ_MULTIPLIER = 0.1;
const CACHE_WRITE_MULTIPLIER = 1.25;

function priceFor(model) {
  return PRICING[String(model || '').trim()] || DEFAULT_PRICING;
}

/** True when we are guessing the price because the model is unknown to us. */
function isEstimatedModel(model) {
  return !PRICING[String(model || '').trim()];
}

/**
 * Cost in USD for one response's usage block.
 * Tolerant of missing fields — a provider that stops sending cache counts must
 * not turn the running total into NaN.
 */
function costOf(usage, model) {
  const u = usage || {};
  const p = priceFor(model);
  const n = (v) => (Number.isFinite(+v) ? +v : 0);
  const input = n(u.input_tokens);
  const output = n(u.output_tokens);
  const cacheRead = n(u.cache_read_input_tokens);
  const cacheWrite = n(u.cache_creation_input_tokens);
  return (
    (input * p.input)
    + (output * p.output)
    + (cacheRead * p.input * CACHE_READ_MULTIPLIER)
    + (cacheWrite * p.input * CACHE_WRITE_MULTIPLIER)
  ) / 1_000_000;
}

/** Local calendar month key. Deliberately not UTC — see test/local-dates.test.js. */
function monthKey(now) {
  const d = new Date(now);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
}

/**
 * Fold one call into the running ledger, in place, and return it.
 * Shape: { '2026-07': { quote: {calls, input, output, cost}, … }, … }
 *
 * Only the last 12 months are kept. This lives in `settings`, which is written
 * on every save and included in backups but is NOT synced between devices
 * (lib/sync.js walks array collections only) — so the figure is per-device
 * and the panel says so. An unbounded per-call log would grow without limit for
 * a number nobody reads at that granularity.
 */
function record(ledger, { task, model, usage, now }) {
  const led = (ledger && typeof ledger === 'object') ? ledger : {};
  const mk = monthKey(now);
  const month = led[mk] || (led[mk] = {});
  const key = String(task || 'quote');
  const row = month[key] || (month[key] = { calls: 0, input: 0, output: 0, cost: 0 });
  const u = usage || {};
  const n = (v) => (Number.isFinite(+v) ? +v : 0);
  row.calls += 1;
  row.input += n(u.input_tokens) + n(u.cache_read_input_tokens) + n(u.cache_creation_input_tokens);
  row.output += n(u.output_tokens);
  row.cost = Math.round((row.cost + costOf(u, model)) * 1e6) / 1e6;
  return prune(led, now);
}

/** Keep the ledger bounded to the last 12 local months. */
function prune(ledger, now, keep = 12) {
  const keys = Object.keys(ledger).sort();          // 'YYYY-MM' sorts chronologically
  while (keys.length > keep) delete ledger[keys.shift()];
  return ledger;
}

/**
 * Per-feature totals for one month, newest-first by cost so the expensive
 * feature is the first thing the owner sees.
 * @returns {{month: string, rows: Array, total: {calls, cost}}}
 */
function summarize(ledger, now) {
  const mk = monthKey(now);
  const month = (ledger && ledger[mk]) || {};
  const rows = Object.entries(month)
    .map(([task, r]) => ({
      task,
      calls: r.calls || 0,
      input: r.input || 0,
      output: r.output || 0,
      cost: Math.round((r.cost || 0) * 100) / 100,
      costExact: r.cost || 0,
    }))
    .sort((a, b) => b.costExact - a.costExact);
  const total = rows.reduce(
    (acc, r) => ({ calls: acc.calls + r.calls, cost: acc.cost + r.costExact }),
    { calls: 0, cost: 0 },
  );
  total.cost = Math.round(total.cost * 100) / 100;
  return { month: mk, rows, total };
}

/** Format a USD amount for display; sub-cent spend reads as "<$0.01", not "$0.00". */
function fmtUsd(n) {
  const v = +n || 0;
  if (v > 0 && v < 0.01) return '<$0.01';
  return `$${v.toFixed(2)}`;
}

const api = {
  PRICING, DEFAULT_PRICING, CACHE_READ_MULTIPLIER, CACHE_WRITE_MULTIPLIER,
  priceFor, isEstimatedModel, costOf, monthKey, record, prune, summarize, fmtUsd,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiUsage = api;

})();
