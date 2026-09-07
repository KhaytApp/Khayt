/**
 * Flat mode, driven through the studio the way a maker drives it.
 *
 * The library halves are covered elsewhere: hueforge-flat.js turns an image into parts, and
 * buildFlatU1_3mf turns parts into a file. What only breaks once they are wired together is
 * the join — whether the panel computes a flat plan at all when the mode is switched, whether
 * it stops showing the relief's, and whether the payload it hands the main process is the one
 * that process knows how to read.
 *
 * The last of those is the point of the final test: it takes the object the renderer actually
 * sent over IPC and runs it through the same calls main.js makes. A renamed field or a typed
 * array that does not survive the trip fails there and nowhere else.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const FLAT = require('../lib/hueforge-flat.js');
const M3 = require('../lib/hueforge-3mf.js');
const { openZip } = require('../lib/zip-read.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

const W = 48, H = 48;
const QUAD = [[220, 40, 40], [40, 160, 220], [250, 240, 210], [30, 30, 35]];

async function boot() {
  const dom = new JSDOM('<!doctype html><html data-app="bedready"><body><div id="hueforge-tab"></div></body></html>',
    { pretendToBeVisual: true, runScripts: 'outside-only' });
  const { window } = dom;
  const doc = window.document;

  const data = new window.Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const c = QUAD[(y < H / 2 ? 0 : 2) + (x < W / 2 ? 0 : 1)];
      const o = (y * W + x) * 4;
      data[o] = c[0]; data[o + 1] = c[1]; data[o + 2] = c[2]; data[o + 3] = 255;
    }
  }
  const imageData = { data, width: W, height: H };

  window.HTMLCanvasElement.prototype.getContext = function () {
    return {
      drawImage() {},
      getImageData: () => imageData,
      createImageData: (w, h) => ({ data: new window.Uint8ClampedArray(w * h * 4), width: w, height: h }),
      putImageData() {},
    };
  };
  window.HTMLCanvasElement.prototype.toDataURL = () => 'data:image/png;base64,AA';
  window.FileReader = class {
    readAsDataURL() { this.result = 'data:image/png;base64,AA'; setTimeout(() => this.onload && this.onload(), 0); }
  };
  window.Image = class {
    constructor() { this.width = W; this.height = H; }
    set src(v) { this._src = v; setTimeout(() => this.onload && this.onload(), 0); }
    get src() { return this._src; }
  };

  const relief = [], flat = [];
  window.hubAPI = {
    hfExport3mf: async (o) => { relief.push(o); return { ok: true }; },
    hfExportFlat3mf: async (o) => { flat.push(o); return { ok: true }; },
  };
  window.inventory = [];

  const ctx = vm.createContext(window);
  vm.runInContext(read('lib/color-mix.js'), ctx);
  vm.runInContext(read('lib/hueforge.js'), ctx);
  vm.runInContext(read('lib/hueforge-flat.js'), ctx);
  vm.runInContext(read('renderer/hueforge.js'), ctx);

  window.renderHueForge();
  const ev = new window.Event('drop');
  ev.dataTransfer = { files: [{ type: 'image/png', name: 'poster.png' }] };
  doc.getElementById('hfDrop').dispatchEvent(ev);
  await settle(window, () => doc.getElementById('hfMode'));
  return { window, doc, relief, flat };
}

/**
 * Wait for the thing, not for eighty milliseconds.
 *
 * This was a fixed 80 ms sleep followed by an assertion, which is a race the
 * machine loses when it is busy: four of these failed together during a run
 * that had a Swift build going beside it, and passed on every quiet run before
 * and since. A suite that goes green when the machine is idle teaches people to
 * run it again rather than to read it.
 *
 * Resolves rather than throws when the deadline passes, so the test's own
 * assertion reports what was actually missing instead of a timeout.
 */
const settle = (window, until, ms = 4000) => new Promise((resolve) => {
  const deadline = Date.now() + ms;
  const tick = () => {
    let done = false;
    try { done = until ? !!until() : true; } catch (_) { done = false; }
    if (done || Date.now() >= deadline) return resolve();
    window.setTimeout(tick, 10);
  };
  window.setTimeout(tick, 0);
});
const click = (window, el) => el.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));

async function toFlat(window, doc) {
  const sel = doc.getElementById('hfMode');
  assert.ok(sel, 'the studio should offer a mode selector');
  sel.value = 'flat';
  sel.dispatchEvent(new window.Event('change', { bubbles: true }));
  await settle(window, () => doc.getElementById('hfVerdict')?.textContent.length);
}

const partHeads = (doc) => Array.from(doc.querySelectorAll('.hf-band-slot')).map((e) => +e.textContent.replace(/[^0-9]/g, ''));

test('the studio offers flat mode, and switching to it builds a flat plan', async () => {
  const { window, doc } = await boot();
  assert.ok(doc.querySelector('.hf-band'), 'relief mode should have drawn something first');

  await toFlat(window, doc);
  const heads = partHeads(doc);
  assert.ok(heads.length >= 2, 'a flat plate is a base slab plus at least one colour region');
  for (const h of heads) assert.ok(h >= 0 && h <= 3, 'head ' + h + ' is not one of the U1\'s four');
});

test('switching modes does not leave the other mode\'s plan on screen', async () => {
  const { window, doc } = await boot();
  await toFlat(window, doc);
  // The relief's verdict talks about swaps and reloads; the flat one cannot.
  const flatText = doc.getElementById('hfVerdict').textContent;
  assert.match(flatText, /free tool change/i, 'flat mode should state its own case');
  assert.doesNotMatch(flatText, /RELOAD/i, 'a flat plate never needs a mid-print reload');

  const sel = doc.getElementById('hfMode');
  sel.value = 'relief';
  sel.dispatchEvent(new window.Event('change', { bubbles: true }));
  await settle(window, () => doc.getElementById('hfVerdict')?.textContent.length);
  assert.ok(doc.getElementById('hfVerdict').textContent.length, 'relief mode should come back');
  assert.doesNotMatch(doc.getElementById('hfVerdict').textContent, /free tool change/i,
    'the flat verdict is still on screen after leaving flat mode');
});

test('exporting in flat mode calls the flat bridge, not the relief one', async () => {
  const { window, doc, relief, flat } = await boot();
  await toFlat(window, doc);

  click(window, doc.getElementById('hf3mf'));
  await settle(window, () => flat.length || relief.length);

  assert.equal(flat.length, 1, 'the flat export should have been invoked');
  assert.equal(relief.length, 0, 'the relief export must not fire for a flat plate');
  const sent = flat[0];
  assert.ok(Array.isArray(sent.labels) && sent.labels.length === sent.width * sent.height,
    'the label field must arrive whole');
  assert.ok(Array.isArray(sent.palette) && sent.palette.length, 'and the palette with it');
  assert.ok(!('parts' in sent), 'geometry should be rebuilt in main, not shipped over IPC');
});

test('what the panel sends is what the main process can build', async () => {
  const { window, doc, flat } = await boot();
  await toFlat(window, doc);
  click(window, doc.getElementById('hf3mf'));
  await settle(window, () => flat.length);
  const sent = flat[0];

  // Exactly what main.js's hub:hf-export-flat-3mf does with the payload.
  const built = FLAT.buildFlatParts(
    { labels: Array.from(sent.labels), palette: Array.from(sent.palette), width: sent.width, height: sent.height },
    { widthMm: sent.widthMm, heightMm: sent.heightMm, capMm: sent.capMm },
  );
  assert.ok(built && built.parts.length, 'the payload should rebuild into parts');

  const buf = M3.buildFlatU1_3mf({
    parts: built.parts,
    filaments: (Array.isArray(sent.filaments) && sent.filaments.length) ? sent.filaments : built.filaments,
    sizeMm: built.sizeMm,
    baseHead: Number.isInteger(sent.baseHead) ? sent.baseHead : built.baseHead,
    layerH: sent.layerH, name: sent.name,
  });
  assert.ok(buf && buf.length, 'and that should assemble into a 3MF');

  const zip = openZip(buf);
  const names = zip.entries.map((e) => e.name);
  assert.ok(names.includes('3D/Objects/object_1.model'));
  assert.ok(!names.includes('Metadata/layer_config_ranges.xml'), 'flat files carry no Z-band table');

  const settings = Buffer.from(zip.file('Metadata/model_settings.config')).toString('utf8');
  const extruders = [...settings.matchAll(/<part id="\d+"[\s\S]*?key="extruder" value="(\d+)"/g)].map((m) => +m[1]);
  assert.equal(extruders.length, built.parts.length, 'every part reaches the file with a head');
  for (const e of extruders) assert.ok(e >= 1 && e <= 4, 'extruder ' + e + ' is not a U1 head');
});
