/**
 * Hover descriptions, and the accessible name that must survive them.
 *
 * Icon-only buttons carry a `title`. That is right in the markup and wrong at
 * runtime: Chromium decides when to show it and waits roughly a second, which
 * is not configurable from CSS or from an attribute. Reported as "the icons
 * either don't load the description or take a long time to load, it's not
 * instant".
 *
 * renderer/tooltips.js replaces it. The risk in doing that is not visual: it is
 * that taking `title` away silently un-names every icon button for a screen
 * reader, reintroducing at runtime the exact defect
 * test/button-accessible-name.test.js exists to prevent — somewhere that check,
 * which reads source, can never see.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JSDOM } = require('jsdom');

function withDom(html) {
  const dom = new JSDOM(`<!doctype html><body>${html}</body>`);
  // The module attaches to `document` on load, so both have to be in place
  // before it is required.
  global.window = dom.window;
  global.document = dom.window.document;
  delete require.cache[require.resolve('../renderer/tooltips.js')];
  const api = require('../renderer/tooltips.js');
  return { dom, api, $: (s) => dom.window.document.querySelector(s) };
}

test('a title becomes a tooltip and stops being a native one', () => {
  const { api, $ } = withDom('<button id="b" title="Log a nozzle change">🔩</button>');
  const el = $('#b');
  assert.equal(api.adopt(el), 'Log a nozzle change');
  assert.equal(el.getAttribute('title'), null,
    'the native tooltip must be suppressed, or both appear and the slow one lands on top');
  assert.equal(el.dataset.khaytTip, 'Log a nozzle change');
});

test('the button keeps its name for a screen reader', () => {
  // This is the whole risk of the change. A screen reader falls back to `title`
  // when there is no label, so removing it without this leaves a nameless button.
  const { api, $ } = withDom('<button id="b" title="Delete machine">🗑</button>');
  const el = $('#b');
  api.adopt(el);
  assert.equal(el.getAttribute('aria-label'), 'Delete machine');
});

test('an existing label is never overwritten', () => {
  // The label is the considered wording; the title may be a longer hint. The
  // label wins, because that is what someone chose to have announced.
  const { api, $ } = withDom('<button id="b" title="Read every job this printer has run" aria-label="Import print history">📥</button>');
  const el = $('#b');
  api.adopt(el);
  assert.equal(el.getAttribute('aria-label'), 'Import print history');
  assert.equal(el.dataset.khaytTip, 'Read every job this printer has run');
});

test('aria-labelledby counts as a name too', () => {
  const { api, $ } = withDom('<span id="lbl">Filters</span><button id="b" title="Show filters" aria-labelledby="lbl">⚙</button>');
  const el = $('#b');
  api.adopt(el);
  assert.equal(el.getAttribute('aria-label'), null, 'a button named by another element must not gain a second name');
});

test('an empty or missing title produces nothing', () => {
  const { api, $ } = withDom('<button id="a" title="   ">x</button><button id="b">y</button>');
  assert.equal(api.adopt($('#a')), '');
  assert.equal($('#a').getAttribute('aria-label'), null, 'whitespace is not a description');
  assert.equal(api.adopt($('#b')), '');
});

test('adopting twice keeps the first answer', () => {
  // Elements are hovered repeatedly; the title is gone after the first pass and
  // the tip has to survive that.
  const { api, $ } = withDom('<button id="b" title="Edit">✎</button>');
  const el = $('#b');
  api.adopt(el);
  assert.equal(api.adopt(el), 'Edit', 'a second hover must still know what to show');
});

test('it is delay-driven, and the delay is this app\'s to choose', () => {
  const { api } = withDom('<button title="x">x</button>');
  assert.ok(api.SHOW_DELAY_MS > 0 && api.SHOW_DELAY_MS <= 300,
    'fast enough to read as an answer rather than a wait — the native delay it replaces is ~1000ms');
});

test('the module is loaded by both apps', () => {
  // Built and never plugged in is the recurring way a fix like this ships inert.
  const fs = require('fs');
  const path = require('path');
  for (const page of ['index.html', 'bedready.html']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', page), 'utf8');
    assert.match(src, /<script src="tooltips\.js"><\/script>/, `${page} must load tooltips.js`);
  }
});
