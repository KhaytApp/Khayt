/**
 * Which tabs a customer can reach, and the three places that have to agree.
 *
 * Tab visibility is decided in two hand-maintained lists that sit in different
 * files and different languages:
 *
 *   renderer/index.html   `.biz-only` / `.pro-only` classes on the nav buttons —
 *                         what CSS hides
 *   renderer/shell.js     BIZ_TABS / PRO_TABS — what bounces the active tab and
 *                         blocks keyboard/programmatic navigation
 *
 * shell.js literally carries the comment "Keep in sync with the .biz-only /
 * .pro-only nav buttons in index.html", which is the same arrangement that let
 * the settings export list rot until four panels were unreachable. A comment is
 * not a mechanism.
 *
 * The consequences point in both directions and neither is loud. A tab in the
 * HTML lists but missing from shell.js stays reachable by keyboard after the CSS
 * hides it. A tab in shell.js but no longer in the HTML gets bounced away from a
 * customer who is entitled to it — a paid feature that silently does not open.
 *
 * Semantics being asserted:
 *   .pro-only  → not available below Professional
 *   .biz-only  → not available in the commerce-free (enthusiast) experience
 *   BIZ_TABS   → everything unavailable in enthusiast, so the UNION of both
 *   PRO_TABS   → exactly the pro-only set
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const HTML = fs.readFileSync(path.join(ROOT, 'renderer/index.html'), 'utf8');
const SHELL = fs.readFileSync(path.join(ROOT, 'renderer/shell.js'), 'utf8');

/** Nav buttons carrying a gating class, by the tab they open. */
function gatedNavTabs() {
  const biz = new Set();
  const pro = new Set();
  for (const m of HTML.matchAll(/<button[^>]*>/g)) {
    const tag = m[0];
    const tab = tag.match(/data-tab="([a-z0-9-]+)"/);
    if (!tab) continue;
    const cls = (tag.match(/class="([^"]*)"/) || [, ''])[1];
    if (/\bbiz-only\b/.test(cls)) biz.add(tab[1]);
    if (/\bpro-only\b/.test(cls)) pro.add(tab[1]);
  }
  return { biz, pro };
}

/** A `const NAME = ['a', 'b']` array out of shell.js. */
function shellList(name) {
  const m = SHELL.match(new RegExp(`const ${name}\\s*=\\s*\\[([^\\]]*)\\]`));
  assert.ok(m, `${name} not found in shell.js — this check has lost its subject`);
  return new Set(m[1].split(',').map((s) => s.trim().replace(/^'|'$/g, '')).filter(Boolean));
}

/** Every tab id the app actually defines a panel for. */
function realTabs() {
  return new Set([...HTML.matchAll(/id="([a-z0-9-]+-tab)"/g)].map((m) => m[1]));
}

test('the check can still see the nav, the lists and the tabs', () => {
  // Guards the guard: if any of these three extractions silently returned
  // nothing, every assertion below would pass against empty sets.
  const { biz, pro } = gatedNavTabs();
  assert.ok(biz.size >= 5, `expected several biz-only nav tabs, found ${biz.size}`);
  assert.ok(pro.size >= 1, `expected at least one pro-only nav tab, found ${pro.size}`);
  assert.ok(shellList('BIZ_TABS').size >= 5);
  assert.ok(realTabs().size >= 10, 'expected the app to define many tab panels');
});

test('every gated nav tab is also blocked in code, not just hidden by CSS', () => {
  // CSS hiding without the code list means the tab is still reachable by
  // keyboard or by a programmatic switchTab — visually gone, functionally open.
  const { biz, pro } = gatedNavTabs();
  const BIZ = shellList('BIZ_TABS');
  const unguarded = [...new Set([...biz, ...pro])].filter((t) => !BIZ.has(t)).sort();
  assert.deepEqual(unguarded, [],
    `hidden by CSS but still reachable in code: ${unguarded.join(', ')}`);
});

test('PRO_TABS is exactly the set marked pro-only in the nav', () => {
  const { pro } = gatedNavTabs();
  const PRO = shellList('PRO_TABS');
  assert.deepEqual([...PRO].sort(), [...pro].sort(),
    'a Professional-gated tab must be gated in both places, or a paying customer loses it');
});

test('no gating list names a tab that does not exist', () => {
  // A renamed or removed tab leaves a phantom entry behind. Harmless-looking,
  // until the rename means a real tab is now ungated.
  const tabs = realTabs();
  for (const name of ['BIZ_TABS', 'PRO_TABS']) {
    const phantom = [...shellList(name)].filter((t) => !tabs.has(t)).sort();
    assert.deepEqual(phantom, [], `${name} lists tabs the app does not define: ${phantom.join(', ')}`);
  }
});

test('a Professional-only tab is also unavailable in the commerce-free experience', () => {
  // PRO_TABS ⊆ BIZ_TABS. Expenses is the live example: Professional-gated AND
  // absent from the hobbyist build. If this inverts, the commerce-free flavour
  // starts showing a business surface.
  const PRO = shellList('PRO_TABS');
  const BIZ = shellList('BIZ_TABS');
  const leaked = [...PRO].filter((t) => !BIZ.has(t)).sort();
  assert.deepEqual(leaked, [],
    `Pro-only tabs must also be hidden in the commerce-free build: ${leaked.join(', ')}`);
});

test('the tier registry describes both gated tiers and does not double-count', () => {
  // lib/feature-tiers.js calls itself the single source of truth for tiering. It
  // lists features rather than tabs, so it cannot be diffed against the nav —
  // but a feature claimed by two tiers makes the comparison UI incoherent.
  const tiers = require('../lib/feature-tiers.js');
  assert.ok(Array.isArray(tiers.BUSINESS_FEATURES) && tiers.BUSINESS_FEATURES.length);
  assert.ok(Array.isArray(tiers.PRO_FEATURES) && tiers.PRO_FEATURES.length);
  const proKeys = new Set(tiers.PRO_FEATURES.map((f) => f.key));
  const dupes = tiers.BUSINESS_FEATURES.map((f) => f.key).filter((k) => proKeys.has(k)).sort();
  assert.deepEqual(dupes, [], `claimed by both tiers: ${dupes.join(', ')}`);
});
