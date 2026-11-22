/**
 * Consumable categories, as wired in.
 *
 * lib/consumable-categories.js is where the grouping is tested. What can only go
 * wrong here reads as data loss rather than as a bug:
 *
 *   1. The filter surviving the category it names. resolveSelection() exists for
 *      this, but only helps if the render actually calls it.
 *   2. An empty list with no way out. The only route to one is a filter, so the
 *      empty state has to say so and offer All — otherwise the shop sees a
 *      consumables table that has apparently lost everything.
 *   3. A control wired to a function the other IIFE cannot see, or a listener
 *      bound to a node that is re-rendered out from under it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const inv = read('renderer/inventory.js');
const wire = read('renderer/wire-events.js');
const html = read('renderer/index.html');

test('the module is loaded, or the picker is dead on arrival', () => {
  assert.match(html, /<script src="\.\.\/lib\/consumable-categories\.js"><\/script>/,
    'lib/consumable-categories.js is never loaded');
  assert.match(html, /id="consCategoryFilter"/, 'the filter has nowhere to render');
});

test('the selection is reconciled on every draw, not just when it changes', () => {
  // A category emptied by an edit elsewhere would otherwise stay selected and
  // hide the whole list.
  const at = inv.indexOf('function renderConsCategoryFilter(');
  const body = inv.slice(at, inv.indexOf('\n}', at));
  assert.match(body, /consCategoryFilter = CC\.resolveSelection\(consumables, consCategoryFilter\)/,
    'a stale filter is never reconciled');
});

test('the list filters through the tested module, not inline', () => {
  const at = inv.indexOf('function renderConsumables(');
  const body = inv.slice(at, inv.indexOf('\n}\n', at));
  assert.match(body, /KhaytConsumableCategories\.filterByCategory\(consumables, consCategoryFilter\)/,
    'the list does its own filtering and can disagree with the picker');
  assert.match(body, /renderConsCategoryFilter\(\)/, 'the picker is never refilled');
});

test('an empty category says so and offers the way out', () => {
  const at = inv.indexOf('function renderConsumables(');
  const body = inv.slice(at, inv.indexOf('\n}\n', at));
  assert.match(body, /shown\.length === 0/, 'an empty filtered list falls through to the normal render');
  assert.match(body, /cons\.cat_empty/, 'the empty state does not say why it is empty');
  assert.match(body, /data-act="cons-cat-all"/, 'there is no way back to All from the empty state');
});

test('the empty-state button is delegated — it is re-rendered every draw', () => {
  // Anchored on the handler that actually handles it. The table already had a
  // delegated click listener for edit/delete, so matching the selector alone
  // passes on THAT one — which is how this check first let a mutant through.
  const at = wire.indexOf("$('#consumablesTable')?.addEventListener('click'");
  assert.ok(at > -1, 'the consumables table has no delegated click handler at all');
  const body = wire.slice(at, wire.indexOf('\n  });', at));
  assert.match(body, /btn\.dataset\.act === 'cons-cat-all'/,
    'the All button is not handled by the table\'s delegated listener');
  assert.match(body, /setConsCategoryFilter\(''\)/, 'it is matched but does nothing');
});

test('the picker is wired to something exported', () => {
  assert.match(wire, /#consCategoryFilter'\)\?\.addEventListener\('change'/, 'a dead picker');
  assert.match(inv, /function setConsCategoryFilter\(/, 'setConsCategoryFilter is not defined');
  const api = inv.slice(inv.indexOf('    renderConsumables,'), inv.indexOf('    renderConsumables,') + 400);
  assert.match(api, /\bsetConsCategoryFilter,/,
    'setConsCategoryFilter is not exported — wire-events cannot see it');
});

test('the category is saved, trimmed', () => {
  // This used to pin the renderer's own `draft.category = (…).trim()` line.
  // That line is gone: the trim — and the clamp, the booleans and what a blank
  // category means — moved to lib/consumable-edit.js when the Mac needed the
  // same answers. Pinning the text would now fail on a lift that changed no
  // behaviour at all, so this asserts the BEHAVIOUR and, separately, that the
  // editor still routes through the rule that provides it.
  const { newConsumable, applyEdit } = require('../lib/consumable-edit.js');
  assert.equal(newConsumable({ name: 'x', category: '  Spares  ' }, { id: 'C' })
    .consumable.category, 'Spares', 'a category is not trimmed on the way in');
  const existing = { id: 'C', name: 'x', category: 'Spares' };
  applyEdit(existing, { category: '  Fasteners ' });
  assert.equal(existing.category, 'Fasteners', 'an edited category is not trimmed');

  assert.match(inv, /data-f="category"/, 'the editor has no category field');
  assert.match(inv, /KhaytConsumableEdit\.(newConsumable|applyEdit)/,
    'the editor no longer saves through the shared rule');
  assert.match(html, /<script src="\.\.\/lib\/consumable-edit\.js"><\/script>/,
    'lib/consumable-edit.js is never loaded, so saving throws');
});

test('the editor suggests categories the shop already uses', () => {
  assert.match(inv, /KhaytConsumableCategories\.suggestions\(consumables\)/,
    'every category must be retyped from memory');
  assert.match(inv, /list="consCategoryList"/, 'the datalist is not attached to the input');
});

test('the picker hides itself when there is nothing to choose between', () => {
  const at = inv.indexOf('function renderConsCategoryFilter(');
  const body = inv.slice(at, inv.indexOf('\n}', at));
  assert.match(body, /cats\.length < 2/, 'a one-category shop is shown a pointless picker');
});

test('the strings are translated everywhere', () => {
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    for (const k of ['cons.category', 'cons.category_ph', 'cons.cat_all', 'cons.cat_none', 'cons.cat_empty']) {
      assert.ok(loc.includes(`"${k}":`), `${code} is missing ${k}`);
    }
  }
});
