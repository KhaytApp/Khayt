/**
 * Bed Ready's theme CSS, checked for the shape of bug that hides in plain sight.
 *
 * bedready-theme.css owns the shell layout that the dropped theme CSS used to provide,
 * including hiding every other design's masthead. That block lost its body: the selector
 * list ended `.command-pagehead,` with a trailing comma and ran straight into the sidebar
 * rule below it, so those selectors were handed a WIDTH and never a display.
 *
 * Nothing errored. CSS does not complain about a selector list that merges into the next
 * rule — it just applies the wrong declarations. Bed Ready drew its own masthead and then
 * ledger's and console's underneath, three brands and three "Dashboard" headings on every
 * screen, and had been doing so since the redesign.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const CSS = fs.readFileSync(path.join(__dirname, '../renderer/bedready-theme.css'), 'utf8');

/** The declaration block a selector lands in, or null if it never reaches one. */
function blockFor(selector) {
  const at = CSS.indexOf(selector);
  if (at === -1) return null;
  const open = CSS.indexOf('{', at);
  if (open === -1) return null;
  return CSS.slice(open + 1, CSS.indexOf('}', open));
}

test('every alternate design\'s masthead is actually hidden', () => {
  for (const sel of [
    '.ledger-masthead-brand', '.ledger-pagehead', '.ledger-path',
    '.console-masthead-brand', '.console-pagehead', '.console-path',
    '.workbench-pagehead', '.vivid-pagehead', '.command-pagehead',
  ]) {
    const block = blockFor('html[data-app="bedready"] ' + sel);
    assert.ok(block, sel + ' has no rule at all in bedready-theme.css');
    assert.match(block, /display:\s*none/,
      sel + ' reaches a block that does not hide it — Bed Ready will draw it over its own masthead');
  }
});

test('the hiding block does not swallow the rule after it', () => {
  // The exact failure: a trailing comma merged the list into the sidebar-width rule, so
  // the mastheads got `width: var(--nav-w)` instead of `display: none`.
  const block = blockFor('html[data-app="bedready"] .command-pagehead');
  assert.ok(block && !/width\s*:/.test(block),
    'the masthead block contains a width — its selector list has run into the sidebar rule');
});

test('the sidebar still gets its pinned width', () => {
  const block = blockFor('html[data-app="bedready"] body.bedready-ui .khayt-sidebar');
  assert.ok(block && /width:\s*var\(--nav-w\)/.test(block),
    'fixing the comma must not cost the sidebar the width it depends on');
});
