'use strict';
/**
 * One list of client sources, wherever it is written or read.
 *
 * A client's `source` says where the customer came from. Two places write one:
 * the customer form, from a dropdown, and the intake import in
 * `renderer/integrations.js`, which stamps `source: 'online'` when a shop turns
 * an order request into a quote.
 *
 * The analytics chart read a **different** list — six values typed into the
 * function, without `online`. So every customer who arrived through the shop's
 * own intake form was counted into a bucket the chart then never drew, and
 * their revenue with them. The customer list's badge had the same gap from the
 * other end: it rendered `t('cl.source_' + c.source)`, no locale had
 * `cl.source_online`, and Khayt's `t()` returns the key when it has no
 * translation — so the badge printed the literal string `cl.source_online`
 * beside the customer's name.
 *
 * Neither failure announced itself. A chart that omits a source looks exactly
 * like a source that brought in nobody.
 *
 * So this is the ratchet. It fails when a source is written that the shared
 * list does not have, when a screen types the list out instead of reading it,
 * and when any locale cannot name one — the three ways this broke.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const CS = require('../lib/client-sources.js');

const read = rel => fs.readFileSync(path.join(ROOT, rel), 'utf8');

/** Files that create or update a client record. */
const WRITERS = [
  'renderer/clients.js',
  'renderer/integrations.js',
  'renderer/waiting-list.js',
];

test('every source any code writes is in the shared list', () => {
  const written = new Set();
  for (const file of WRITERS) {
    const src = read(file);
    // Only literals inside a CLIENT being built. A bare `source:` sweep is too
    // wide: `redeemLoyaltyPoints` writes `source: 'loyalty'` onto a store
    // credit, which is not a client and must not widen this list. Every client
    // in Khayt is created with `uid('CLI')`, so that is the anchor, and the
    // window is the object literal that follows it.
    for (const m of src.matchAll(/uid\('CLI'\)/g)) {
      const literal = src.slice(m.index, m.index + 400);
      for (const hit of literal.matchAll(/\bsource:\s*'([a-z_]+)'/g)) written.add(hit[1]);
    }
  }
  // Sanity: the sweep has to actually find something, or it proves nothing.
  assert.ok(written.size > 0, 'found no written sources — the patterns have gone stale');
  assert.ok(written.has('online'), 'the intake import writes `online`; it must still be swept');

  const strays = [...written].filter(s => !CS.SOURCES.includes(s));
  assert.deepEqual(strays, [],
    'a client is being given a source the chart cannot draw and no locale can name:\n'
    + strays.join('\n'));
});

test('no screen types the list of sources out by hand', () => {
  const typed = [];
  for (const file of ['renderer/analytics.js', 'renderer/clients.js']) {
    const src = read(file);
    // The exact shape that was there: an array literal of source names.
    if (/\[\s*'instagram'\s*,\s*'referral'/.test(src)) typed.push(file);
  }
  assert.deepEqual(typed, [],
    'read KhaytClientSources.SOURCES instead — a second list is how `online` was missed');
});

test('the chart and the badge both go through the shared list', () => {
  assert.match(read('renderer/analytics.js'), /KhaytClientSources\.byClient\(/,
    'the source chart must come from the rule');
  assert.match(read('renderer/clients.js'), /KhaytClientSources\.normalize\(c\.source\)/,
    'the badge must normalise, or an unknown source prints its own key');
});

test('every locale names every source', () => {
  const dir = path.join(ROOT, 'renderer/locales');
  const locales = fs.readdirSync(dir).filter(f => f.endsWith('.js'));
  assert.ok(locales.length >= 9, `expected the full set of locales, saw ${locales.length}`);

  const missing = [];
  for (const file of locales) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const source of CS.SOURCES) {
      if (!src.includes(`"cl.source_${source}"`)) missing.push(`${file}: cl.source_${source}`);
    }
  }
  // A missing key does not fall back — see [[khayt-i18n-fallback-trap]]. It
  // renders as the key itself, in front of a customer's name.
  assert.deepEqual(missing, [], missing.join('\n'));
});

test('no locale names a source nothing can carry', () => {
  const dir = path.join(ROOT, 'renderer/locales');
  const known = new Set(CS.SOURCES);
  const strays = [];
  for (const file of fs.readdirSync(dir).filter(f => f.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const m of src.matchAll(/"cl\.source_([a-z_]+)"/g)) {
      if (!known.has(m[1])) strays.push(`${file}: cl.source_${m[1]}`);
    }
  }
  assert.deepEqual(strays, [],
    'either the list lost a source or the key is a typo:\n' + strays.join('\n'));
});

test('every source a shop can see has a badge colour', () => {
  const css = read('renderer/styles.css');
  const missing = CS.SOURCES
    .filter(s => s !== CS.DEFAULT_SOURCE) // `other` draws no badge at all
    .filter(s => !css.includes(`.source-${s}`));
  assert.deepEqual(missing, [],
    'an unstyled badge is a bare pill with no colour:\n' + missing.join('\n'));
});
