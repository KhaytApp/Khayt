const { test } = require('node:test');
const assert = require('node:assert/strict');

const U = require('../lib/ai-usage.js');
const P = require('../lib/ai-privacy.js');

/**
 * The AI features run on the owner's own Anthropic key, so the bill is theirs.
 * Every response already carried a `usage` block and the app discarded it,
 * which left a shop unable to tell whether the assistant cost them two riyals
 * this month or two hundred. Anthropic's console shows one total; only Khayt
 * can attribute it per feature.
 *
 * These pin the arithmetic. The numbers are an ESTIMATE for the owner's
 * benefit, never a bill — which is why the UI says so and why unknown models
 * fall back loudly rather than silently.
 */

const JULY = new Date(2026, 6, 15, 12).getTime();
const AUG = new Date(2026, 7, 15, 12).getTime();

test('cost is computed from the four token classes at their own rates', () => {
  // 1M input + 1M output on Opus = $5 + $25.
  const c = U.costOf({ input_tokens: 1e6, output_tokens: 1e6 }, 'claude-opus-4-8');
  assert.equal(Math.round(c * 100) / 100, 30);
  // Cache reads bill at ~0.1x input, writes at ~1.25x — folding them into the
  // input count would overstate a cached workload by an order of magnitude.
  const cached = U.costOf({ cache_read_input_tokens: 1e6 }, 'claude-opus-4-8');
  assert.equal(Math.round(cached * 100) / 100, 0.5);
  const written = U.costOf({ cache_creation_input_tokens: 1e6 }, 'claude-opus-4-8');
  assert.equal(Math.round(written * 100) / 100, 6.25);
});

test('a missing or malformed usage block yields 0, never NaN', () => {
  // A NaN here would poison the running total permanently and silently.
  for (const bad of [null, undefined, {}, { input_tokens: 'x' }, { output_tokens: null }]) {
    const c = U.costOf(bad, 'claude-opus-4-8');
    assert.ok(Number.isFinite(c), `${JSON.stringify(bad)} produced ${c}`);
    assert.equal(c, 0);
  }
});

test('an unknown model falls back to Opus rates and says so', () => {
  assert.equal(U.isEstimatedModel('claude-opus-4-8'), false);
  assert.equal(U.isEstimatedModel('some-future-model'), true);
  assert.equal(U.isEstimatedModel(''), true);
  // Falling back silently would quietly under- or over-report; the UI shows a note.
  assert.deepEqual(U.priceFor('some-future-model'), U.DEFAULT_PRICING);
});

test('cheaper models cost less for identical usage', () => {
  const usage = { input_tokens: 1e6, output_tokens: 1e6 };
  const opus = U.costOf(usage, 'claude-opus-4-8');
  const sonnet = U.costOf(usage, 'claude-sonnet-5');
  const haiku = U.costOf(usage, 'claude-haiku-4-5');
  assert.ok(opus > sonnet && sonnet > haiku, `${opus} > ${sonnet} > ${haiku}`);
});

test('record accumulates per feature within a month', () => {
  let led = {};
  led = U.record(led, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 1000, output_tokens: 500 }, now: JULY });
  led = U.record(led, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 1000, output_tokens: 500 }, now: JULY });
  led = U.record(led, { task: 'reply', model: 'claude-opus-4-8', usage: { input_tokens: 200, output_tokens: 100 }, now: JULY });
  const m = led['2026-07'];
  assert.equal(m.quote.calls, 2);
  assert.equal(m.quote.input, 2000);
  assert.equal(m.quote.output, 1000);
  assert.equal(m.reply.calls, 1);
});

test('months are kept separate and keyed on the LOCAL calendar', () => {
  let led = {};
  led = U.record(led, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 10 }, now: JULY });
  led = U.record(led, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 10 }, now: AUG });
  assert.deepEqual(Object.keys(led).sort(), ['2026-07', '2026-08']);
  // Local, not UTC — the same defect as test/local-dates.test.js guards against.
  assert.equal(U.monthKey(new Date(2026, 6, 1, 1, 30).getTime()), '2026-07');
});

test('the ledger stays bounded to 12 months', () => {
  // It lives in the store, which is written on every save and included in
  // backups; unbounded growth for a number nobody reads at per-call
  // granularity is not worth the bytes. (It does NOT sync — see below.)
  let led = {};
  for (let i = 0; i < 20; i++) {
    led = U.record(led, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 1 }, now: new Date(2025, i, 15).getTime() });
  }
  assert.equal(Object.keys(led).length, 12);
  // The OLDEST are dropped, not the newest.
  const keys = Object.keys(led).sort();
  assert.equal(keys[keys.length - 1], '2026-08');
});

test('summarize ranks the expensive feature first', () => {
  let led = {};
  led = U.record(led, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 100, output_tokens: 50 }, now: JULY });
  led = U.record(led, { task: 'assistant', model: 'claude-opus-4-8', usage: { input_tokens: 100000, output_tokens: 50000 }, now: JULY });
  const s = U.summarize(led, JULY);
  assert.equal(s.month, '2026-07');
  assert.equal(s.rows[0].task, 'assistant', 'the expensive feature must be first');
  assert.equal(s.total.calls, 2);
  assert.ok(s.total.cost > 0);
});

test('summarize is empty-safe and month-scoped', () => {
  assert.deepEqual(U.summarize(undefined, JULY).rows, []);
  assert.deepEqual(U.summarize({}, JULY).rows, []);
  let led = U.record({}, { task: 'quote', model: 'claude-opus-4-8', usage: { input_tokens: 10 }, now: JULY });
  assert.deepEqual(U.summarize(led, AUG).rows, [], 'another month must not leak in');
});

test('every recordable task is a real AI feature with a label', () => {
  // The panel labels rows via KhaytAiPrivacy.AI_FEATURES; a task with no entry
  // would render as a raw id.
  for (const id of Object.keys(P.AI_FEATURES)) {
    const led = U.record({}, { task: id, model: 'claude-opus-4-8', usage: { input_tokens: 1 }, now: JULY });
    assert.equal(U.summarize(led, JULY).rows[0].task, id);
    assert.ok(P.AI_FEATURES[id].labelKey, `${id} has no label key for the spend panel`);
  }
});

test('sub-cent spend reads as "<$0.01", not "$0.00"', () => {
  // "$0.00" next to a non-zero call count reads as a bug, or as free.
  assert.equal(U.fmtUsd(0.0004), '<$0.01');
  assert.equal(U.fmtUsd(0), '$0.00');
  assert.equal(U.fmtUsd(1.239), '$1.24');
});

test('the ledger is device-local — sync cannot clobber or merge it', () => {
  // I reasoned from the code that settings synced across devices and would
  // overwrite this ledger. That was WRONG, and the mistake is easy to repeat:
  // lib/sync.js walks arrayCollections() only, so `settings` — an object —
  // is never stamped, never sent, and never replaced by a pull.
  //
  // The consequence is not data loss, it is scope: the panel shows THIS
  // device's spend, which under-reports for a shop running two machines on one
  // key. That is why the panel says so rather than silently totalling.
  const S = require('../lib/sync.js');
  const local = { settings: { aiUsage: { '2026-07': { quote: { calls: 5, cost: 1 } } } }, printLog: [] };
  const remote = { settings: { aiUsage: { '2026-07': { quote: { calls: 99, cost: 99 } } } }, printLog: [] };
  S.applyDeltas(local, S.extractDeltas(remote, { rev: 0, ts: '' }), { appendOnly: [] });
  assert.deepEqual(local.settings.aiUsage['2026-07'].quote, { calls: 5, cost: 1 },
    'a pull must not touch the local ledger');
});

test('the panel discloses that the figure is device-local', () => {
  // If the ledger ever DOES start syncing, this caveat becomes wrong and should
  // be removed — the test names the coupling so it is not missed.
  const fs = require('fs');
  const path = require('path');
  const settings = fs.readFileSync(path.join(__dirname, '../renderer/settings.js'), 'utf8');
  assert.match(settings, /set\.ai_spend_device/, 'the spend panel must state the figure covers this device only');
  const en = fs.readFileSync(path.join(__dirname, '../renderer/locales/en.js'), 'utf8');
  assert.match(en, /"set\.ai_spend_device"/, 'the caveat needs an English string');
});

test('the desktop\'s normalised usage is counted, not recorded as 0 tokens and $0', () => {
  // renderer/ai-call.js records `res.usage`, which main.js takes from
  // lib/ai-providers.js usageOf: {inputTokens, outputTokens}. The ledger read
  // only the provider's own spelling, so every desktop call cost "$0".
  const { usageOf } = require('../lib/ai-providers.js');
  const now = new Date(2026, 9, 12).getTime();
  const replies = {
    anthropic: { usage: { input_tokens: 1000, output_tokens: 200 } },
    openai: { usage: { prompt_tokens: 1000, completion_tokens: 200 } },
    google: { usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 200 } },
  };
  for (const [provider, data] of Object.entries(replies)) {
    const led = U.record({}, { task: 'quote', model: 'claude-sonnet-5-5', usage: usageOf(provider, data), now });
    const row = led['2026-10'].quote;
    assert.equal(row.input, 1000, provider);
    assert.equal(row.output, 200, provider);
    assert.ok(row.cost > 0, `${provider} cost`);
  }
  // The Mac spells it the provider's way before recording; same figures.
  const mac = U.record({}, { task: 'library', model: 'claude-sonnet-5-5', usage: { input_tokens: 1000, output_tokens: 200 }, now });
  const desk = U.record({}, { task: 'library', model: 'claude-sonnet-5-5', usage: { inputTokens: 1000, outputTokens: 200 }, now });
  assert.deepEqual(mac, desk);
  assert.equal(U.costOf({ inputTokens: 1000, outputTokens: 200 }, 'x'), U.costOf({ input_tokens: 1000, output_tokens: 200 }, 'x'));
});
