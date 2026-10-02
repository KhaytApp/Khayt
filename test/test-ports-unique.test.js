'use strict';

/**
 * Every test that starts a real server on a fixed port has a port of its own.
 *
 * `node --test` runs files in parallel, so two files listening on the same
 * port fail at random, whichever starts second. Three LAN tests shared 3994
 * and one of them failed during the 3.11.2 cut. Nothing was wrong with the
 * code under test.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('no two test files hard-code the same server port', () => {
  const dir = __dirname;
  const owners = new Map();
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.test.js'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const m of src.matchAll(/\bconst PORT = (\d{4,5});/g)) {
      const list = owners.get(m[1]) || new Set();
      list.add(f);
      owners.set(m[1], list);
    }
  }
  assert.ok(owners.size >= 10, `expected to find the LAN tests' ports, found ${owners.size}`);
  const shared = [...owners].filter(([, files]) => files.size > 1).map(([p, files]) => `${p}: ${[...files].join(', ')}`);
  assert.deepEqual(shared, [], 'give each file its own port');
});
