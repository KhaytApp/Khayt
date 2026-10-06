'use strict';
/**
 * A preview that cannot be read is not a preview that is gone.
 *
 * rebuildThumb used to delete rec.thumbFile and save the book whether or not it made a new
 * picture. With the library folder or NAS offline for a moment, every visible card lost its
 * thumbFile for good, and the thumb.jpg that came back with the share was never linked again.
 * Runs the real warmThumbs/rebuildThumb from renderer/printfiles.js in a vm.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const pf = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'printfiles.js'), 'utf8');
const warm = pf.slice(pf.indexOf('async function warmThumbs'), pf.indexOf('function thumbHtml'));
const resolve = pf.slice(pf.indexOf('async function resolveModelPath'), pf.indexOf('async function view3d'));

function harness(hub, setThumb) {
  const rec = { id: 'PF1', thumbFile: 'thumb.jpg', sourceFile: { filename: 'a.3mf', ext: '3mf' } };
  const ctx = {
    printFiles: [rec], _view: 'grid', _thumbCache: new Map(), cacheThumb() {}, CSS: { escape: (s) => s },
    document: { querySelector: () => null }, MODEL_EXT: /\.(3mf|stl)$/i, saves: 0,
    api: () => hub, renderPrintFiles() {}, safeImageSrc: (s) => s,
    resizeDataUrl: async (u) => u, setThumb,
  };
  ctx.saveAll = () => { ctx.saves++; };
  vm.createContext(ctx);
  vm.runInContext(resolve + warm + '; this.warmThumbs = warmThumbs;', ctx);
  return { rec, ctx };
}
const settle = () => new Promise((r) => setTimeout(r, 30));

test('a library that is offline keeps every thumbFile and saves nothing', async () => {
  const { rec, ctx } = harness({ printLibLoadThumbs: async () => ({}), printLibList: async () => [], extractThumbnail: async () => null },
    async () => false);
  await ctx.warmThumbs([rec]);
  await settle();
  assert.equal(rec.thumbFile, 'thumb.jpg');
  assert.equal(ctx.saves, 0);
});

test('a preview made again from the model is saved', async () => {
  const { rec, ctx } = harness({
    printLibLoadThumbs: async () => ({}), printLibList: async () => [{ filename: 'a.3mf', fullPath: '/lib/a.3mf' }],
    extractThumbnail: async () => ({ pngBase64: 'AAAA' }),
  }, async (r) => { r.thumbFile = 'thumb-2.jpg'; return true; });
  await ctx.warmThumbs([rec]);
  await settle();
  assert.equal(rec.thumbFile, 'thumb-2.jpg');
  assert.equal(ctx.saves, 1);
});
