/**
 * DOM render-path test harness.
 *
 * Loads the real renderer/index.html into jsdom so render functions can write
 * into the same element IDs they target at runtime, then exposes the browser
 * globals (window/document/localStorage/$/$$ …) the renderer modules expect.
 *
 * Renderer modules are plain IIFEs that attach their API to `globalThis` and
 * read free globals (printLog, inventory, settings, $, fmtMoney …). Tests set
 * those globals, require the module, call the render function, and assert on the
 * produced DOM — locking in fixes that only manifest on the render path.
 *
 * Usage:
 *   const { setupDom } = require('./helpers/dom.js');
 *   const dom = setupDom();          // call once per test (beforeEach-style)
 *   ... set globals, require module, render ...
 *   dom.teardown();                  // optional; node runs each file in its own process
 */
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const INDEX_HTML = fs.readFileSync(
  path.join(__dirname, '..', '..', 'renderer', 'index.html'),
  'utf8',
);

// Minimal no-op 2D context so chart/canvas render paths don't throw under jsdom
// (jsdom has no canvas implementation without the native `canvas` package).
function stubCanvasContext() {
  const noop = () => {};
  return new Proxy(
    {
      canvas: null,
      fillRect: noop, clearRect: noop, strokeRect: noop,
      beginPath: noop, closePath: noop, moveTo: noop, lineTo: noop,
      arc: noop, arcTo: noop, bezierCurveTo: noop, quadraticCurveTo: noop,
      rect: noop, fill: noop, stroke: noop, clip: noop,
      save: noop, restore: noop, scale: noop, rotate: noop, translate: noop,
      transform: noop, setTransform: noop, resetTransform: noop,
      fillText: noop, strokeText: noop,
      measureText: () => ({ width: 0 }),
      setLineDash: noop, getLineDash: () => [],
      createLinearGradient: () => ({ addColorStop: noop }),
      createRadialGradient: () => ({ addColorStop: noop }),
      createPattern: () => null,
      drawImage: noop,
      putImageData: noop,
      getImageData: () => ({ data: new Uint8ClampedArray(4) }),
      createImageData: () => ({ data: new Uint8ClampedArray(4) }),
    },
    { get: (t, p) => (p in t ? t[p] : noop), set: () => true },
  );
}

// State collections declared as script-scope `let`s in renderer/app-state.js.
// In the browser they're shared across renderer scripts; under Node's per-module
// scope they aren't, so render functions read them as free globals that tests
// must seed. seedState() provides an empty-but-complete baseline.
const STATE_COLLECTIONS = [
  'printLog', 'machines', 'printers', 'inventory', 'templates', 'products',
  'clients', 'expenses', 'wasteLog', 'machMaintLog', 'consumables', 'suppliers',
  'purchaseOrders', 'testPrints', 'locations', 'operators', 'waitingList',
  'waitingListHistory', 'timeEntries', 'shiftLogs', 'giftCards', 'slicerProfiles',
  'envLogs', 'waTemplates',
];

const GLOBAL_KEYS = [
  'window', 'document', 'navigator', 'localStorage', 'sessionStorage',
  'HTMLElement', 'Node', 'Element', 'CustomEvent', 'Event',
  'getComputedStyle', 'requestAnimationFrame', 'cancelAnimationFrame',
  'matchMedia',
];

function setupDom() {
  // Scripts in index.html are NOT executed (default runScripts) and external
  // resources are NOT fetched (default resources) — we only want the markup.
  const dom = new JSDOM(INDEX_HTML, { url: 'http://localhost/' });
  const { window } = dom;

  window.HTMLCanvasElement.prototype.getContext = function () {
    return stubCanvasContext();
  };
  if (!window.matchMedia) {
    window.matchMedia = (q) => ({
      matches: false, media: q, onchange: null,
      addListener() {}, removeListener() {},
      addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; },
    });
  }
  if (!window.requestAnimationFrame) {
    window.requestAnimationFrame = (cb) => setTimeout(() => cb(0), 0);
    window.cancelAnimationFrame = (id) => clearTimeout(id);
  }

  const g = globalThis;
  const saved = {};
  for (const k of GLOBAL_KEYS) {
    saved[k] = Object.prototype.hasOwnProperty.call(g, k) ? g[k] : undefined;
    if (k in window) g[k] = window[k];
  }
  g.window = window;
  g.document = window.document;

  // util.js defines $ / $$ (and other helpers) and attaches them to globalThis.
  // Require it after document is in place so the helpers resolve against jsdom.
  delete require.cache[require.resolve('../../renderer/util.js')];
  require('../../renderer/util.js');

  return {
    dom,
    window,
    document: window.document,
    /**
     * Load the i18n stack (English locale + i18n.js) and mirror `i18n` / `t`
     * onto globalThis, since i18n.js assigns them to the jsdom `window` rather
     * than the global scope where renderer free-vars resolve.
     */
    loadI18n() {
      delete require.cache[require.resolve('../../renderer/locales/en.js')];
      delete require.cache[require.resolve('../../renderer/i18n.js')];
      require('../../renderer/locales/en.js');
      require('../../renderer/i18n.js');
      g.i18n = window.i18n;
      g.t = window.t;
      return window.i18n;
    },
    /**
     * Seed a complete, empty app state on globalThis. Every collection in
     * STATE_COLLECTIONS becomes `[]`, plus the common scalar globals render
     * paths read. Pass `overrides` to replace specific collections/scalars.
     * Returns the resulting state object (also applied to globalThis).
     */
    seedState(overrides = {}) {
      const state = {
        settings: {},
        machineStatusCache: {},
        activeLocation: null,
        analyticsRange: 'all',
        // UI filter / selection scalars (script-scope lets in app-state.js)
        logSearchTerm: '', logClientFilter: '', logOperatorFilter: '',
        logStatusFilter: '', logPayFilter: '', logRangeFilter: 'all',
        logTagFilter: '', logDisplayLimit: 100,
        logSortCol: 'date', logSortDir: 'desc',
        kanSearchTerm: '', kanbanCollapsed: new Set(), selectedOrders: new Set(),
      };
      for (const k of STATE_COLLECTIONS) state[k] = [];
      Object.assign(state, overrides);
      for (const [k, v] of Object.entries(state)) g[k] = v;
      return state;
    },
    teardown() {
      for (const k of GLOBAL_KEYS) {
        if (saved[k] === undefined) delete g[k];
        else g[k] = saved[k];
      }
      window.close();
    },
  };
}

module.exports = { setupDom };
