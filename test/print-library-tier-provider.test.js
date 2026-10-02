'use strict';

/**
 * A tiered model's sidecar names where it went, and fetching it back asks that
 * remote first, then the other. The desktop wrote the bucket endpoint for a
 * model that had gone to Drive, and fetched only from the remote in use, so a
 * model moved before a switch could not come back. Same rule as the Mac's
 * CloudLibrary.route / remoteOrder (#1706).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
const fn = (name) => {
  const at = src.indexOf(`function ${name}(`);
  assert.ok(at > 0, name);
  let depth = 0, i = src.indexOf('{', at);
  for (; i < src.length; i++) { if (src[i] === '{') depth++; else if (src[i] === '}' && --depth === 0) break; }
  return src.slice(at, i + 1);
};

function world({ inUse, s3Configured = true, driveConfigured = true }) {
  const ctx = vm.createContext({
    printLibS3Settings: () => ({ endpoint: 'https://acc.r2.cloudflarestorage.com' }),
    printLibRemote: () => (inUse === 'gdrive' ? { kind: 'gdrive' } : inUse === 's3' ? { kind: 's3' } : null),
    printLibS3: (o) => (s3Configured && (inUse === 's3' || (o && o.evenIfOff)) ? { kind: 's3' } : null),
    printLibDrive: (o) => (driveConfigured && (inUse === 'gdrive' || (o && o.evenIfOff)) ? { kind: 'gdrive' } : null),
  });
  vm.runInContext(`${fn('printLibSidecarProvider')}\n${fn('printLibRemotesFor')}\nthis.api = { printLibSidecarProvider, printLibRemotesFor };`, ctx);
  return ctx.api;
}
const kinds = (list) => JSON.parse(JSON.stringify(list.map((r) => r.kind)));  // out of the vm's realm

test('the sidecar records the remote the model actually went to', () => {
  const w = world({ inUse: 'gdrive' });
  assert.equal(w.printLibSidecarProvider({ kind: 'gdrive' }), 'gdrive');
  assert.equal(w.printLibSidecarProvider({ kind: 's3' }), 'https://acc.r2.cloudflarestorage.com');
});

test('fetching back asks the named remote first, then the other: the Mac\'s cases', () => {
  assert.deepEqual(kinds(world({ inUse: 's3' }).printLibRemotesFor('gdrive')), ['gdrive', 's3']);
  assert.deepEqual(kinds(world({ inUse: 'gdrive' }).printLibRemotesFor('https://acc.r2.cloudflarestorage.com')), ['s3', 'gdrive']);
  assert.deepEqual(kinds(world({ inUse: 'gdrive' }).printLibRemotesFor('')), ['gdrive', 's3'], 'an older sidecar starts with the remote in use');
  assert.deepEqual(kinds(world({ inUse: 's3' }).printLibRemotesFor(undefined)), ['s3', 'gdrive']);
});

test('a remote that is configured but not in use is still asked; one never set up is not', () => {
  assert.deepEqual(kinds(world({ inUse: 's3', driveConfigured: false }).printLibRemotesFor('gdrive')), ['s3']);
  assert.deepEqual(kinds(world({ inUse: null, s3Configured: false, driveConfigured: false }).printLibRemotesFor('gdrive')), []);
});

test('the sweep writes the real provider, and every read goes through the ordered fetch', () => {
  assert.match(src, /provider: printLibSidecarProvider\(s3\),/);
  assert.doesNotMatch(src, /provider: printLibS3Settings\(\)\.endpoint/);
  const re = fn('printLibRehydrate');
  assert.match(re, /printLibRemotesFor\(side\.provider\)/);
  assert.match(re, /for \(const r of remotes\)/);
});
