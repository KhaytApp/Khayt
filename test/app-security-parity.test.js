/**
 * The security module that SHIPS is not the one the tests cover.
 *
 * There are two: `lib/app-security.js` on Node's `crypto`, and
 * `renderer/app-security.js` on WebCrypto. That pair is legitimate — a renderer
 * cannot require Node's crypto, and `lib/sync-crypto.js` / `sync-crypto-web.js`
 * exist as the same kind of pair.
 *
 * What was not legitimate is which one had tests. `test/app-security.test.js`
 * requires `../lib/app-security`, and **nothing loads `lib/app-security.js` at
 * runtime**: `index.html` and `bedready.html` both pull in
 * `renderer/app-security.js`, which had no test of any kind. So the PIN gate,
 * the recovery code and the destructive-action gate were verified on a copy
 * nobody runs, and the copy every shop runs was verified by nothing.
 *
 * This is the same shape as the slicer allowlist that was written, explained,
 * tested and never called. A passing test on the wrong copy is worse than no
 * test, because it reads like coverage.
 *
 * So: run the shipped module and compare it to the tested one, over generated
 * codes and the inputs that are actually awkward.
 *
 * ── WHAT IS DELIBERATELY NOT COMPARED ──────────────────────────────────────
 *
 * `hashSecret`. The renderer's prefers `hashPin` when the app provides it —
 * PBKDF2, from `lib/pin-hash.js` — and falls back to plain SHA-256 only when it
 * is absent; `lib`'s is always SHA-256. Those SHOULD differ, and asserting they
 * match would pin the weaker of the two. What must hold is the compatibility
 * path below: a hash written by an older build has to keep verifying, or a shop
 * that set a recovery code last year is locked out of its own book.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const nodeCrypto = require('crypto');

const lib = require('../lib/app-security.js');

/** The shipped module, in a context shaped like the renderer's. */
function loadRenderer() {
  const sandbox = {
    crypto: nodeCrypto.webcrypto,
    TextEncoder,
    TextDecoder,
    console,
    // No `hubAPI`, on purpose: that absence is what exercises the legacy
    // verification path, which is the one that has to stay compatible.
    window: {},
  };
  // `sha256Hex` lives in renderer/ops-locations.js and app-security.js reaches
  // it as a bare global. That exact cross-file reach is what
  // test/cross-file-wiring.test.js was written after — when it was missing from
  // its file's export list, `verifyHash` fell through to `return false` and
  // locked the operator out. Supplied here so a difference cannot be blamed on
  // this harness; without it the two disagree, and it is the harness's fault.
  sandbox.sha256Hex = async (value) => {
    const buf = await sandbox.crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(value)));
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-security.js'), 'utf8'),
    sandbox,
  );
  assert.ok(sandbox.KhaytAppSecurity, 'renderer/app-security.js did not publish its api');
  return sandbox.KhaytAppSecurity;
}

/** Codes from both generators, so neither one's habits are the whole corpus. */
function corpus() {
  const ren = loadRenderer();
  const codes = [];
  for (let i = 0; i < 150; i++) codes.push(lib.generateRecoveryCode());
  for (let i = 0; i < 150; i++) codes.push(ren.generateRecoveryCode());
  return codes;
}

/** The inputs that are actually awkward, rather than a second set of valid ones. */
const AWKWARD = [
  '', '   ', null, undefined, 'KHAYT', 'KHAYT-', '-', 'khayt-aaaa-bbbb-cccc',
  'KHAYT-AAAA-BBBB-CCCC', 'AAAABBBBCCCC', 'aaaabbbbcccc',
  // 0/1/O/I are outside the alphabet on purpose — a recovery code is read off
  // paper and typed by a person.
  'KHAYT-0000-1111-OOOO', 'KHAYT-IIII-LLLL-OOOO',
  'KHAYT--AAAA-BBBB-CCCC', 'KHAYT-AAAA-BBBB-CCCC-DDDD', ' KHAYT-AAAA-BBBB-CCCC ',
  'KHAYT-aaaa-BBBB-cccc', 'KHAYTAAAABBBBCCCC', 'KHAYT_AAAA_BBBB_CCCC',
];

const PINS = [
  '', '0', '12', '123', '1234', '00000', '0000', '1111', '2222', '1234567',
  '12345678', '123456789', '123456789012', 'abcd', '12a4', '9876', '4321',
  '11111111', '01234567', ' 1234', '1234 ', null, undefined,
];

test('the shipped security module and the tested one agree on every pure rule', () => {
  const ren = loadRenderer();
  const codes = corpus();

  for (const fn of ['normalizeRecoveryCode', 'formatRecoveryCode', 'isValidRecoveryCode']) {
    for (const value of codes.concat(AWKWARD)) {
      assert.deepEqual(ren[fn](value), lib[fn](value),
        `${fn}(${JSON.stringify(value)}) differs between renderer/ and lib/`);
    }
  }
  for (const fn of ['isValidPin', 'isWeakPin']) {
    for (const value of PINS) {
      assert.deepEqual(ren[fn](value), lib[fn](value),
        `${fn}(${JSON.stringify(value)}) differs between renderer/ and lib/`);
    }
  }
});

test('a recovery code hashed by an older build still verifies in the shipped one', async () => {
  const ren = loadRenderer();
  for (const code of corpus().slice(0, 60)) {
    // What a build without PBKDF2 wrote: plain SHA-256 of the normalised code.
    const stored = lib.hashSecret(lib.normalizeRecoveryCode(code));
    assert.equal(await ren.verifyRecoveryCode(code, stored), true,
      `the shipped module could not verify a legacy hash for ${code} — that is a lockout`);
    assert.equal(lib.verifyRecoveryCode(code, stored), true);
  }
});

test('a wrong code is refused by both, and so is a malformed one', async () => {
  const ren = loadRenderer();
  const real = lib.generateRecoveryCode();
  const other = lib.hashSecret(lib.normalizeRecoveryCode(lib.generateRecoveryCode()));

  assert.equal(await ren.verifyRecoveryCode(real, other), false);
  assert.equal(lib.verifyRecoveryCode(real, other), false);

  for (const bad of AWKWARD) {
    const stored = lib.hashSecret(lib.normalizeRecoveryCode(real));
    assert.equal(await ren.verifyRecoveryCode(bad, stored), false,
      `${JSON.stringify(bad)} must not verify`);
    assert.equal(lib.verifyRecoveryCode(bad, stored), false);
  }
  // An empty or absent stored hash is not a free pass. This is the shape of the
  // failure that turns "security is off" into "anything unlocks it".
  for (const stored of ['', null, undefined, 0, 'not-a-hash']) {
    assert.equal(await ren.verifyRecoveryCode(real, stored), false);
    assert.equal(lib.verifyRecoveryCode(real, stored), false);
  }
});

test('every rule the tested module has, the shipped one has too', () => {
  const ren = loadRenderer();
  // The renderer's api is larger — it owns the modals and the gates, which need
  // a DOM. What must not happen is the reverse: a rule tested in lib/ that the
  // shipped module does not carry is a rule no shop is running.
  for (const name of Object.keys(lib)) {
    assert.equal(typeof ren[name], 'function',
      `${name} is tested in lib/app-security.js and missing from the module that ships`);
  }
});
