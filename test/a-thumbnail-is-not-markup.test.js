'use strict';
/**
 * A downloaded G-code file could put working markup on a print-file card.
 *
 * The chain, every link of which is ordinary use of the app:
 *
 *   1. lib/thumbnail-extract.js pulls the embedded preview out of a .gcode and
 *      strips only `;` and whitespace — leaving " < > / = and never checking
 *      that what remains is base64 at all.
 *   2. printfiles.js concatenates it onto `data:image/png;base64,` and hands it
 *      to resizeDataUrl, whose `img.onerror` resolves the ORIGINAL string when
 *      the payload will not decode.
 *   3. The strict main-process thumbnail writer rejects it, which drives the
 *      fallback that stores it on the record — so it persists, is redrawn on
 *      every visit, and travels with the cloud-sync snapshot.
 *   4. safeImageSrc tested only the PREFIX and returned the value verbatim,
 *      unlike its http and file branches which escape.
 *
 * `<img class="pf-thumb" src="${safeImageSrc(src)}">` then gains whatever
 * attributes the payload chose — and the grid delegates on
 * `closest('[data-act]')`, so an ordinary click on the largest target on the
 * card runs a real action.
 *
 * The app's CSP (`script-src 'self'`, no unsafe-inline) means this is not code
 * execution. It is click-hijacking and UI spoofing, which is quite enough.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const { extractGcodeThumbnail } = require('../lib/thumbnail-extract.js');

function safeImageSrc() {
  const ctx = vm.createContext({ globalThis: {}, console });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, 'renderer/util.js'), 'utf8'), ctx);
  return (ctx.globalThis.KhaytUtil || ctx.globalThis).safeImageSrc || ctx.safeImageSrc;
}

test('a data URL is validated whole, not by its first twenty characters', () => {
  const f = safeImageSrc();
  const BREAKOUT = 'data:image/png;base64,iVBORw0KGgo="/data-act="pf-del"/data-id="X';
  assert.equal(f(BREAKOUT), '',
    'a string that merely STARTS like a data URL is written into src="…" verbatim');
  assert.equal(f('data:image/png;base64,abc<style>.modal-footer{opacity:0}</style>'), '',
    'markup in the payload survives into the attribute');
  // Not a picture format we render, so not a picture.
  assert.equal(f('data:image/svg+xml;base64,PHN2Zz4='), '');
});

test('a real preview still renders', () => {
  const f = safeImageSrc();
  const REAL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
  assert.equal(f(REAL), REAL, 'a valid preview was refused — the grid would show no pictures');
  assert.equal(f('data:image/jpeg;base64,/9j/4AAQ=='), 'data:image/jpeg;base64,/9j/4AAQ==');
  assert.equal(f('data:image/png;base64,'), 'data:image/png;base64,', 'an empty payload is well-formed, if useless');
});

test('the extractor refuses a payload that is not base64', () => {
  /* Rejected at the source as well as at the sink: a value that is not base64
   * is not a picture and should never reach a record, let alone the sync. */
  const gcode = [
    '; thumbnail begin 16x16 100',
    '; iVBORw0KGgo="/data-act="pf-del"/data-id="X',
    '; thumbnail end',
  ].join('\n');
  // The "nothing here" shape is `{pngBase64: null, width: 0, height: 0}`, not
  // null — the function is deliberately total so a weird file cannot crash the
  // parse. My first assertion compared against null and failed on the shape
  // rather than the behaviour.
  assert.equal(extractGcodeThumbnail(gcode).pngBase64, null,
    'a crafted preview is still extracted and stored');

  const good = [
    '; thumbnail begin 1x1 68',
    '; iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    '; thumbnail end',
  ].join('\n');
  const ok = extractGcodeThumbnail(good);
  assert.ok(ok && ok.pngBase64, 'a genuine embedded preview is no longer extracted');
});

test('the two other branches still escape, as they always did', () => {
  const f = safeImageSrc();
  assert.equal(f('https://x/a"onerror="y'), 'https://x/a&quot;onerror=&quot;y');
  assert.equal(f('javascript:alert(1)'), '');
  assert.equal(f(''), '');
  assert.equal(f(null), '');
});
