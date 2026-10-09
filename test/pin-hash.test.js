const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const {
  hashPin, verifyPin, isPbkdf2Hash, isLegacySha256Hash, isManagedHash, needsUpgrade,
} = require('../lib/pin-hash');

test('hashPin produces the salted PBKDF2 format and verifies', () => {
  const h = hashPin('1357', 50000); // fewer iters to keep the test fast
  assert.ok(isPbkdf2Hash(h));
  assert.equal(h.split('$').length, 4);
  assert.equal(verifyPin('1357', h), true);
  assert.equal(verifyPin('0000', h), false);
});

test('hashPin uses a fresh salt each time (no precomputation)', () => {
  assert.notEqual(hashPin('1357', 50000), hashPin('1357', 50000));
});

test('verifyPin accepts legacy unsalted SHA-256 hashes (backward compat)', () => {
  const legacy = crypto.createHash('sha256').update('4242').digest('hex');
  assert.ok(isLegacySha256Hash(legacy));
  assert.equal(verifyPin('4242', legacy), true);
  assert.equal(verifyPin('9999', legacy), false);
});

test('format detection: managed vs unrecognized (must not be wiped on length alone)', () => {
  const legacy = crypto.createHash('sha256').update('x').digest('hex');
  const salted = hashPin('x', 50000);
  assert.equal(isManagedHash(legacy), true);
  assert.equal(isManagedHash(salted), true);
  // Very-old base64 scheme / garbage → unrecognized, verify fails (re-prompt), not crash.
  assert.equal(isManagedHash('MTIzNA=='), false);
  assert.equal(verifyPin('1234', 'MTIzNA=='), false);
  assert.equal(verifyPin('1234', ''), false);
  assert.equal(verifyPin('1234', undefined), false);
});

test('needsUpgrade flags legacy hashes only', () => {
  assert.equal(needsUpgrade(crypto.createHash('sha256').update('x').digest('hex')), true);
  assert.equal(needsUpgrade(hashPin('x', 50000)), false);
});

/**
 * `needsUpgrade` HAS TO BE CALLED, and it was not.
 *
 * It shipped with this doc comment — "Should this stored hash be upgraded to
 * the salted format on next successful auth?" — and with the test above, and
 * `main.js` imported `hashPin`, `verifyPin` and `isManagedHash` from this
 * module and not it. So a shop that set its PIN before PBKDF2 shipped kept an
 * unsalted SHA-256 hash for ever: verified happily on every unlock, upgraded
 * never.
 *
 * That is not a small difference. A four-to-eight digit PIN under unsalted
 * SHA-256 is a lookup, not a search, and the hash travels in backups and
 * through cloud sync.
 *
 * A successful verify is the only moment the plaintext exists, so it is the
 * only moment an upgrade is possible. These assert that the moment is used.
 */
test('main.js upgrades a legacy hash on a correct PIN', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

  assert.match(main, /needsUpgrade\s*\}?\s*=\s*require\('\.\/lib\/pin-hash'\)|needsUpgrade[^=]*require\('\.\/lib\/pin-hash'\)/,
    'main.js must import needsUpgrade from lib/pin-hash');

  // Both verify handlers, not one. `hub:verify-pin` covers the admin PIN and
  // the recovery code; `hub:verify-operator-pin` covers the shop floor, and an
  // operator PIN left on the old format is the same weakness.
  const calls = (main.match(/needsUpgrade\(/g) || []).length;
  assert.ok(calls >= 2,
    `expected needsUpgrade at both verify handlers, found ${calls} call(s)`);
});

test('the renderer keeps the replacement rather than dropping it', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');

  // An upgrade that is computed and thrown away is worse than none: it costs
  // the work and leaves the weak hash in place.
  const security = read('app-security.js');
  assert.match(security, /answer\.upgraded/,
    'app-security.js ignores the replacement hash');
  assert.match(security, /admin\.pinHash = upgraded/,
    'the admin PIN upgrade is never written back');
  assert.match(security, /settings\.recoveryCodeHash = upgraded/,
    'the recovery code upgrade is never written back');

  const ops = read('ops-locations.js');
  assert.match(ops, /op\.pinHash = verified\.upgraded/,
    'the operator PIN upgrade is never written back');
});

test('an upgraded hash verifies the same PIN and is no longer legacy', () => {
  const legacy = crypto.createHash('sha256').update('4821').digest('hex');
  assert.equal(verifyPin('4821', legacy), true, 'the old hash must keep working');
  assert.equal(needsUpgrade(legacy), true);

  // What the handler hands back.
  const upgraded = hashPin('4821');
  assert.equal(needsUpgrade(upgraded), false, 'the replacement must not need upgrading again');
  assert.equal(isPbkdf2Hash(upgraded), true);
  assert.equal(verifyPin('4821', upgraded), true, 'the same PIN must still unlock');
  assert.equal(verifyPin('4822', upgraded), false, 'and a wrong one must not');

  // Salted: two upgrades of the same PIN are different strings, which is the
  // whole reason the old format was a lookup.
  assert.notEqual(hashPin('4821'), hashPin('4821'));
});

test('a wrong PIN against a legacy hash upgrades nothing', () => {
  // The upgrade is gated on the verify succeeding. Re-hashing on a failed
  // attempt would replace the stored hash with one derived from whatever an
  // attacker typed — locking the owner out with the attacker's PIN.
  const legacy = crypto.createHash('sha256').update('4821').digest('hex');
  assert.equal(verifyPin('0000', legacy), false);
  const main = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /ok && needsUpgrade\(/,
    'the upgrade must be gated on the verify succeeding');
});

test('a PIN typed in Arabic or Persian digits is the same PIN; an old Arabic-character hash still opens', () => {
  const P = require('../lib/pin-hash.js');
  const crypto = require('crypto');
  const h = P.hashPin('1234', 1000);
  assert.equal(P.verifyPin('\u0661\u0662\u0663\u0664', h), true);
  assert.equal(P.verifyPin('\u06F1\u06F2\u06F3\u06F4', h), true);
  assert.equal(P.verifyPin('1235', h), false);
  const salt = Buffer.alloc(16, 7);
  const old = 'p2$1000$' + salt.toString('hex') + '$' + crypto.pbkdf2Sync('\u0661\u0662\u0663\u0664', salt, 1000, 32, 'sha256').toString('hex');
  assert.equal(P.verifyPin('\u0661\u0662\u0663\u0664', old), true);
  assert.equal(P.normalizePin('\u0660\u0669'), '09');
});
