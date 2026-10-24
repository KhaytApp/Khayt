/**
 * A model the Mac moved to the Khayt Vault is not asked of the bucket.
 *
 * The desktop has no vault client. Its rule for a sidecar's provider is
 * "gdrive is Drive, anything else a bucket", so a `vault` sidecar sent the
 * bring-back to the bucket, which answered with a missing key — an error that
 * named the wrong place. It is refused by name, before any remote is asked.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

test('bring-back refuses a vault sidecar before asking any remote', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const guard = src.indexOf("=== 'vault'");
  const ask = src.indexOf('const remotes = printLibRemotesFor(side.provider);');
  assert.ok(guard !== -1, 'vault is refused by name');
  assert.ok(ask !== -1 && guard < ask, 'the refusal comes before the remotes are asked');
  assert.match(src.slice(guard, ask), /return \{ ok: false, error: '[^']*Khayt Vault[^']*Mac/);
});
