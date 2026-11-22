/**
 * The desktop poller asks a Klipper printer what it has with
 * `moonraker.discover` — sensors, chamber and per-head fans — and passes the
 * whole answer to `queryWith` / `readStatus`. It asked for the sensors alone,
 * so the chamber and the head fans lib/moonraker.js can read were never in the
 * query. And a failed ask was cached as "no sensors" until the app restarted;
 * now it is asked again after a minute.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const MAIN = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
const block = MAIN.slice(MAIN.indexOf("if (type === 'moonraker') {"), MAIN.indexOf("if (type === 'prusalink') {"));

test('the poller discovers with moonraker.discover and queries with its answer', () => {
  assert.match(block, /moonraker\.discover\(await get\('\/printer\/objects\/list'\)\)/);
  assert.match(block, /moonraker\.queryWith\(sensorNames\)/);
  assert.match(block, /moonraker\.readStatus\(data, hot, hotName, sensorNames, /);
  assert.doesNotMatch(block, /filamentSensors\.sensorNames/);
});

test('a failed discovery is retried, not cached as "has none"', () => {
  assert.match(block, /catch \(e\) \{ found = \{ watched: null, retryAt: Date\.now\(\) \+ MOONRAKER_DISCOVER_RETRY_MS \}; \}/);
  assert.match(block, /!found\.watched && Date\.now\(\) >= found\.retryAt/);
  assert.match(MAIN, /const MOONRAKER_DISCOVER_RETRY_MS = 60 \* 1000;/);
});
