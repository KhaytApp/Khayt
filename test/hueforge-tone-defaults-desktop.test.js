'use strict';
/**
 * The desktop HueForge studio's starting values (Turki's OK, Nov 2026): 3.2 mm,
 * vividness 8 and lightness-first matching (chromaWeight 0.5) in colour,
 * vividness 6 and plain matching (1) in black and white. The numbers and the
 * neutral rule are lib/hueforge.js's (`TONE_DEFAULTS`, `isNeutralPalette`);
 * this pins that the studio reads them, passes them to planPainting, leaves a
 * vividness the maker chose alone — and changes nothing on an engine without
 * them. The stand-ins below are what lib/hueforge.js exports from #2267; once
 * it does, `stubTones: false` runs the real ones.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const W = 8, H = 8;

async function boot(pixels, { tones = true } = {}) {
  const dom = new JSDOM('<!doctype html><html data-app="bedready"><body><div id="hueforge-tab"></div></body></html>',
    { pretendToBeVisual: true, runScripts: 'outside-only' });
  const { window } = dom;
  const data = new window.Uint8ClampedArray(W * H * 4);
  for (let i = 0; i < W * H; i++) { const c = pixels[i % pixels.length]; data.set([c[0], c[1], c[2], 255], i * 4); }
  const imageData = { data, width: W, height: H };
  window.HTMLCanvasElement.prototype.getContext = function () {
    return { drawImage() {}, getImageData: () => imageData,
      createImageData: (w, h) => ({ data: new window.Uint8ClampedArray(w * h * 4), width: w, height: h }), putImageData() {} };
  };
  window.FileReader = class { readAsDataURL() { this.result = 'data:image/png;base64,AA'; setTimeout(() => this.onload && this.onload(), 0); } };
  window.Image = class { constructor() { this.width = W; this.height = H; } set src(v) { this._src = v; setTimeout(() => this.onload && this.onload(), 0); } get src() { return this._src; } };
  window.hubAPI = {};
  window.inventory = [];
  const ctx = vm.createContext(window);
  vm.runInContext(read('renderer/util.js'), ctx);
  vm.runInContext(read('lib/color-mix.js'), ctx);
  vm.runInContext(read('lib/hueforge.js'), ctx);
  const hf = window.KhaytHueForge;
  if (tones && !hf.TONE_DEFAULTS) {
    hf.TONE_DEFAULTS = { colour: { heightMm: 3.2, vivid: 8, chromaWeight: 0.5 }, bw: { heightMm: 3.2, vivid: 6, chromaWeight: 1 } };
    hf.isNeutralPalette = (hexes, max = 6) => hexes.length > 0 && hexes.every((h) => {
      const l = window.KhaytColor.hexToLab(h); return !!l && Math.hypot(l.a, l.b) <= max;
    });
  }
  if (!tones) { delete hf.TONE_DEFAULTS; delete hf.isNeutralPalette; }
  const calls = [];
  const real = hf.planPainting;
  hf.planPainting = (img, fils, opts) => { calls.push({ hexes: fils.map((f) => f.hex), opts }); return real(img, fils, opts); };
  vm.runInContext(read('renderer/hueforge.js'), ctx);
  window.renderHueForge();
  const ev = new window.Event('drop');
  ev.dataTransfer = { files: [{ type: 'image/png', name: 'p.png' }] };
  window.document.getElementById('hfDrop').dispatchEvent(ev);
  for (let i = 0; i < 100 && !calls.length; i++) await new Promise((r) => setTimeout(r, 20));
  return { window, doc: window.document, calls, hf };
}
const last = (calls) => calls[calls.length - 1];

const COLOUR = [[220, 40, 40], [40, 160, 220], [250, 240, 210], [30, 30, 35]];
const GREYS = [[20, 20, 20], [90, 90, 90], [170, 170, 170], [245, 245, 245]];

test('a colour picture starts at 3.2 mm, vividness 8, and matches lightness first', async () => {
  const { doc, calls, hf } = await boot(COLOUR);
  const c = last(calls);
  assert.ok(c, 'the studio planned');
  assert.equal(hf.isNeutralPalette(c.hexes), false, `a colour palette (${c.hexes})`);
  assert.equal(c.opts.heightMm, 3.2);
  assert.ok(Math.abs(c.opts.tdScale - 0.3) < 1e-9, `vividness 8 → TD scale 0.3 (${c.opts.tdScale})`);
  assert.equal(c.opts.chromaWeight, 0.5);
  assert.equal(doc.getElementById('hfVivid').value, '8', 'and the field says so');
  assert.equal(doc.getElementById('hfHeight').value, '3.2');
});

test('neutral filaments plan for black and white: vividness 6, plain matching', async () => {
  const { calls, hf } = await boot(GREYS);
  const c = last(calls);
  assert.ok(c, 'the studio planned');
  assert.ok(hf.isNeutralPalette(c.hexes), `a grey picture picks neutrals (${c.hexes})`);
  assert.ok(Math.abs(c.opts.tdScale - 0.5) < 1e-9, `vividness 6 → TD scale 0.5 (${c.opts.tdScale})`);
  assert.equal(c.opts.chromaWeight, 1);
});

test('a vividness the maker chose stays', async () => {
  const { window, doc, calls } = await boot(COLOUR);
  const v = doc.getElementById('hfVivid');
  v.value = '4';
  v.dispatchEvent(new window.Event('input', { bubbles: true }));
  for (let i = 0; i < 50; i++) await new Promise((r) => setTimeout(r, 20));
  const c = last(calls);
  assert.ok(Math.abs(c.opts.tdScale - 0.7) < 1e-9, `vividness 4 → 0.7 (${c.opts.tdScale})`);
  assert.equal(c.opts.chromaWeight, 0.5, 'the matching still follows the filaments');
});

test('an engine without TONE_DEFAULTS keeps the old studio exactly', async () => {
  const { calls } = await boot(COLOUR, { tones: false });
  const c = last(calls);
  assert.equal(c.opts.heightMm, 2.4);
  assert.ok(Math.abs(c.opts.tdScale - 0.2) < 1e-9, `vividness 9 → 0.2 (${c.opts.tdScale})`);
  assert.equal(c.opts.chromaWeight, 1);
});
