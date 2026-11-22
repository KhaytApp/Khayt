'use strict';

/**
 * The desktop's half of #1720 (Mac lane): the actuals estimate counts
 * supports, the executive summary costs a job by the shared rule, marking
 * shipped tells webhooks, and finished-print records are merged, not
 * overwritten.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const PC = require('../lib/printer-poll-cache.js');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('the actuals estimate includes the supports', () => {
  assert.match(read('renderer/order-flows.js'), /\(\+p\.printWeight \|\| 0\) \+ \(\+p\.supportWeight \|\| 0\)\) \* \(p\.qty \|\| 1\)/);
});

test('the executive summary costs a job by KhaytKpiRows.orderCost', () => {
  const a = read('renderer/analytics.js');
  const at = a.indexOf('function openExecutiveSummary');
  const body = a.slice(at, at + 4000);
  assert.match(body, /cost: KhaytKpiRows\.orderCost\(o, \{/);
  assert.doesNotMatch(body, /cost: \(o\.parts \|\| \[\]\)\.reduce/);
});

test('marking shipped and the Ship dialog both fire order_shipped with the bus payload', () => {
  const f = read('renderer/order-flows.js');
  const ms = f.slice(f.indexOf('function markShipped('), f.indexOf('function markShipped(') + 700);
  assert.match(ms, /fireStatusWebhook\('order_shipped', order\)/);
  assert.doesNotMatch(f, /fireWebhook\('order_shipped', \{ orderId/, 'no hand-built payload left');
  assert.equal((f.match(/fireStatusWebhook\('order_shipped', order\)/g) || []).length, 2);
});

test('completions are merged with what was saved, both on save and on restore', () => {
  const m = read('main.js');
  assert.match(m, /mergePersisted\(cur && cur\[COMPLETIONS_KEY\], saved\)/);
  const at = m.indexOf('function rehydrateCompletions');
  assert.match(m.slice(at, at + 2000), /mergePersisted\(\{ \[machineId\]: entry\.completions \}/);
  // The rule itself: another writer's completion survives, duplicates collapse.
  const a = { at: '2026-10-01T10:00:00Z', filename: 'a.gcode', actuals: { grams: 10 } };
  const b = { at: '2026-10-02T10:00:00Z', filename: 'b.gcode', actuals: { grams: 20 } };
  const out = PC.mergePersisted({ M1: [a] }, { M1: [b, a] });
  assert.deepEqual(out.M1.map((c) => c.filename), ['b.gcode', 'a.gcode']);
});
