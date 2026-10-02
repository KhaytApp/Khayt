/**
 * Eviction deletes a customer's paid-for model off the disk. That is the only
 * destructive operation in the print library, so the tests that matter here are
 * the ones about refusing to do it.
 *
 * Each of the following is a way a shop loses a model, and each has a test:
 *
 *   - evicting something the bucket never actually received
 *   - evicting the thumbnails, so the library becomes unbrowsable offline
 *   - accepting a download that came back short, or came back as someone else's
 *     file of the same length
 *   - a sidecar too damaged to verify a download, treated as if it were fine
 *   - a tiered model vanishing from the listing, where "in the cloud" and "gone"
 *     become the same thing to the person looking at the screen
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/print-library-tier.js');

const NOW = Date.UTC(2026, 7, 23);
const daysAgo = (d) => NOW - d * 86400000;
const POLICY = T.normalisePolicy({ enabled: true, keepDays: 90, minBytes: 1048576 });

const file = (filename, size, ageDays) => ({ filename, size, mtimeMs: daysAgo(ageDays) });

test('a big, old model is the thing tiering exists for', () => {
  assert.deepEqual(T.evictable(file('dragon.3mf', 80e6, 200), POLICY, NOW), { ok: true, reason: 'ok' });
});

test('previews are never evicted, however old and however large', () => {
  // Evicting these turns drawing the library grid into hundreds of round trips,
  // and a wall of blank placeholders when the bucket is unreachable.
  for (const name of ['thumb.png', 'photo.JPG', 'shot.webp', 'meta.json']) {
    const v = T.evictable(file(name, 500e6, 3650), POLICY, NOW);
    assert.equal(v.ok, false, name);
    assert.equal(v.reason, 'preview', name);
  }
});

test('recent models stay on the disk', () => {
  assert.equal(T.evictable(file('new.stl', 80e6, 3), POLICY, NOW).reason, 'too-recent');
  // The boundary is inclusive: at exactly the policy age it goes.
  assert.equal(T.evictable(file('edge.stl', 80e6, 90), POLICY, NOW).ok, true);
  assert.equal(T.evictable(file('edge.stl', 80e6, 89), POLICY, NOW).ok, false);
});

test('a model imported recently is recent, whatever its copied mtime says', () => {
  // A copy keeps the download's mtime: 400 days old on disk, imported 5 days ago.
  const imported = { ...file('old-download.3mf', 80e6, 400), lastUsedMs: daysAgo(5) };
  assert.equal(T.evictable(imported, POLICY, NOW).reason, 'too-recent');
  // The NEWEST of the two counts — an older lastUsed does not age a fresh file.
  const fresh = { ...file('fresh.3mf', 80e6, 2), lastUsedMs: daysAgo(500) };
  assert.equal(T.evictable(fresh, POLICY, NOW).reason, 'too-recent');
  // Both old: it goes.
  assert.equal(T.evictable({ ...file('cold.3mf', 80e6, 400), lastUsedMs: daysAgo(200) }, POLICY, NOW).ok, true);
});

test('a model an unfinished job needs is never moved off, however old', () => {
  const v = T.evictable({ ...file('queued.3mf', 80e6, 900), inUse: true }, POLICY, NOW);
  assert.deepEqual(v, { ok: false, reason: 'in-use' });
  const p = T.plan([{ ...file('queued.3mf', 80e6, 900), inUse: true }, file('cold.3mf', 80e6, 900)], POLICY, NOW);
  assert.deepEqual(p.candidates.map((f) => f.filename), ['cold.3mf']);
  assert.equal(p.skipped['in-use'], 1);
});

test('small files are left alone — the request costs more than the space', () => {
  assert.equal(T.evictable(file('tiny.gcode', 4096, 500), POLICY, NOW).reason, 'too-small');
});

test('an already-tiered file is not tiered twice', () => {
  assert.equal(T.evictable(file('m.3mf.cloud', 300, 500), POLICY, NOW).reason, 'already-tiered');
});

test('plan reports why nothing happened, not just that nothing happened', () => {
  // A sweep that frees nothing and says nothing looks like a broken button.
  const p = T.plan([
    file('a.3mf', 90e6, 200),
    file('b.stl', 120e6, 400),
    file('recent.3mf', 90e6, 2),
    file('thumb.png', 40e6, 900),
    file('tiny.gcode', 100, 900),
  ], { enabled: true }, NOW);
  assert.equal(p.candidates.length, 2);
  assert.equal(p.bytes, 210e6);
  assert.deepEqual(p.skipped, { 'too-recent': 1, preview: 1, 'too-small': 1 });
});

test('the biggest files are evicted first', () => {
  // A sweep interrupted by an unmounted share should have freed as much as it
  // could get to before it stopped.
  const p = T.plan([file('s.3mf', 2e6, 200), file('l.3mf', 900e6, 200), file('m.3mf', 50e6, 200)], { enabled: true }, NOW);
  assert.deepEqual(p.candidates.map((c) => c.filename), ['l.3mf', 'm.3mf', 's.3mf']);
});

test('a zero keepDays cannot be configured', () => {
  // It would evict every model the moment it was saved, making every first open
  // a download.
  assert.equal(T.normalisePolicy({ keepDays: 0 }).keepDays, 90);
  assert.equal(T.normalisePolicy({ keepDays: -5 }).keepDays, 90);
  assert.equal(T.normalisePolicy({ keepDays: 'soon' }).keepDays, 90);
  assert.equal(T.normalisePolicy({ keepDays: 7 }).keepDays, 7);
});

test('tiering is off unless someone turned it on', () => {
  assert.equal(T.normalisePolicy({}).enabled, false);
  assert.equal(T.normalisePolicy(null).enabled, false);
});

test('sidecar names append, so the real extension survives', () => {
  assert.equal(T.sidecarName('dragon.3mf'), 'dragon.3mf.cloud');
  assert.equal(T.baseName('dragon.3mf.cloud'), 'dragon.3mf');
  assert.equal(T.baseName('dragon.3mf'), 'dragon.3mf');
});

test('a sidecar that cannot verify a download is refused', () => {
  // Worse than no sidecar: it claims the model is safe in the bucket while
  // giving no way to notice it came back wrong.
  const good = JSON.stringify(T.makeSidecar({ size: 10, sha256: 'abc', key: 'k', provider: 'r2', at: 'x' }));
  assert.ok(T.parseSidecar(good));
  assert.equal(T.parseSidecar('{"v":1,"size":10,"key":"k"}'), null, 'no hash');
  assert.equal(T.parseSidecar('{"v":1,"sha256":"a","key":"k"}'), null, 'no size');
  assert.equal(T.parseSidecar('{"v":1,"size":10,"sha256":"a"}'), null, 'no key');
  assert.equal(T.parseSidecar('{"v":99,"size":10,"sha256":"a","key":"k"}'), null, 'future version');
  assert.equal(T.parseSidecar('not json'), null);
  assert.equal(T.parseSidecar(''), null);
});

test('the etag check distinguishes "wrong" from "cannot tell"', () => {
  const md5 = 'd41d8cd98f00b204e9800998ecf8427e';
  assert.equal(T.etagVerdict(md5, md5), 'match');
  assert.equal(T.etagVerdict(`"${md5}"`, md5), 'match', 'buckets quote their etags');
  assert.equal(T.etagVerdict(md5.toUpperCase(), md5), 'match');
  assert.equal(T.etagVerdict('0'.repeat(32), md5), 'mismatch');
  // A multipart etag is not an MD5 of anything. Reading it as a mismatch would
  // condemn a perfectly good object; reading it as a match would delete a local
  // file on no evidence. Neither — the caller has to go and download it.
  assert.equal(T.etagVerdict(`${md5}-4`, md5), 'unusable');
  assert.equal(T.etagVerdict('', md5), 'unusable');
  assert.equal(T.etagVerdict(md5, ''), 'unusable');
});

test('a short download is refused', () => {
  const side = T.makeSidecar({ size: 1000, sha256: 'aa', key: 'k' });
  const r = T.verifyRehydrate(side, 900, 'aa');
  assert.equal(r.ok, false);
  assert.match(r.error, /900/);
});

test('the right length but the wrong file is refused', () => {
  // The one that would hand a customer another shop's model, from a prefix
  // collision in a shared bucket.
  const side = T.makeSidecar({ size: 1000, sha256: 'aa', key: 'k' });
  assert.equal(T.verifyRehydrate(side, 1000, 'bb').ok, false);
  assert.equal(T.verifyRehydrate(side, 1000, 'AA').ok, true, 'hash case should not matter');
});

test('tiered models stay in the listing, at their real size', () => {
  // "In the cloud" and "gone" must never look the same on screen.
  const merged = T.mergeListing(
    [{ filename: 'here.3mf', fullPath: '/lib/here.3mf', size: 500 },
      { filename: 'away.3mf.cloud', fullPath: '/lib/away.3mf.cloud', size: 200 }],
    new Map([['away.3mf', { size: 90e6, key: 'p/away.3mf', sha256: 'aa', fullPath: '/lib/away.3mf' }]]),
  );
  const away = merged.find((m) => m.filename === 'away.3mf');
  assert.ok(away, 'the tiered model must still be listed');
  assert.equal(away.tiered, true);
  assert.equal(away.size, 90e6, 'its real size, not the sidecar\'s');
  assert.equal(merged.find((m) => m.filename === 'here.3mf').tiered, false);
  assert.ok(!merged.some((m) => T.isSidecar(m.filename)), 'sidecars are plumbing, not files');
});

test('a local copy wins over a leftover sidecar', () => {
  // A rehydrate that landed but failed to clean up. The bytes someone is about
  // to open are on the disk, so the row must not claim they need downloading.
  const merged = T.mergeListing(
    [{ filename: 'both.3mf', fullPath: '/lib/both.3mf', size: 90e6 }],
    new Map([['both.3mf', { size: 90e6, key: 'k', sha256: 'aa' }]]),
  );
  assert.equal(merged.length, 1);
  assert.equal(merged[0].tiered, false);
});

test('formatBytes says the thing the decision actually turns on', () => {
  assert.equal(T.formatBytes(0), '0 B');
  assert.equal(T.formatBytes(1024), '1.0 KB');
  assert.equal(T.formatBytes(36 * 1024 ** 3), '36 GB');
  assert.equal(T.formatBytes(1.5 * 1024 ** 3), '1.5 GB');
});
