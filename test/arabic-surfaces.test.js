'use strict';
/**
 * The Arabic desktop is Arabic, and Latin values keep their order (Nov 11
 * desktop UI review, F7/F9/F10). Every item here was an English literal in a
 * template or a macOS-only setting, not a missing locale key, so the locale
 * parity test could never see it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const read = (rel) => fs.readFileSync(path.join(__dirname, '..', rel), 'utf8');

test('the surfaces that were English go through t()', () => {
  const eod = read('renderer/operations-extras.js');
  const body = eod.slice(eod.indexOf('function openEndOfDayReport'), eod.indexOf('function', eod.indexOf('function openEndOfDayReport') + 10));
  for (const s of ['End of Day Report', 'Orders Completed', 'Revenue Today', 'Filament Wasted', 'Time Logged', 'Due Today', "'Export as PDF'"]) {
    assert.ok(!body.includes(s), `end of day still says "${s}"`);
  }
  const set = read('renderer/settings.js');
  for (const s of ['No operator active', 'Add operators in the Operators section', 'Notify on order on_hold', 'Notify on order completed', 'Notify on low stock', '<label>Bot Token</label>', '>Save PIN<']) {
    assert.ok(!set.includes(s), `settings still says "${s}"`);
  }
  const html = read('renderer/index.html');
  assert.ok(!html.includes('placeholder="This Mac (default)"'), 'Library still says "This Mac"');
  assert.ok(!/<kbd>⌘K<\/kbd>/.test(html), 'the search chip still says ⌘K on Windows/Linux');
  assert.ok(!/data-i18n="app\.title">Khayt<\/span> · خيط/.test(html), 'About still doubles the Arabic name');
});

test('no locale puts the macOS shortcut in the search placeholder', () => {
  const dir = path.join(__dirname, '../renderer/locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    const m = fs.readFileSync(path.join(dir, f), 'utf8').match(/"search\.placeholder": "([^"]*)"/);
    assert.ok(m && !m[1].includes('⌘'), `${f}: ${m && m[1]}`);
  }
});

test('Arabic is set in the bundled Plex Arabic, and Latin values isolate left-to-right', () => {
  const css = read('renderer/styles.css');
  const ar = css.match(/\[lang="ar"\]\s*\{[^}]*\}/);
  assert.ok(ar && /IBM Plex Sans Arabic/.test(ar[0]) && !/SF Arabic|Geeza Pro/.test(ar[0]), 'the [lang=ar] stack');
  assert.match(read('renderer/fonts/fonts.css'), /font-family: "IBM Plex Sans Arabic"/);
  assert.match(css, /html\[dir="rtl"\]\[data-design\]\s*\{[^}]*IBM Plex Sans Arabic/, 'the mono stack falls back to Arabic under RTL');
  const iso = css.match(/code, kbd, samp, bdi\[dir="ltr"\][^{]*\{[^}]*\}/);
  assert.ok(iso && /direction: ltr/.test(iso[0]) && /unicode-bidi: isolate/.test(iso[0]), 'code/kbd/bdi isolate LTR');
  for (const cls of ['.cs-hex', '.cs-step-hex', '.cp-hex', '.ltr-value']) assert.ok(iso[0].includes(cls), cls);
  assert.match(read('renderer/clients.js'), /<bdi dir="ltr">\$\{escapeHtml\(c\.phone/, 'the Clients phone cell');
});
