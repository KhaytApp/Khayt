'use strict';
/**
 * Settings: 14 panes in the Mac's order and groups (desktop-settings-menus-review.md §4.1).
 * Cards moved between panes, but no control may be lost, doubled or renamed,
 * and every old section id still opens a pane.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'renderer/index.html'), 'utf8');
const shell = fs.readFileSync(path.join(root, 'renderer/shell.js'), 'utf8');

const PANES = ['general', 'shop', 'pricing', 'invoices', 'production', 'team', 'printers', 'library',
  'cloud', 'store', 'notify', 'connections', 'ai', 'advanced'];

const nav = html.slice(html.indexOf('<nav class="settings-sidebar"'), html.indexOf('</nav>', html.indexOf('<nav class="settings-sidebar"')));

test('the sidebar lists the 14 panes in the Mac\'s order, with its three group headers', () => {
  const items = [...nav.matchAll(/data-settings-section="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(items, PANES);
  const groups = [...nav.matchAll(/settings-nav-group-label" data-i18n="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(groups, ['set.nav_group_shop', 'set.nav_group_workshop', 'set.nav_group_online', 'set.nav_group_advanced']);
});

test('every pane has a panel, a title and a Save button, and nothing else is a panel', () => {
  const panels = [...html.matchAll(/class="settings-panel[^"]*" id="settings-panel-([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(panels, PANES);
  for (const p of PANES) {
    const start = html.indexOf(`id="settings-panel-${p}"`);
    const next = PANES.slice(PANES.indexOf(p) + 1).map((q) => html.indexOf(`id="settings-panel-${q}"`)).find((i) => i > 0) || html.length;
    const body = html.slice(start, next);
    assert.match(body, new RegExp(`data-i18n="set.pane_${p}"`), p + ' title');
    assert.match(body, /class="settings-save-row"/, p + ' save row');
  }
});

test('a pane hidden from a mode is hidden in the sidebar the same way', () => {
  for (const m of nav.matchAll(/class="settings-nav-item([^"]*)" data-settings-section="([^"]+)"/g)) {
    const navCls = m[1].split(/\s+/).filter((c) => c === 'pro-only' || c === 'biz-only');
    const panel = html.match(new RegExp(`class="settings-panel([^"]*)" id="settings-panel-${m[2]}"`))[1];
    const panelCls = panel.split(/\s+/).filter((c) => c === 'pro-only' || c === 'biz-only');
    assert.deepEqual(navCls, panelCls, m[2]);
  }
});

test('no id is on the page twice, and the Save buttons keep their ids', () => {
  const ids = [...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]);
  const dup = ids.filter((id, i) => ids.indexOf(id) !== i);
  assert.deepEqual(dup, []);
  assert.ok(ids.includes('btnSaveSettings'));
  // It re-renders the expense budgets, so it must sit in the pane they moved to.
  const pricing = html.slice(html.indexOf('id="settings-panel-pricing"'), html.indexOf('id="settings-panel-invoices"'));
  assert.match(pricing, /id="set_budget_filament"/);
  assert.match(pricing, /id="btnSaveOpsSettings"/);
});

test('every old section id resolves to a pane that exists', () => {
  const block = shell.match(/const SETTINGS_SECTION_ALIASES = \{([\s\S]*?)\};/)[1];
  const map = Object.fromEntries([...block.matchAll(/(\w+): '(\w+)'/g)].map((m) => [m[1], m[2]]));
  assert.deepEqual(Object.keys(map).sort(),
    ['access', 'automation', 'biz', 'data', 'invoice', 'online', 'ops', 'payments', 'prefs', 'stock'].sort());
  for (const [from, to] of Object.entries(map)) assert.ok(PANES.includes(to), `${from} → ${to}`);
});

test('every pane and group name is translated in all 9 languages', () => {
  const keys = PANES.map((p) => 'set.pane_' + p).concat(['set.nav_group_shop', 'set.nav_group_workshop', 'set.nav_group_online']);
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = fs.readFileSync(path.join(root, 'renderer/locales', lang + '.js'), 'utf8');
    for (const k of keys) assert.match(src, new RegExp(`"${k.replace('.', '\\.')}": "[^"]+"`), `${lang} ${k}`);
  }
});

test('loyalty is shown in Simple mode: nothing open around its card is pro-only (Turki, Nov 10)', () => {
  const at = html.indexOf('id="settingsLoyaltyCard"');
  assert.ok(at > 0 && html.indexOf('set_loyaltyEnabled', at) > at, 'the loyalty card has its id');
  const cardOpen = html.lastIndexOf('<div', at);
  const pane = html.lastIndexOf('<div class="settings-panel', at);
  // Every <div> still open at the card, from its pane down, so a gate at any
  // depth is seen. Simple, not hobbyist: only pro-only is banned (biz-only
  // also hides from hobbyist shops, which the ruling did not cover).
  const open = [];
  for (const m of html.slice(pane, cardOpen).matchAll(/<div\b[^>]*>|<\/div>/g)) {
    if (m[0].startsWith('</')) open.pop(); else open.push(m[0]);
  }
  open.push(html.slice(cardOpen, html.indexOf('>', at) + 1));
  assert.match(open[0], /id="settings-panel-pricing"/, 'in Pricing & Tax, as on the Mac');
  for (const tag of open) assert.doesNotMatch(tag, /\bpro-only\b/, tag);
});
