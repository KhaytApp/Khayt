'use strict';
/**
 * A review was permanent and invisible.
 *
 * Anyone who could reach POST /v1/shops/{id}/reviews could leave one, and every
 * one of them counted toward `avg` — the star rating the storefront prints:
 *
 *     if (d && d.count > 0) $('#shopRating').textContent = `★ ${d.avg} (${d.count})`;
 *
 * The cloud had no DELETE route and no hidden flag; the desktop showed only the
 * aggregate and a "copy review link" button. So a shop could watch its public
 * rating fall, could not see which reviews were doing it, and could not remove
 * any of them. Rate limiting bounds one address at ten an hour; it bounds
 * nothing in aggregate, and it does not help at all once a review is written.
 *
 * The cloud half is covered by the contract suite against BOTH backends. This is
 * the desktop half — the part that would otherwise be a route nobody calls.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

test('the whole chain exists: client → IPC → preload → renderer', () => {
  // Every link, because any one missing makes the feature dead in a different
  // and equally silent way.
  const client = code('lib/cloud-client.js');
  assert.match(client, /async function listReviews\(/, 'no client call');
  assert.match(client, /async function deleteReview\(/, 'no client call');
  assert.match(client, /^\s*listReviews,$/m, 'listReviews is not exported from the client');
  assert.match(client, /^\s*deleteReview,$/m, 'deleteReview is not exported from the client');

  const main = code('main.js');
  assert.match(main, /ipcMain\.handle\('hub:cloud-list-reviews'/, 'no main handler');
  assert.match(main, /ipcMain\.handle\('hub:cloud-delete-review'/, 'no main handler');

  const pre = code('preload.js');
  assert.match(pre, /cloudListReviews:\s+\(opts\) => ipcRenderer\.invoke\('hub:cloud-list-reviews'/, 'not on the bridge');
  assert.match(pre, /cloudDeleteReview:\s+\(opts\) => ipcRenderer\.invoke\('hub:cloud-delete-review'/, 'not on the bridge');

  const set = code('renderer/settings.js');
  assert.match(set, /window\.hubAPI\.cloudListReviews\(/, 'nothing lists them, so the route is dead');
  assert.match(set, /window\.hubAPI\.cloudDeleteReview\(/, 'nothing deletes them');
});

test('the token is sent — the routes are owner-only', () => {
  const set = code('renderer/settings.js');
  const at = set.indexOf('const renderReviews = async () =>');
  assert.ok(at > 0, 'the review list is gone');
  const body = set.slice(at, at + 3200);
  assert.match(body, /cloudListReviews\(\{ url: c\.url, shopId: c\.shopId, token: c\.token \}\)/,
    'no token, so an owner-only route answers 401 and the panel looks broken');
  assert.match(body, /cloudDeleteReview\(\{ url: c\.url, shopId: c\.shopId, token: c\.token, reviewId:/);
});

test('a failure says why instead of looking like "no reviews"', () => {
  // A blank space here reads as "nobody has reviewed you", which is the one
  // thing it must not be mistaken for.
  const set = code('renderer/settings.js');
  const at = set.indexOf('const renderReviews = async () =>');
  const body = set.slice(at, at + 3200);
  assert.match(body, /store\.reviews_load_failed/, 'a failed load is silent');
  assert.match(body, /store\.reviews_none/, 'an empty list is indistinguishable from a failure');
  assert.match(body, /catch \(e\)/, 'a thrown call escapes and the panel stays on the loading text');
});

test('deleting asks first, and refreshes after', () => {
  const set = code('renderer/settings.js');
  const at = set.indexOf('const renderReviews = async () =>');
  const body = set.slice(at, at + 3200);
  assert.match(body, /confirmModal\([^)]*store\.review_delete_q/, 'a review is deleted on one click, with no confirmation');
  assert.match(body, /danger: true/);
  assert.match(body, /if \(!d \|\| !d\.ok\) \{[^}]*return; \}/, 'a failed delete is reported as success');
  assert.match(body, /renderReviews\(\);\s*\}\);/, 'the list is not refreshed, so a deleted review stays on screen');
});

test('every field from a stranger is escaped', () => {
  // comment and name come from an unauthenticated POST. They are length-capped
  // server-side and nothing more.
  const set = code('renderer/settings.js');
  const at = set.indexOf('const renderReviews = async () =>');
  const body = set.slice(at, at + 3200);
  for (const f of ['rv.comment', 'rv.name', 'rv.id']) {
    const raw = new RegExp(`\\$\\{${f.replace('.', '\\.')}\\s*\\|?\\|?[^}]*\\}`);
    const m = body.match(raw);
    if (!m) continue;
    assert.match(m[0], /escapeHtml\(/, `${f} reaches innerHTML unescaped`);
  }
  assert.match(body, /\$\{escapeHtml\(rv\.comment(?: \|\| '')?\)\}/, 'the comment is not escaped');
  // The rows come from the shared reader, which makes every field a string.
  assert.match(body, /SI\.reviewRows\(r\.reviews\)/, 'the rows are not read through lib/storefront-insights.js');
});

test('the star count cannot be forged into a huge string', () => {
  // '★'.repeat(rating) with an unclamped rating from the server is a trivial
  // way to make the panel unusable. The clamp lives in
  // lib/storefront-insights.js now, which the Mac lists reviews through too.
  const set = code('renderer/settings.js');
  assert.match(set, /'★'\.repeat\(rv\.stars\)/, 'the stars are not the clamped ones');
  const SI = require('../lib/storefront-insights.js');
  assert.equal(SI.reviewRows([{ id: 'r', rating: 1e9 }])[0].stars, 5, 'the rating is repeated without being clamped');
  assert.equal(SI.reviewRows([{ id: 'r', rating: -1e9 }])[0].stars, 0);
  assert.equal(SI.reviewRows([{ id: 'r', rating: 'x' }])[0].stars, 0);
});

test('all six strings exist in every locale', () => {
  const dir = path.join(ROOT, 'renderer', 'locales');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  assert.equal(files.length, 9);
  for (const f of files) {
    const src = read(path.join('renderer', 'locales', f));
    for (const k of ['store.reviews_none', 'store.reviews_load_failed', 'store.review_anon',
      'store.review_verified', 'store.review_unverified', 'store.review_delete_q']) {
      assert.ok(src.includes(`"${k}"`), `${f} is missing ${k}`);
    }
  }
});
