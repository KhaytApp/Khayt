/**
 * The presets exist to stop a shop mistyping an endpoint, so the thing worth
 * testing is that they cannot themselves introduce one.
 *
 * Two failure modes drive most of this file:
 *
 *   1. A round trip that does not close. Settings renders the saved endpoint,
 *      the shop edits an unrelated field, the form saves — and if detect() and
 *      extractVars() do not agree with resolveEndpoint(), that save rewrites a
 *      working endpoint into a broken one. Nobody would connect the outage to
 *      the field they actually touched.
 *
 *   2. A template that looks plausible and is wrong. IDrive e2 issues per-account
 *      hosts and Synology moved domains; both were caught only by checking, and a
 *      test is what keeps a future "tidy-up" from re-guessing them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const SP = require('../lib/storage-providers.js');

test('every provider is internally consistent', () => {
  const seen = new Set();
  for (const p of SP.PROVIDERS) {
    assert.ok(p.id && !seen.has(p.id), `duplicate or missing id: ${p.id}`);
    seen.add(p.id);
    assert.ok(p.label, `${p.id} needs a label`);
    // Every {placeholder} in the template must have a var to fill it, or the
    // endpoint ships to the bucket with a literal brace in the hostname.
    const holes = [...String(p.endpoint || '').matchAll(/\{(\w+)\}/g)].map((m) => m[1]);
    const keys = p.vars.map((v) => v.key);
    for (const h of holes) assert.ok(keys.includes(h), `${p.id}: {${h}} has no var`);
    for (const k of keys) assert.ok(holes.includes(k) || k === 'region', `${p.id}: var ${k} fills nothing`);
    for (const v of p.vars) assert.ok(v.label && v.hint, `${p.id}.${v.key} needs a label and a hint`);
  }
});

test('resolveEndpoint fills the template', () => {
  const r = SP.resolveEndpoint('r2', { account: 'abc123' });
  assert.equal(r.ok, true);
  assert.equal(r.endpoint, 'https://abc123.r2.cloudflarestorage.com');
  assert.equal(r.region, 'auto');
});

test('a region in the hostname is also the signing region', () => {
  // B2 signs against the region in its host. Defaulting to 'auto' here produces
  // a signature mismatch that the shop reads as a bad secret, and they go and
  // re-copy a key that was never wrong.
  const r = SP.resolveEndpoint('b2', { region: 'us-west-004' });
  assert.equal(r.endpoint, 'https://s3.us-west-004.backblazeb2.com');
  assert.equal(r.region, 'us-west-004');
});

test('missing variables are all reported at once, not one per attempt', () => {
  const r = SP.resolveEndpoint('oci', {});
  assert.equal(r.ok, false);
  assert.deepEqual(r.missing.sort(), ['namespace', 'region']);
  assert.match(r.error, /namespace/i);
  assert.match(r.error, /region/i);
});

test('providers without a template keep the endpoint the shop typed', () => {
  // The regression this guards: returning '' for these wiped a working endpoint
  // whenever any other field on the Settings page was saved.
  for (const id of ['custom', 'idrive']) {
    const r = SP.resolveEndpoint(id, { endpoint: 'https://r4a6.or5.idrivee2-75.com' });
    assert.equal(r.ok, true, id);
    assert.equal(r.endpoint, 'https://r4a6.or5.idrivee2-75.com', id);
  }
});

test('unknown provider is refused rather than guessed at', () => {
  assert.equal(SP.resolveEndpoint('dropbox', {}).ok, false);
});

test('detect recognises each templated provider from its own endpoint', () => {
  for (const p of SP.PROVIDERS) {
    if (!p.endpoint) continue;
    const filled = p.endpoint.replace(/\{\w+\}/g, 'x1');
    assert.equal(SP.detect(filled), p.id, `${p.id} did not recognise ${filled}`);
  }
});

test('detect handles e2 hosts, whose domain carries a varying number', () => {
  assert.equal(SP.detect('https://r4a6.or5.idrivee2-75.com'), 'idrive');
  assert.equal(SP.detect('https://u6a5.bn.idrivee2-61.com'), 'idrive');
  assert.equal(SP.detect('https://s3.us-west-2.idrivee2.com'), 'idrive');
});

test('a NAS is called a NAS, so its one caveat can be shown', () => {
  // 'custom' would hide the note about the copy being in the same building.
  assert.equal(SP.detect('http://192.168.1.20:9000'), 'minio');
  assert.equal(SP.detect('http://nas.local:9000'), 'minio');
  assert.equal(SP.detect('http://truenas:9000'), 'minio');
});

test('detect falls back to custom, and says nothing about nothing', () => {
  assert.equal(SP.detect('https://storage.example.co.uk'), 'custom');
  assert.equal(SP.detect(''), '');
  assert.equal(SP.detect(null), '');
});

test('extractVars round-trips resolveEndpoint for every templated provider', () => {
  // This closes the loop that Settings depends on: render → edit → save must
  // land on the same endpoint it started from.
  for (const p of SP.PROVIDERS) {
    if (!p.endpoint || !p.vars.length) continue;
    const vars = Object.fromEntries(p.vars.map((v, i) => [v.key, `v${i}${p.id}`]));
    const built = SP.resolveEndpoint(p.id, vars);
    assert.equal(built.ok, true, p.id);
    assert.deepEqual(SP.extractVars(p.id, built.endpoint), vars, `${p.id} did not round-trip`);
  }
});

test('extractVars does not mistake a different provider for this one', () => {
  assert.deepEqual(SP.extractVars('r2', 'https://s3.eu-central-1.amazonaws.com'), {});
});

test('the prices carry the date they were checked', () => {
  // A figure with no date is a figure nobody can tell is stale.
  assert.match(SP.PRICED_ON, /^\d{4}-\d{2}-\d{2}$/);
});

test('Wasabi is listed with its minimums, not quietly omitted', () => {
  // It was left off an earlier draft. A shop will find it anyway, and the two
  // minimums are the whole story below 1 TB.
  const w = SP.byId('wasabi');
  assert.ok(w, 'wasabi should be offered');
  assert.match(w.note, /1 TB minimum/i);
  assert.match(w.note, /90/);
});

/**
 * The signup links exist for the shop that has no account yet — every other
 * field on the settings page is copied off a dashboard, so before the signup
 * the whole form is unfillable. Two things are worth holding still:
 *
 *   1. Every provider a shop can pick has somewhere to go. A missing link is
 *      not a visible bug: the anchor just does not render, and the one shop it
 *      was for sees the same blank form as before.
 *
 *   2. A referral link cannot become an attack on the shop. It is the only
 *      string in this file that arrives by paste rather than by literal, and
 *      the renderer hands whatever it gets to the OS browser.
 */
test('every provider a shop can sign up for has a link', () => {
  for (const p of SP.PROVIDERS) {
    if (p.id === 'custom') {
      assert.ok(!p.signup, 'custom has nothing to sign up for');
      continue;
    }
    assert.ok(p.signup, `${p.id} needs a signup link`);
    assert.ok(SP.isSafeSignupUrl(p.signup), `${p.id}: unsafe signup URL ${p.signup}`);
  }
});

test('signupLink returns the plain link, undisclosed, when no referral is set', () => {
  const r = SP.signupLink('r2');
  assert.equal(r.url, SP.byId('r2').signup);
  assert.equal(r.referral, false);
});

test('signupLink is null where there is nothing to sign up for', () => {
  assert.equal(SP.signupLink('custom'), null);
  assert.equal(SP.signupLink('nope'), null);
});

test('a configured referral is used AND flagged for disclosure', () => {
  // Flagged is the half that matters: the renderer only discloses what it is
  // told to, so a referral that resolves without the flag is an undisclosed
  // commercial link in a settings page.
  SP.REFERRALS.b2 = 'https://www.backblaze.com/sign-up/cloud-storage?ref=test';
  try {
    const r = SP.signupLink('b2');
    assert.equal(r.url, 'https://www.backblaze.com/sign-up/cloud-storage?ref=test');
    assert.equal(r.referral, true);
    const listed = SP.list().find((p) => p.id === 'b2');
    assert.equal(listed.signup, r.url);
    assert.equal(listed.signupReferral, true);
  } finally { delete SP.REFERRALS.b2; }
});

test('an unsafe referral falls back to the plain link rather than shipping', () => {
  // A dead signup button is worse than an honest one, so this degrades to the
  // literal rather than to nothing — and it must not degrade to *opening* it.
  for (const bad of [
    'javascript:alert(1)',
    'http://www.backblaze.com/?ref=x',      // not https
    'https://user:pw@backblaze.com/?ref=x', // credentials in the URL
    'https://localhost/?ref=x',             // no dot: not a public host
    'not a url',
  ]) {
    assert.equal(SP.isSafeSignupUrl(bad), false, `should be rejected: ${bad}`);
    SP.REFERRALS.b2 = bad;
    try {
      const r = SP.signupLink('b2');
      assert.equal(r.url, SP.byId('b2').signup, `fell through wrongly for ${bad}`);
      assert.equal(r.referral, false);
    } finally { delete SP.REFERRALS.b2; }
  }
});

test('the renderer is handed a resolved link, never the referral table', () => {
  for (const p of SP.list()) {
    assert.equal(typeof p.signup, 'string');
    assert.equal(typeof p.signupReferral, 'boolean');
    assert.ok(!('REFERRALS' in p));
  }
});

/**
 * THE WHOLE ENDPOINT, PASTED INTO THE FIELD THAT WANTS ONE PIECE OF IT.
 *
 * Backblaze's template is `https://s3.{region}.backblazeb2.com`, and the hint
 * on the Region box says "In your bucket's endpoint, e.g. us-west-004". A shop
 * copied the endpoint out of the B2 dashboard and pasted all of it, which
 * composed a host that does not exist:
 *
 *     https://s3.s3.us-west-001.backblazeb2.com.backblazeb2.com
 *
 * It was saved with enabled:true and sat there. Nothing between the settings
 * page and the first upload asks whether the address resolves, so the failure
 * arrives as an S3 error in a background job months later — found by reading a
 * real shop's settings, not by a report.
 *
 * The hint already tried to prevent this and did not, so the fix is not a
 * better hint.
 */
test('resolveEndpoint: a pasted endpoint in a variable field is read as one', () => {
  const plain = SP.resolveEndpoint('b2', { region: 'us-west-001' });
  const pasted = SP.resolveEndpoint('b2', { region: 's3.us-west-001.backblazeb2.com' });
  const withScheme = SP.resolveEndpoint('b2', { region: 'https://s3.us-west-001.backblazeb2.com' });

  assert.equal(plain.endpoint, 'https://s3.us-west-001.backblazeb2.com');
  assert.deepEqual(pasted, plain, 'the pasted endpoint must land where the plain region does');
  assert.deepEqual(withScheme, plain, 'and so must one copied with its scheme');

  // The region is signed against, not just addressed — B2 rejects 'auto' with a
  // signature error that reads to a shop like a wrong secret key.
  assert.equal(pasted.region, 'us-west-001');
});

test('resolveEndpoint: the same recovery works for every templated provider', () => {
  for (const [id, key, value, whole] of [
    ['r2', 'account', 'abc123', 'abc123.r2.cloudflarestorage.com'],
    ['b2', 'region', 'us-west-004', 's3.us-west-004.backblazeb2.com'],
    ['do', 'region', 'fra1', 'fra1.digitaloceanspaces.com'],
    ['wasabi', 'region', 'us-east-1', 's3.us-east-1.wasabisys.com'],
  ]) {
    assert.deepEqual(SP.resolveEndpoint(id, { [key]: whole }), SP.resolveEndpoint(id, { [key]: value }),
      `${id}: a pasted endpoint should resolve like the bare ${key}`);
  }
});

test('resolveEndpoint: an ordinary value is left exactly alone', () => {
  // No dot, so nothing is even attempted.
  assert.equal(SP.resolveEndpoint('b2', { region: 'us-west-004' }).endpoint,
    'https://s3.us-west-004.backblazeb2.com');
  assert.equal(SP.resolveEndpoint('r2', { account: 'deadbeef0123' }).endpoint,
    'https://deadbeef0123.r2.cloudflarestorage.com');

  // A dot that is NOT this provider's endpoint is not touched either: the
  // recovery only fires when the value matches the whole template. Nonsense in
  // still comes out as nonsense, which is the honest outcome — silently
  // rewriting a value nobody can explain would be worse than a wrong address.
  const odd = SP.resolveEndpoint('b2', { region: 'us.west.004' });
  assert.equal(odd.endpoint, 'https://s3.us.west.004.backblazeb2.com');
  assert.equal(odd.region, 'us.west.004');

  // Another provider's endpoint in this provider's field is not this
  // provider's template, so it stands.
  const crossed = SP.resolveEndpoint('b2', { region: 'fra1.digitaloceanspaces.com' });
  assert.equal(crossed.region, 'fra1.digitaloceanspaces.com');
});

test('resolveEndpoint: still refuses when the field is empty', () => {
  const r = SP.resolveEndpoint('b2', {});
  assert.equal(r.ok, false);
  assert.deepEqual(r.missing, ['region']);
});

test('resolveEndpoint: a provider with no template keeps what was typed', () => {
  // IDrive e2 issues every account its own host; 'custom' is whatever a shop
  // has. Neither may be rewritten by any of the above.
  const r = SP.resolveEndpoint('custom', { endpoint: 'https://minio.local:9000', region: 'eu' });
  assert.equal(r.ok, true);
  assert.equal(r.endpoint, 'https://minio.local:9000');
  assert.equal(r.region, 'eu');
});

// ── repair: a config saved before the recovery existed ────────────────────
//
// A SHOP'S ACTUAL SAVED SETTINGS. Backblaze's dashboard shows the endpoint
// `s3.us-west-001.backblazeb2.com` and the Region box asks for the part in the
// middle; the whole host went in, and the template composed a name carrying the
// provider's suffix twice over. It resolved to nothing, `enabled` was true, and
// the library quietly never synced — with no error on any screen to say so.
const BROKEN = {
  provider: 'b2',
  endpoint: 'https://s3.s3.us-west-001.backblazeb2.com.backblazeb2.com',
  region: 's3.us-west-001.backblazeb2.com',
  bucket: 'KhaytLibrary',
  accessKeyId: 'K001xxx',
};

test('repair recomposes the address the shop meant', () => {
  const fixed = SP.repair(BROKEN);
  assert.equal(fixed.endpoint, 'https://s3.us-west-001.backblazeb2.com');
  assert.equal(fixed.region, 'us-west-001');
});

test('repair keeps every other field, including the credentials', () => {
  const fixed = SP.repair(BROKEN);
  assert.equal(fixed.bucket, 'KhaytLibrary');
  assert.equal(fixed.accessKeyId, 'K001xxx');
  assert.equal(fixed.provider, 'b2');
});

test('repair leaves a working config exactly as it is', () => {
  const good = {
    provider: 'b2', endpoint: 'https://s3.us-west-004.backblazeb2.com', region: 'us-west-004',
  };
  assert.deepEqual(SP.repair(good), good);
});

// Better a broken endpoint the shop can see and correct than a plausible one
// this invented, which would address somebody else's bucket.
test('repair leaves alone what it cannot make sense of', () => {
  for (const cfg of [
    { provider: 'custom', endpoint: 'https://storage.example.internal' },
    { provider: 'b2', endpoint: '', region: '' },
    { endpoint: 'not a url at all' },
    {},
  ]) assert.deepEqual(SP.repair(cfg), cfg);
});

test('repair survives being handed nothing', () => {
  assert.equal(SP.repair(null), null);
  assert.equal(SP.repair(undefined), undefined);
});

// The provider field is recent; an older book has only the host, and the suffix
// that identifies it survives the doubling that broke the address.
test('repair works out the provider from the endpoint when the field is missing', () => {
  const fixed = SP.repair({ ...BROKEN, provider: undefined });
  assert.equal(fixed.endpoint, 'https://s3.us-west-001.backblazeb2.com');
});

test('repair is idempotent — repairing a repair changes nothing', () => {
  const once = SP.repair(BROKEN);
  assert.deepEqual(SP.repair(once), once);
});
