'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const acct = require('../lib/makerrun-account');

function tmpDir() {
  const d = path.join(os.tmpdir(), 'bedready-acct-test-' + process.pid + '-' + Math.floor(process.hrtime()[1]));
  fs.mkdirSync(d, { recursive: true });
  return d;
}

test('parseDeepLink reads tokens from the fragment', () => {
  const t = acct.parseDeepLink('bedready://auth#access_token=AAA&refresh_token=RRR&expires_at=1234');
  assert.deepEqual(t, { access: 'AAA', refresh: 'RRR', expires: 1234, state: '' });
});

test('parseDeepLink surfaces the state nonce when present, else empty string', () => {
  const withState = acct.parseDeepLink('bedready://auth#access_token=A&refresh_token=R&expires_at=1&state=abc123');
  assert.equal(withState.state, 'abc123');
  const without = acct.parseDeepLink('bedready://auth#refresh_token=R');
  assert.equal(without.state, '');
});

test('parseDeepLink normalizes a millisecond expires_at to seconds', () => {
  // Supabase sends seconds; guard against contract drift that sends ms (else the token never refreshes).
  const t = acct.parseDeepLink('bedready://auth#refresh_token=R&expires_at=1700000000000');
  assert.equal(t.expires, 1700000000);
});

test('parseDeepLink rejects malformed / token-less links', () => {
  assert.equal(acct.parseDeepLink('bedready://auth'), null); // no fragment
  assert.equal(acct.parseDeepLink('bedready://auth#access_token=AAA'), null); // no refresh_token
  assert.equal(acct.parseDeepLink(''), null);
  assert.equal(acct.parseDeepLink(null), null);
});

test('link / isLinked / read / clear round-trip', () => {
  const dir = tmpDir();
  assert.equal(acct.isLinked(dir), false);
  assert.equal(acct.link(dir, { access: 'A', refresh: 'R', expires: 999 }), true);
  assert.equal(acct.isLinked(dir), true);
  assert.deepEqual(acct.read(dir), { access: 'A', refresh: 'R', expires: 999 });
  acct.clear(dir);
  assert.equal(acct.isLinked(dir), false);
  assert.equal(acct.read(dir), null);
});

test('read decodes a legacy plaintext token file (backward compat)', () => {
  // Files written before at-rest encryption have no __enc__ prefix — they must still read cleanly.
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'bedready-account.json'), JSON.stringify({ access: 'A', refresh: 'R', expires: 5 }));
  assert.deepEqual(acct.read(dir), { access: 'A', refresh: 'R', expires: 5 });
});

test('read tolerates an encrypted field it cannot decrypt (returns it, never throws)', () => {
  // On a machine without safeStorage (or after a device move) an __enc__ value can't be decrypted;
  // read() must not throw — it returns the ciphertext, which the caller treats as an unusable token.
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, 'bedready-account.json'), JSON.stringify({ access: '__enc__abc', refresh: '__enc__def', expires: 5 }));
  const d = acct.read(dir);
  assert.equal(d.expires, 5);
  assert.equal(d.refresh, '__enc__def');
});

test('link refuses tokens without a refresh token', () => {
  const dir = tmpDir();
  assert.equal(acct.link(dir, { access: 'A' }), false);
  assert.equal(acct.isLinked(dir), false);
});

test('getAccessToken returns the stored token when it is not near expiry (no network)', async () => {
  const dir = tmpDir();
  acct.link(dir, { access: 'STILL_GOOD', refresh: 'R', expires: 10_000 });
  const tok = await acct.getAccessToken(dir, /* now */ 5_000); // 5000s of headroom
  assert.equal(tok, 'STILL_GOOD');
});

test('getAccessToken throws a helpful error when not linked', async () => {
  const dir = tmpDir();
  await assert.rejects(() => acct.getAccessToken(dir), /Not linked/);
});

test('getAccessToken single-flights concurrent refreshes (no rotating-token replay)', async () => {
  const dir = tmpDir();
  acct.link(dir, { access: 'OLD', refresh: 'R0', expires: 100 }); // already expired vs now below
  const real = global.fetch;
  let calls = 0;
  global.fetch = async () => {
    calls++;
    await new Promise((r) => setTimeout(r, 5)); // hold the request open so a second call can overlap
    return { status: 200, ok: true, json: async () => ({ access_token: 'NEW', refresh_token: 'R1', expires_at: 9_999 }) };
  };
  try {
    // Two overlapping callers (e.g. a double-clicked Sync) with an expired token.
    const [a, b] = await Promise.all([
      acct.getAccessToken(dir, /* now */ 1_000),
      acct.getAccessToken(dir, /* now */ 1_000),
    ]);
    assert.equal(a, 'NEW');
    assert.equal(b, 'NEW');
    assert.equal(calls, 1, 'the refresh token is exchanged exactly once, never replayed');
    assert.equal(acct.read(dir).refresh, 'R1', 'the rotated refresh token is persisted');
  } finally {
    global.fetch = real;
  }
});

test('getAccessToken keeps a racing-refresh session on 401 for a stale token', async () => {
  const dir = tmpDir();
  acct.link(dir, { access: 'OLD', refresh: 'R_STALE', expires: 100 });
  const real = global.fetch;
  global.fetch = async () => {
    // Simulate that another refresh already rotated the stored token in while our request was in flight.
    acct.link(dir, { access: 'LIVE', refresh: 'R_FRESH', expires: 9_999 });
    return { status: 401, ok: false, json: async () => ({}) };
  };
  try {
    await assert.rejects(() => acct.getAccessToken(dir, /* now */ 1_000), /link expired/);
    assert.equal(acct.isLinked(dir), true, 'a 401 for a stale token must not wipe the freshly-rotated link');
    assert.equal(acct.read(dir).refresh, 'R_FRESH');
  } finally {
    global.fetch = real;
  }
});

test('the token refresh is POSTed to makerrun.com, not the old host', async () => {
  // The one regression this whole migration cannot see on its own. bedready.io still
  // serves /api/* as a compatibility alias, so a slip back to the old host keeps
  // WORKING — until the alias is switched off, at which point every linked shop
  // fails at once, far from the change that caused it. Nothing else in the suite
  // pins the host the request actually goes to.
  const dir = tmpDir();
  acct.link(dir, { access: 'OLD', refresh: 'R0', expires: 100 });
  const real = global.fetch;
  let seen = null;
  global.fetch = async (url, opts) => {
    seen = { url: String(url), method: opts && opts.method };
    return { status: 200, ok: true, json: async () => ({ access_token: 'NEW', refresh_token: 'R1', expires_at: 9_999 }) };
  };
  try {
    await acct.getAccessToken(dir, /* now */ 1_000);
    assert.equal(seen.url, 'https://makerrun.com/api/app-token');
    assert.equal(new URL(seen.url).host, 'makerrun.com', 'never bedready.io, which is the converter now');
    assert.equal(seen.method, 'POST');
  } finally { global.fetch = real; }
});

test('the account client takes its host from the one shared constant', () => {
  // Two copies of the host is the shape this migration was cleaning up: a move lands
  // in one module and the other keeps quietly talking to the old address.
  assert.equal(acct.BASE, require('../lib/makerrun').BASE);
  assert.equal(acct.BASE, require('../lib/makerrun-library').BASE, 'both clients, one host');
});
