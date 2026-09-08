/**
 * What the app publishes, and what the storefront page actually reads.
 *
 * These are two repositories and nothing connected them, so a field could be
 * added to the payload, tested, shipped — and ignored by the page that receives
 * it. That is exactly what happened: the catalogue publish gained `photos` (up
 * to three, each labelled) and `alt` (the shop's second language), and
 * mobile/storefront.js read `it.photo`, `it.desc` and `it.nameAr` and nothing
 * else. A German-and-French shop published a catalogue whose own customers
 * could only read half of it, because the page's language was hard-coded:
 *
 *     const lang = (… === 'ar') ? 'ar' : 'en';
 *
 * Found by asking what the three verification passes structurally could not
 * see — all three ran inside the app.
 *
 * The storefront lives in khayt-cloud, which is a separate repo checked out at
 * khayt-cloud/ and gitignored, so it is absent in CI. The contract is pinned
 * here and cross-checked there when the repo is present.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SETTINGS = fs.readFileSync(path.join(ROOT, 'renderer', 'settings.js'), 'utf8');
const STOREFRONT = path.join(ROOT, 'khayt-cloud', 'mobile', 'storefront.js');

/** Fields the publish payload carries that the page has to understand. */
const CONTRACT = {
  'catalog.langs': /langs:\s*KhaytContentLanguages\.contentLangs/,
  'item.photos': /it\.photos = photos/,
  'item.alt': /it\.alt = \{ lang:/,
  'item.nameAr': /nameAr: \(p\.nameAr \|\| ''\)/,   // kept for older pages
  'item.stockQty': /it\.stockQty = sf\.stockQty\[p\.id\]/,
};

test('the publish payload still carries every field the storefront needs', () => {
  const build = SETTINGS.slice(SETTINGS.indexOf('const buildCatalog = '), SETTINGS.indexOf('#storeCopy'));
  for (const [field, re] of Object.entries(CONTRACT)) {
    assert.match(build, re, `the catalogue publish must send ${field}`);
  }
});

test('`photo` still exists for older pages, derived rather than duplicated', () => {
  /* It used to be sent, which put every listing's primary photo on the wire
   * TWICE — invisible at 30 KB a thumbnail, half the payload at 200 KB a
   * photograph. The server derives it from the gallery it stores instead, so
   * the field a page falls back on is still there and cannot disagree with
   * photos[0]. See khayt-cloud's sanitizeCatalog.
   *
   * The page-side half of this contract is asserted below: storefront.js reads
   * `photos` first and `photo` only as a fallback, so a stored catalogue with
   * both keeps rendering either way. */
  const build = SETTINGS.slice(SETTINGS.indexOf('const buildCatalog = '), SETTINGS.indexOf('#storeCopy'));
  assert.equal(/it\.photo\s*=/.test(build), false, 'the app must not send the duplicate');

  const php = path.join(ROOT, 'khayt-cloud', 'index.php');
  if (!fs.existsSync(php)) return;   // separate repo, absent in CI
  const src = fs.readFileSync(php, 'utf8');
  assert.match(src, /\$o\['photo'\] = \$photos\[0\]\['src'\]/,
    'the server must derive it, or an older page loses its only picture');
});

test('a published item is priced from the catalogue, not from a second form', () => {
  /* The publish read `sf.prices[p.id]` and nothing else, so a shop that had
   * already priced every product — cost, margin, rounding, the lot — published a
   * storefront where everything cost nothing, and had to type it all again into
   * a different form. The product feeds other platforms import are built from
   * this same payload, so they inherited the blank.
   *
   * Reported as: "the price should be from the catalogue, I just want to sync
   * the catalogue, I don't want to enter the info again."
   */
  const build = SETTINGS.slice(SETTINGS.indexOf('const buildCatalog = '), SETTINGS.indexOf('#storeCopy'));
  assert.match(build, /p\.price != null \? p\.price : p\.basePrice/,
    'the catalogue price is the default; a storefront entry is only an override');
  // `!= null`, never a truthy test: 0 is a price. A giveaway or a sample priced
  // at nothing is a decision, and a truthy check silently replaces it.
  assert.doesNotMatch(build, /if \(sf\.prices\[p\.id\]\) it\.price/,
    'a truthy check would treat a deliberate zero as unpriced');
});

test('the stock box the dialog draws is the one the save reads', () => {
  /* The cheapest way for this feature to do nothing at all.
   *
   * The row markup and the capture are ~130 lines apart and joined only by a
   * class name. Rename one and the input still renders, the shop still types a
   * number, Save still succeeds — and querySelectorAll finds nothing, so the
   * count is silently never published. No error, no test failure, and the shop
   * discovers it when a customer is quoted a print lead time on something in a
   * box.
   *
   * No Electron here, so this cannot click the field; it can at least insist
   * the two halves still name the same thing.
   */
  assert.match(SETTINGS, /<input class="sfStock"/, 'the dialog must draw the box');
  assert.match(SETTINGS, /querySelectorAll\('\.sfStock'\)/, 'and the save must read it');

  // The dirty flag is likewise a name shared across the two, and it decides
  // whether a count is re-dated at all.
  assert.match(SETTINGS, /inp\.dataset\.counted = '1'/, 'touching the box must mark it');
  assert.match(SETTINGS, /inp\.dataset\.counted === '1'/, 'and the save must read that mark');
});

test('a batch count of zero survives every hop, because zero is a state', () => {
  /* The one number in this payload where 0 is meaningful and every neighbour's
   * 0 is not.
   *
   * printHours and weightGrams are dropped when zero — nothing prints instantly
   * or weighs nothing, so a zero there is a parse failure wearing a number. A
   * stock count of zero is a shop saying the batch sold out, which it reverses
   * next week. Read as "absent" it becomes "we do not stock this", and the
   * storefront quotes a print lead time on a piece about to be restocked.
   *
   * Three places can each swallow it independently, which is why all three are
   * pinned here rather than trusted to review: the app's publish, the server's
   * whitelist, and the feed the storefront actually reads.
   */
  const build = SETTINGS.slice(SETTINGS.indexOf('const buildCatalog = '), SETTINGS.indexOf('#storeCopy'));
  assert.match(build, /sf\.stockQty\[p\.id\] != null/,
    'a truthy check would publish a sold-out batch as made to order');

  const php = path.join(ROOT, 'khayt-cloud', 'index.php');
  if (!fs.existsSync(php)) return;   // separate repo, absent in CI
  const src = fs.readFileSync(php, 'utf8');

  // The whitelist must admit 0 — `>= 0`, not the `> 0` its neighbours use.
  assert.match(src, /\$o\['stockQty'\] = \(int\) min/,
    'the server whitelist must know the field, or it is dropped in silence');
  assert.match(src, /\(float\) \$sq >= 0/,
    'the whitelist must admit zero — a sold-out batch is a state, not a gap');

  // And the feed must emit it. isset() is false for null and TRUE for 0.
  assert.match(src, /isset\(\$it\['stockQty'\]\)\) \$products\[\$last\]\['stock_quantity'\]/,
    'the feed must carry the count, and !empty() would drop a zero');
});

test('the count and the moment it was taken travel together', () => {
  /* stockCountedAt is what lets a storefront re-apply a count over what it has
   * sold since — it applies the number when the shop COUNTED, not when it
   * happened to read. So the app must date a count the shop touched, and must
   * NOT re-date one it did not: opening this dialog to edit a price would
   * otherwise re-assert every count and undo the sales in between.
   */
  const build = SETTINGS.slice(SETTINGS.indexOf('const buildCatalog = '), SETTINGS.indexOf('#storeCopy'));
  assert.match(build, /it\.stockCountedAt = sf\.stockCountedAt\[p\.id\]/,
    'a count with no date cannot be told from one the shop never re-took');

  // Touched, not merely changed: a shop that sells three, prints three and
  // counts twenty again types the same figure, and that IS a re-count.
  assert.match(SETTINGS, /inp\.dataset\.counted = '1'/,
    'touching the box is the signal — a value comparison misses a re-count onto the same number');

  const php = path.join(ROOT, 'khayt-cloud', 'index.php');
  if (!fs.existsSync(php)) return;
  const src = fs.readFileSync(php, 'utf8');
  assert.match(src, /\$o\['stockCountedAt'\] = \$sc/,
    'the server must keep the date, or the consumer can never tell a re-count from a re-read');
});

test('the storefront page reads them, where the cloud repo is checked out', {
  skip: fs.existsSync(STOREFRONT) ? false : 'khayt-cloud is a separate repo and is not present',
}, () => {
  const page = fs.readFileSync(STOREFRONT, 'utf8');
  for (const [field, marker] of [
    ['catalog.langs', /catalog && catalog\.langs/],
    ['item.photos', /it\.photos/],
    ['item.alt', /it\.alt/],
  ]) {
    assert.match(page, marker, `storefront.js must read ${field} — the app sends it`);
  }
  /* And the display language must not be hard-coded to two.
   *
   * `lang === 'ar' ? … : 'en'` is what made a German-and-French catalogue
   * unreadable: the page chose between a field that was German and one that
   * was empty.
   */
  assert.doesNotMatch(page, /const lang = \(\(qLang.*'ar'\) \? 'ar' : 'en'\);/,
    'the storefront language must come from the catalogue, not from a two-way guess');
  assert.match(page, /function pickLang\(\)/, 'it picks from the languages the catalogue declares');

  /* And the picking must happen AFTER the catalogue has arrived.
   *
   * This is not hypothetical tidiness — it is the bug this test was written
   * one revision too late to prevent. `applyStatic()` (which calls pickLang)
   * ran as the FIRST line of load(), six lines before `catalog = data.catalog`.
   * So it settled the language against a null catalogue, fell back to
   * en-or-ar, and the whole feature was inert while reading as correct.
   *
   * The page needs an early pass too, for the loading and not-found states
   * that never see a catalogue — so this asserts the SECOND one exists rather
   * than that the first does not.
   */
  const load = page.slice(page.indexOf('async function load()'));
  const assign = load.indexOf('catalog = data.catalog');
  assert.ok(assign > -1, 'load() must still be where the catalogue is assigned');
  assert.ok(load.indexOf('applyStatic()', assign) > -1,
    'the display language must be settled again after the catalogue loads, or it is picked from nothing');
  // Older catalogues, published before any of this, must still render.
  assert.match(page, /it\.photo \?/, 'a catalogue with a single unlabelled photo still shows it');
  assert.match(page, /it\.nameAr/, 'and one with only nameAr still shows an Arabic name');
});
