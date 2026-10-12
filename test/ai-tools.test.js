const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ai = require('../lib/ai-tools.js');

const ROOT = path.join(__dirname, '..');

/**
 * Every AI feature shares one IPC handler. That handler used to hard-code a
 * single tool definition — name 'quote_extract', description 'Physical facts
 * for a 3D-print quote' — so a customer-reply draft arrived at the model framed
 * as a quote extraction. These tests pin the framing per feature, and pin the
 * request policy (retry / stop-reason / error text) the handler now relies on.
 */

test('every AI task frames itself distinctly to the model', () => {
  const ids = Object.keys(ai.AI_TASKS);
  assert.deepEqual(ids.sort(), ['assistant', 'library', 'price', 'quote', 'reply']);

  const names = new Set(), descs = new Set();
  for (const [id, spec] of Object.entries(ai.AI_TASKS)) {
    assert.ok(spec.name, `${id} has no tool name`);
    assert.ok(spec.description && spec.description.length > 20, `${id} needs a real description`);
    assert.ok(spec.maxTokens > 0, `${id} needs a token budget`);
    assert.equal(names.has(spec.name), false, `${id} reuses tool name '${spec.name}'`);
    assert.equal(descs.has(spec.description), false, `${id} reuses a description`);
    names.add(spec.name);
    descs.add(spec.description);
  }
});

test('only the quote task describes itself as quoting', () => {
  // This is the exact regression: three features presenting as 'quote_extract'.
  for (const [id, spec] of Object.entries(ai.AI_TASKS)) {
    if (id === 'quote') continue;
    const blob = (spec.name + ' ' + spec.description).toLowerCase();
    assert.equal(/quote/.test(blob), false,
      `${id} still frames itself as quoting: ${spec.name} — "${spec.description}"`);
  }
});

test('free-text tasks get more room than structured extractions', () => {
  // A truncated answer surfaces as a parse failure, so the caps must reflect
  // the shape of each output rather than one shared 1024.
  assert.ok(ai.AI_TASKS.assistant.maxTokens > ai.AI_TASKS.quote.maxTokens);
  assert.ok(ai.AI_TASKS.reply.maxTokens > ai.AI_TASKS.quote.maxTokens);
});

test('resolveTool builds the tool definition for a task', () => {
  const schema = { type: 'object', properties: { message: { type: 'string' } } };
  const r = ai.resolveTool('reply', schema);
  assert.equal(r.task, 'reply');
  assert.equal(r.tool.name, ai.AI_TASKS.reply.name);
  assert.equal(r.tool.description, ai.AI_TASKS.reply.description);
  assert.deepEqual(r.tool.input_schema, schema);
  assert.equal(r.maxTokens, ai.AI_TASKS.reply.maxTokens);
});

test('resolveTool falls back rather than throwing on a bad task id', () => {
  // A mislabelled call should still produce a quote, not break the feature.
  for (const bad of [undefined, null, '', 'nope', 42, {}]) {
    const r = ai.resolveTool(bad, { type: 'object' });
    assert.equal(r.task, ai.DEFAULT_TASK, `task ${JSON.stringify(bad)} should fall back`);
    assert.ok(r.tool.name);
  }
});

test('resolveTool always supplies an input_schema object', () => {
  // tool_choice forces this tool, so a missing schema must not send `undefined`.
  for (const bad of [undefined, null, 'nope', 7]) {
    const r = ai.resolveTool('quote', bad);
    assert.equal(typeof r.tool.input_schema, 'object');
    assert.notEqual(r.tool.input_schema, null);
  }
});

test('only transient statuses are retried', () => {
  for (const s of [429, 529, 500, 502, 503, 599]) {
    assert.equal(ai.shouldRetry(s), true, `${s} is transient and should retry`);
  }
  // Retrying these only delays the error the owner needs to act on.
  for (const s of [400, 401, 403, 404, 413, 422, 200]) {
    assert.equal(ai.shouldRetry(s), false, `${s} will fail identically on retry`);
  }
});

test('backoff prefers the server retry-after, then exponential', () => {
  assert.equal(ai.retryDelayMs(0, '5'), 5000);
  assert.equal(ai.retryDelayMs(0), 1000);
  assert.equal(ai.retryDelayMs(1), 2000);
  assert.equal(ai.retryDelayMs(2), 4000);
  // Junk headers must not produce NaN delays (setTimeout(NaN) fires immediately,
  // turning backoff into a hot retry loop against a rate-limited endpoint).
  for (const junk of ['', 'soon', undefined, null, '-3', '0']) {
    const d = ai.retryDelayMs(1, junk);
    assert.ok(Number.isFinite(d) && d > 0, `retry-after ${JSON.stringify(junk)} gave ${d}`);
  }
  // And nothing waits longer than the cap.
  assert.equal(ai.retryDelayMs(0, '99999'), 30000);
  assert.equal(ai.retryDelayMs(20), 30000);
});

test('HTTP errors are distinguishable by cause, not just by number', () => {
  // 'AI API error: HTTP 400' could not tell a bad key from a bad schema.
  const key = ai.describeHttpError(401, null);
  const schema = ai.describeHttpError(400, null);
  const model = ai.describeHttpError(404, null);
  assert.notEqual(key, schema);
  assert.notEqual(schema, model);
  assert.match(key, /key/i);
  assert.match(model, /model/i);
  assert.match(ai.describeHttpError(429, null), /rate limit/i);
});

test('HTTP errors surface the API message when there is one', () => {
  const msg = ai.describeHttpError(400, { error: { message: 'tools.0.input_schema: invalid' } });
  assert.match(msg, /invalid/);
});

test('HTTP errors survive an unreadable body', () => {
  // res.json() fails on an HTML error page from a proxy; the handler passes null.
  for (const body of [null, undefined, {}, { error: null }, 'not json']) {
    const msg = ai.describeHttpError(500, body);
    assert.ok(msg && !/undefined|null|\[object/.test(msg), `bad body ${JSON.stringify(body)} → ${msg}`);
  }
});

test('stop reasons explain a 200 that carried no tool call', () => {
  assert.match(ai.describeStop('refusal'), /declin/i);
  assert.match(ai.describeStop('max_tokens'), /cut off/i);
  assert.ok(ai.describeStop('pause_turn'));
  // A normal turn must NOT be reported as an error — for a forced tool_choice
  // the stop reason is 'tool_use', and end_turn is normal too.
  assert.equal(ai.describeStop('tool_use'), null);
  assert.equal(ai.describeStop('end_turn'), null);
  assert.equal(ai.describeStop(undefined), null);
});

test('every aiExtract call site declares its task', () => {
  // Every call goes through khaytAiExtract (renderer/ai-call.js), which also
  // records spend. The task id is what restores correct framing; a new call site that forgets
  // it silently reverts that feature to being framed as a quote extraction.
  const files = ['renderer/build.js', 'renderer/integrations.js', 'renderer/settings.js'];
  const valid = new Set(Object.keys(ai.AI_TASKS));
  let seen = 0;
  for (const rel of files) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    // Each call spans a few lines; take a window after the call opens.
    const re = /khaytAiExtract\(\{/g;
    let m;
    while ((m = re.exec(src))) {
      seen++;
      const window = src.slice(m.index, m.index + 600);
      const call = window.slice(0, window.indexOf('});') + 1);
      const task = /task:\s*'([a-z]+)'/.exec(call);
      assert.ok(task, `${rel}: an aiExtract call near offset ${m.index} declares no task`);
      assert.ok(valid.has(task[1]), `${rel}: unknown task '${task[1]}'`);
    }
  }
  assert.equal(seen, 6, `expected 6 khaytAiExtract call sites, found ${seen}`);
});
