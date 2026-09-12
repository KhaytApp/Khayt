/**
 * The default AI model is written in nine places, and they have to agree.
 *
 * `main.js`, four spots in `renderer/build.js`, four in `renderer/settings.js`,
 * and one each in `lib/ai-quote.js`, `renderer/app-state.js` and
 * `renderer/integrations.js` all carry the same `|| 'claude-…'` fallback. There
 * is no shared constant, so bumping the model means editing every one — and
 * missing one does not fail anything: the app keeps working, just with two
 * different models depending on which call site you came through, and a cost
 * ledger that prices one of them by luck.
 *
 * That is what this pins. It does not care WHICH model is the default; it cares
 * that there is only one of it, and that `lib/ai-usage.js` knows its price —
 * because an unpriced default silently bills the owner at the fallback rate.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const usage = require('../lib/ai-usage.js');

const ROOT = path.join(__dirname, '..');

/** Every file that hardcodes a default model. NOT ai-usage.js — that one is the
 *  price list, so naming many models is its job rather than a disagreement. */
const FILES = [
  // The default now lives in the provider registry, which is the shared
  // constant this file's header was asking for. `main.js` names no model at
  // all any more — it asks the provider for one.
  'lib/ai-providers.js',
  'main.js',
  'lib/ai-quote.js',
  'renderer/app-state.js',
  'renderer/build.js',
  'renderer/integrations.js',
  'renderer/settings.js',
];

const MODEL_RE = /claude-[a-z0-9-]+/g;

test('every hardcoded default AI model is the same string', () => {
  const found = new Map();
  for (const rel of FILES) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    for (const m of src.match(MODEL_RE) || []) {
      if (!found.has(m)) found.set(m, []);
      if (!found.get(m).includes(rel)) found.get(m).push(rel);
    }
  }
  assert.ok(found.size > 0, 'no default model found at all — did the fallbacks move?');
  assert.equal(
    found.size, 1,
    'the default model disagrees across call sites: '
      + [...found].map(([m, files]) => `${m} in ${files.join(', ')}`).join(' | '),
  );
});

test('the default AI model has a price, so the cost ledger is not guessing', () => {
  // Read from the registry rather than regexed out of a call site: that is
  // where the default is chosen now, and a guard that reads it from anywhere
  // else is pinning a copy.
  const providers = require('../lib/ai-providers.js');
  const model = providers.PROVIDERS.anthropic.defaultModel;
  assert.ok(model, 'the Anthropic provider no longer names a default model');
  assert.equal(
    usage.isEstimatedModel(model), false,
    `${model} is the default but lib/ai-usage.js has no price for it — `
      + 'the owner would be shown the fallback rate as though it were theirs',
  );
});
