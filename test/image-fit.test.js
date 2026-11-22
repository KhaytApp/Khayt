const { test } = require('node:test');
const assert = require('node:assert/strict');
const F = require('../lib/image-fit.js');

/**
 * A storefront rejects an image over its limit — Medusa at 1 MB — and the shop
 * finds out at the END of making a listing. Getting under that limit is easy;
 * the two ways to get it wrong are what these pin.
 *
 *   re-encoding something that was already fine   — quality lost for nothing,
 *                                                   and lost again every time
 *   grinding it down until it is unusable         — and calling that success
 */

const MB = 1024 * 1024;

test('an image already within the limit is left completely alone', () => {
  // Re-encoding it would cost quality and buy nothing — and doing it on every
  // listing would degrade the same photo repeatedly, each pass a little worse.
  const r = F.fitPlan({ bytes: 600 * 1024, width: 1500, height: 1000, format: 'jpeg' });
  assert.equal(r.keep, true);
  assert.deepEqual(r.steps, []);
});

test('oversized dimensions alone are not a reason to touch it', () => {
  // The storefront's limit is bytes. A 3000px photo that encodes to 400 KB is
  // accepted, and shrinking it would be us imposing a rule nobody has.
  const r = F.fitPlan({ bytes: 400 * 1024, width: 3000, height: 2000, format: 'jpeg', maxEdge: 3000 });
  assert.equal(r.keep, true);
});

test('quality is spent before pixels are', () => {
  // Recompressing at the same size is nearly invisible; halving the resolution
  // is not. So the cheap thing is tried first.
  const r = F.fitPlan({ bytes: 4 * MB, width: 2000, height: 1500, format: 'jpeg' });
  assert.equal(r.keep, false);
  const first = r.steps[0];
  assert.equal(first.maxEdge, 2000, 'the first attempt keeps the size');
  assert.equal(first.quality, 90);
  const firstShrink = r.steps.findIndex((s) => s.maxEdge < 2000);
  const lastQuality = r.steps.findIndex((s) => s.quality === F.FLOOR_QUALITY);
  assert.ok(lastQuality < firstShrink, 'every quality is tried before any pixels are given up');
});

test('transparency is tried in PNG before it is flattened', () => {
  // Flattening alpha onto white is a visible change to somebody's product photo:
  // a cut-out mug becomes a mug on a white rectangle. It is the fallback, not
  // the opening move.
  const r = F.fitPlan({ bytes: 3 * MB, width: 2000, height: 2000, format: 'png', hasAlpha: true });
  assert.equal(r.steps[0].format, 'png');
  assert.ok(r.steps.some((s) => s.format === 'jpeg'), 'but JPEG is still available if PNG cannot fit');
  assert.match(r.note, /transparency/);
});

test('a photographic PNG goes straight to JPEG', () => {
  // With nothing to preserve, PNG is simply the wrong container for a
  // photograph and trying it first would waste every step on the ladder.
  const r = F.fitPlan({ bytes: 3 * MB, width: 2000, height: 2000, format: 'png' });
  assert.equal(r.steps[0].format, 'jpeg');
});

test('the ladder stops before the picture stops being a picture', () => {
  // Reached without fitting, the answer is "this cannot be done" — not a smear
  // at quality 30. A shop can crop or re-shoot; it cannot undo what we did to
  // its only picture.
  const r = F.fitPlan({ bytes: 80 * MB, width: 8000, height: 8000, format: 'jpeg' });
  for (const s of r.steps) {
    assert.ok(s.maxEdge >= F.FLOOR_EDGE, `${s.maxEdge}px is below the floor`);
    if (s.quality != null) assert.ok(s.quality >= F.FLOOR_QUALITY, `quality ${s.quality} is below the floor`);
  }
});

test('the ladder only ever gets smaller, never bigger', () => {
  // Upscaling a small file that is somehow over budget would make it larger,
  // and a step that increases the size is a step that can never succeed.
  const r = F.fitPlan({ bytes: 2 * MB, width: 1000, height: 900, format: 'jpeg' });
  for (const s of r.steps) assert.ok(s.maxEdge <= 1000, `${s.maxEdge}px is larger than the original`);
});

// ── What the shop is told ───────────────────────────────────────────────────

test('a failure says what to do, not what went wrong internally', () => {
  const msg = F.describeResult({ ok: false, reason: 'too-large' });
  assert.match(msg, /crop it, or use a smaller picture/i);
});

test('a success says what was done to the picture', () => {
  // Said rather than implied. A silently recompressed photo is one somebody
  // later notices looks worse than the file on their disk, and wonders what else
  // Khayt changed without saying.
  const msg = F.describeResult({
    ok: true, originalFormat: 'png', format: 'jpeg',
    originalWidth: 4000, width: 2000, height: 1500,
    originalBytes: 4 * MB, bytes: 800 * 1024,
  });
  assert.match(msg, /converted to JPEG/);
  assert.match(msg, /resized to 2000×1500/);
  assert.match(msg, /4096 KB down to 800 KB/);
});

test('leaving it alone says so too', () => {
  assert.match(F.describeResult({ keep: true }), /already within the limit/i);
});

test('a refusal names the kind of refusal, so the shop knows what to change', () => {
  // "Too large to get under the limit" and "too many pixels to process" want
  // different actions — recompress-or-crop versus export smaller — and one
  // message for both would send half of the people the wrong way.
  const bomb = F.describeResult({ ok: false, reason: 'too-many-pixels', originalWidth: 9000, originalHeight: 8000 });
  assert.match(bomb, /too many pixels/i);
  assert.match(bomb, /9000×8000/, 'says which image, in the terms the shop sees in its own file browser');
  assert.match(bomb, /export it at a smaller size/i);

  assert.match(F.describeResult({ ok: false, reason: 'unreadable' }), /could not read that as an image/i);
  // And the ordinary case is unchanged.
  assert.match(F.describeResult({ ok: false, reason: 'too-large' }), /crop it, or use a smaller picture/i);
});
