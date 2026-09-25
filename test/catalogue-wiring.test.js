/**
 * The wiring, not the logic — four places where a module was built and then not
 * plugged in, which is a whole feature that ships doing nothing.
 *
 * Every one of these was found by re-reading the diff rather than by a failing
 * test, which is why they are pinned here: a pure module with good tests and no
 * caller passes its own suite forever.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('enriching a print file survives a record with no file on disk', () => {
  // The library also holds entries made from a printer's own history, where
  // there is nothing to parse. Reading .ext off null threw from OUTSIDE the try,
  // so enrichment died before the work that needs no file either.
  const src = read('renderer/printfiles.js');
  /* Brace-matched, not a fixed 900-character window from the function start.
   *
   * The window version failed the moment an unrelated comment was added between
   * the guard and the dereference: the dereference slid past 900, `indexOf`
   * returned -1, and `guard < deref` compared a real offset against a miss. The
   * production code was correct throughout — only the slice had moved.
   *
   * Third source-text extractor in this repo to break by measuring rather than
   * matching. Take the function, not a guess at how long it is. */
  const start = src.indexOf('async function enrichPrintFile');
  assert.ok(start > -1, 'enrichPrintFile is gone');
  const open = src.indexOf('{', start);
  let depth = 0, end = -1;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) { end = i + 1; break; }
  }
  assert.ok(end > -1, 'could not find the end of enrichPrintFile');
  const fn = src.slice(start, end);

  const guard = fn.indexOf('!rec.sourceFile');
  const deref = fn.indexOf('rec.sourceFile.ext');
  assert.ok(guard !== -1, 'enrichPrintFile must guard a missing sourceFile');
  assert.ok(deref !== -1, 'the dereference this guards is gone — has the guard stopped guarding anything?');
  assert.ok(guard < deref, 'and the guard has to come BEFORE the dereference');
});

test('the catalog grid says which listings show no real photo', () => {
  // hasRealPhoto existed, was tested, and nothing called it — the label was
  // collected and never used for anything.
  const src = read('renderer/inventory.js');
  assert.match(src, /KhaytProductImages\.hasRealPhoto\(/, 'the grid must actually ask the question');
  assert.match(src, /product-norealphoto/, 'and show the answer');
});

test('the storefront publishes the labelled photos, not just one', () => {
  const src = read('renderer/settings.js');
  // The payload is built in lib/storefront-catalog.js now (the Mac publishes
  // through it too); the dialog's own part is reading the heroes off disk.
  const build = read('lib/storefront-catalog.js');
  const dialog = src.slice(src.indexOf('const buildCatalog = '), src.indexOf('#storeCopy'));
  assert.match(build, /KhaytProductImages\.storefrontPhotos\(p, \{/,
    'the storefront asks the module, so the selection is testable rather than sealed in a modal');
  assert.match(build, /it\.photos = photos/, 'more than one picture reaches the storefront');
  /* The hero has to be OFFERED, or every listing quietly publishes the 240px
   * grid thumbnail as its product-page picture again — which is what it did,
   * and which looks like a working publish. */
  assert.match(build, /hero: \(img\) =>/, 'the publish must offer the full-size picture');
  assert.match(dialog, /await loadHeroPhotos\(pubProducts\)/,
    'and must have read them off disk first');
  const publish = src.slice(src.indexOf("'#storePublish'"), src.indexOf("'#storeUnpublish'"));
  assert.match(publish, /await buildCatalog\(/,
    'buildCatalog reads files now; a missing await publishes a Promise');
  /* `photo` must NOT be sent. It is a view of photos[0], the server derives it
   * from the gallery it stores, and sending it put every listing's primary
   * photo on the wire twice — invisible at 30 KB a thumbnail, half the payload
   * at 200 KB a photograph. */
  assert.equal(/it\.photo\s*=/.test(build), false,
    'the legacy field is derived by the server, not duplicated onto the wire');
  // The budget itself is asserted in catalogue-images-and-parts.test.js, where
  // it can be exercised rather than pattern-matched.
});

test('every lib module the renderer uses is loaded by both entry points', () => {
  // A module that is required but never <script>-loaded is a ReferenceError the
  // moment its first caller runs — the exact shape of the cloud sign-in freeze.
  const idx = read('renderer/index.html');
  const bed = read('renderer/bedready.html');
  for (const mod of ['product-images.js', 'part-from-print-file.js', 'nozzle-wear.js',
    'nozzle-wear-data.js', 'printer-facts.js']) {
    assert.ok(idx.includes(mod), `renderer/index.html must load ${mod}`);
    assert.ok(bed.includes(mod), `renderer/bedready.html must load ${mod}`);
  }
  // Order matters for the two that read each other at load time.
  assert.ok(idx.indexOf('nozzle-wear-data.js') < idx.indexOf('nozzle-wear.js'),
    'the data table must load before the model that reads it');
  assert.ok(idx.indexOf('printer-facts.js') < idx.indexOf('printer-catalog.js'),
    'the facts must load before the catalog that layers them on');
});
