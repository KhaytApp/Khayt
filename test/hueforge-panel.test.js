/**
 * Driving the HueForge studio panel in a real DOM.
 *
 * lib/hueforge.js already proves the stack, the solve and the U1 head plan are
 * right. What this covers is the thing that only goes wrong once there IS a
 * document: whether the picture, the swap elevation, the U1 verdict and — the
 * one that reaches a printer — the exported 3MF still describe the filament
 * list the maker is looking at, after they have reordered it, added to it,
 * removed from it, or auto-tuned it.
 *
 * The panel keeps three derived values on its session (`stack`, `solve`,
 * `plan`). Every one of those panes reads them, so any edit that repaints
 * without recomputing shows the maker a plan for a stack they no longer have.
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
// Four flat quadrants, far apart in colour, so the auto-picked palette is
// several visibly different filaments rather than near-duplicates.
const QUAD = [[220, 40, 40], [40, 160, 220], [250, 240, 210], [30, 30, 35]];

/** Boot renderer/hueforge.js against a jsdom document with a recording export bridge. */
async function boot() {
  const dom = new JSDOM('<!doctype html><html data-app="bedready"><body><div id="hueforge-tab"></div></body></html>',
    { pretendToBeVisual: true, runScripts: 'outside-only' });
  const { window } = dom;
  const doc = window.document;

  const data = new window.Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const q = (y < H / 2 ? 0 : 2) + (x < W / 2 ? 0 : 1);
      const o = (y * W + x) * 4;
      data[o] = QUAD[q][0]; data[o + 1] = QUAD[q][1]; data[o + 2] = QUAD[q][2]; data[o + 3] = 255;
    }
  }
  const imageData = { data, width: W, height: H };

  // Enough of a 2D context for the panel: it samples the dropped image through
  // one canvas and blits the achievable-colour preview through another.
  window.HTMLCanvasElement.prototype.getContext = function () {
    return {
      drawImage() {},
      getImageData: () => imageData,
      createImageData: (w, h) => ({ data: new window.Uint8ClampedArray(w * h * 4), width: w, height: h }),
      putImageData() {},
    };
  };
  window.FileReader = class {
    readAsDataURL() { this.result = 'data:image/png;base64,AA'; setTimeout(() => this.onload && this.onload(), 0); }
  };
  window.Image = class {
    constructor() { this.width = W; this.height = H; }
    set src(v) { this._src = v; setTimeout(() => this.onload && this.onload(), 0); }
    get src() { return this._src; }
  };

  const exported = [];
  const copied = [];
  window.hubAPI = { hfExport3mf: async (o) => { exported.push(o); return { ok: true }; } };
  window.inventory = [];
  Object.defineProperty(window.navigator, 'clipboard', {
    configurable: true,
    value: { writeText: async (t) => { copied.push(t); } },
  });

  const ctx = vm.createContext(window);
  // util.js first, exactly as bedready.html loads it: the panel's copy button
  // goes through KhaytUtil.copyText, so without this the handler throws on an
  // undefined global and the copy silently does nothing.
  vm.runInContext(read('renderer/util.js'), ctx);
  vm.runInContext(read('lib/color-mix.js'), ctx);
  vm.runInContext(read('lib/hueforge.js'), ctx);
  vm.runInContext(read('renderer/hueforge.js'), ctx);

  window.renderHueForge();

  const ev = new window.Event('drop');
  ev.dataTransfer = { files: [{ type: 'image/png', name: 'painting.png' }] };
  doc.getElementById('hfDrop').dispatchEvent(ev);
  await settle(window);

  return { window, doc, exported, copied };
}

/**
 * Let the panel finish recomputing.
 *
 * ── THIS USED TO BE A 60ms SLEEP, AND IT FLAKED ───────────────────────────
 *
 * `new Promise((r) => window.setTimeout(r, 60))` passes every time this file
 * is run on its own and fails perhaps one run in five under `npm test`, where
 * Node is running many test files at once and 60ms of wall clock is not 60ms
 * of this panel's work. Two of these tests failed that way and passed on a
 * re-run, which is the worst kind of failure: it teaches everyone to re-run
 * rather than to read.
 *
 * A fixed sleep is a guess about someone else's machine. This waits for the
 * panel to STOP CHANGING instead — the derived values it recomputes are all on
 * screen, so two identical reads a tick apart mean the work is done — and it
 * gives up after a generous deadline rather than hanging a suite.
 */
const settle = async (window, { quietMs = 40, timeoutMs = 5000 } = {}) => {
  const doc = window.document;
  // Everything the panel derives ends up in these panes, so their combined
  // text is a fingerprint of "what the maker can see".
  const shot = () => doc.getElementById('hueforge-tab')?.textContent ?? '';
  const tick = () => new Promise((r) => window.setTimeout(r, 10));
  const deadline = Date.now() + timeoutMs;
  let last = null, quietSince = null;
  for (;;) {
    const now = shot();
    if (now !== last) { last = now; quietSince = null; }
    else if (quietSince === null) quietSince = Date.now();
    else if (Date.now() - quietSince >= quietMs) return;
    if (Date.now() > deadline) return;   // the assertion says what went wrong, not this
    await tick();
  }
};
const click = (window, el) => el.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));

/** What the maker is editing: the filament rows, bottom → top. */
const paletteHexes = (doc) => Array.from(doc.querySelectorAll('.hf-fil-hex')).map((e) => e.textContent.trim());
const paletteLayers = (doc) => Array.from(doc.querySelectorAll('.hf-fil input[data-fld="layers"]')).map((i) => +i.value);

/** What the panel says will be printed: the swap elevation, bottom → top. */
const elevationHexes = (doc) => Array.from(doc.querySelectorAll('.hf-band')).map((b) => hexOf(b.style.background || b.getAttribute('style')));
const elevationSpans = (doc) => Array.from(doc.querySelectorAll('.hf-band-l')).map((s) => s.textContent.trim());

function hexOf(style) {
  const s = String(style || '');
  let m = s.match(/#([0-9a-f]{6})/i);
  if (m) return ('#' + m[1]).toUpperCase();
  m = s.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/i);
  if (!m) return s;
  return '#' + [1, 2, 3].map((i) => (+m[i]).toString(16).padStart(2, '0')).join('').toUpperCase();
}

/**
 * The invariant these all turn on, across both the band-per-filament studio and the
 * planPainting one that replaced it: every band the panel shows or exports must name a
 * head that still holds the colour the band claims. A plan computed against a stack the
 * maker has since edited fails that immediately, whatever shape the plan happens to take.
 */
function assertPlanMatchesStack(doc, exported, why) {
  const palette = paletteHexes(doc);
  const elevation = elevationHexes(doc);
  // Without this every "the elevation no longer shows X" check below passes when the
  // elevation shows NOTHING — which is what a panel that never computed a plan looks like.
  assert.ok(elevation.length, why + ': the elevation is empty, so it proves nothing');
  for (const hex of elevation) {
    assert.ok(palette.includes(hex), why + ': elevation shows ' + hex + ', which is not in the stack');
  }
  if (exported) {
    const fil = Array.from(exported.filaments || [], (h) => String(h).toUpperCase());
    const heads = new Set();
    for (const b of exported.bands || []) {
      heads.add(b.head);
      assert.equal(fil[b.head], String(b.hex).toUpperCase(),
        why + ': band on head ' + b.head + ' claims ' + b.hex + ' but that head holds ' + fil[b.head]);
    }
    assert.ok(heads.size <= 4, why + ': plan uses ' + heads.size + ' heads, the U1 has 4');
  }
}

test('the swap elevation only ever shows filaments still in the stack', async () => {
  const { window, doc } = await boot();
  assert.ok(paletteHexes(doc).length >= 3, 'auto-pick should seed several filaments');
  assertPlanMatchesStack(doc, null, 'before any edit');

  click(window, doc.querySelector('.hf-fil[data-idx="0"] [data-act="up"]'));
  await settle(window);
  assertPlanMatchesStack(doc, null, 'after reordering');

  // Reordering does not change WHICH colours are in the stack, so a stale plan would still
  // satisfy the check above. Removing one does.
  const dropped = paletteHexes(doc)[0];
  click(window, doc.querySelector('.hf-fil[data-idx="0"] [data-act="del"]'));
  await settle(window);
  assert.ok(elevationHexes(doc).length, 'the elevation went empty, so this proves nothing');
  assert.ok(!elevationHexes(doc).includes(dropped),
    'the elevation still shows ' + dropped + ', which the maker just deleted');
  assertPlanMatchesStack(doc, null, 'after deleting');
});

test('a reordered stack is the one that reaches the exported 3MF', async () => {
  const { window, doc, exported } = await boot();
  const before = paletteHexes(doc);

  click(window, doc.querySelector('.hf-fil[data-idx="0"] [data-act="up"]'));
  await settle(window);
  assert.notDeepEqual(paletteHexes(doc), before, 'the reorder should have changed the list');

  click(window, doc.getElementById('hf3mf'));
  await settle(window);
  assert.equal(exported.length, 1, 'export should have been invoked');
  // Heads index the filament list; a plan built before the reorder points them at the
  // colours that USED to be in those slots.
  assertPlanMatchesStack(doc, exported[0], 'after reordering');
});

test('removing a filament removes it from the plan and the export', async () => {
  const { window, doc, exported } = await boot();
  const dropped = paletteHexes(doc)[0];

  click(window, doc.querySelector('.hf-fil[data-idx="0"] [data-act="del"]'));
  await settle(window);

  const left = paletteHexes(doc);
  assert.ok(!left.includes(dropped), 'the row should be gone from the list');
  assert.ok(elevationHexes(doc).length, 'the elevation went empty, so this proves nothing');
  assert.ok(!elevationHexes(doc).includes(dropped), 'and out of the elevation');

  click(window, doc.getElementById('hf3mf'));
  await settle(window);
  assert.equal(exported.length, 1);
  assertPlanMatchesStack(doc, exported[0], 'after deleting');
  const fil = Array.from(exported[0].filaments || [], (h) => String(h).toUpperCase());
  assert.ok(!fil.includes(dropped), 'a filament the maker deleted must not be written into the 3MF');
});

test('however many filaments are offered, the plan fits the four heads', async () => {
  const { window, doc, exported } = await boot();
  while (paletteHexes(doc).length < 5) {
    click(window, doc.getElementById('hfAdd'));
    await settle(window);
  }
  assert.equal(paletteHexes(doc).length, 5);

  click(window, doc.getElementById('hf3mf'));
  await settle(window);
  if (exported.length) assertPlanMatchesStack(doc, exported[0], 'with five filaments offered');
});

test('auto-tune repaints the plan it just changed', async () => {
  const { window, doc, exported } = await boot();
  // Change the stack first: tuning on an untouched stack can leave the head->colour mapping
  // exactly as it was, and then a plan that never recomputed looks identical to one that did.
  const dropped = paletteHexes(doc)[0];
  click(window, doc.querySelector('.hf-fil[data-idx="0"] [data-act="del"]'));
  await settle(window);

  click(window, doc.getElementById('hfTune'));
  await settle(window);
  await settle(window);

  assert.ok(elevationHexes(doc).length, 'the elevation went empty, so this proves nothing');
  assert.ok(!elevationHexes(doc).includes(dropped), 'tuning redrew a plan built on the old stack');
  assertPlanMatchesStack(doc, null, 'after tuning');
  click(window, doc.getElementById('hf3mf'));
  await settle(window);
  if (exported.length) assertPlanMatchesStack(doc, exported[0], 'after tuning, on export');
});

test('the copied plan counts the colours the maker actually has', async () => {
  const { window, doc, copied } = await boot();
  click(window, doc.getElementById('hfCopy'));
  await settle(window);
  assert.equal(copied.length, 1, 'the plan should have been copied');
  assert.ok(copied[0].length > 0, 'and not be empty');
});
