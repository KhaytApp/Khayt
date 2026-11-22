const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

/**
 * A label a screen reader cannot follow is not a label.
 *
 * Both entry points were full of this shape:
 *
 *     <div>
 *       <label><span data-i18n="calc.layer_height">Layer height</span> (mm)</label>
 *       <input type="number" id="layerHeight" placeholder="0.2">
 *     </div>
 *
 * The label is a SIBLING with no `for=`, so nothing connects the two. Sighted
 * use is unaffected — the words sit right above the box — which is exactly why
 * it survived: there is no visual symptom at all. A screen reader announces
 * "number edit" and nothing else, and the shop owner using one has no way to
 * tell which of the fifty-six number boxes on that screen they are in.
 *
 * `placeholder` is not the missing name. It is not an accessible name, and it
 * disappears the moment anything is typed, so it fails precisely when a name is
 * most needed. WCAG 2.1 1.3.1, 3.3.2 and 4.1.2.
 *
 * 181 controls were affected. `test:e2e:a11y` was green throughout, and was
 * right to be: it checks that a keyboard can REACH the controls, which is a
 * different property from their being named. A guard absent rather than broken,
 * and therefore silent — the shape this codebase keeps finding.
 *
 * This asserts the STRUCTURE rather than a count. A count would have to be
 * edited every time a field is added, and the edit that raises it is the edit
 * that should have failed.
 */

const ENTRY_POINTS = ['renderer/index.html', 'renderer/bedready.html'];

/**
 * A `<label>` carrying no `for=`, immediately followed by a control with an id.
 *
 * TEMPERED ON PURPOSE. The obvious `[\s\S]*?` for the label body backtracks
 * straight past `</label>` and pairs a label with a control hundreds of lines
 * further down — it reported a credit-card checkbox as the label for the
 * minimum-margin box. A fixer built on that pattern does not merely miss the
 * defect, it WRITES A WRONG NAME, which is worse than the missing one. So the
 * body cannot cross its own closing tag, and the gap to the control is
 * whitespace with no element in it.
 */
const ORPHANED = new RegExp(
  '<label\\b((?:(?!\\bfor\\s*=)[^>])*)>' +
  '((?:(?!</label>)[\\s\\S])*?)' +
  '</label>' +
  '([ \\t]*\\n?[ \\t]*)' +
  '<(input|select|textarea)\\b' +
  '((?:(?!>)[^>])*?)\\bid\\s*=\\s*"([^"]+)"' +
  '((?:(?!>)[^>])*)>',
  'gi');

for (const page of ENTRY_POINTS) {
  test(`${page}: a label sitting on a control names it`, () => {
    const html = fs.readFileSync(path.join(__dirname, '..', page), 'utf8');
    ORPHANED.lastIndex = 0;
    const orphans = [...html.matchAll(ORPHANED)]
      // A hidden input has nothing to name, so a label above one is not this defect.
      .filter((m) => !/type\s*=\s*"?hidden/i.test(m[5] + m[7]))
      // A label that already WRAPS a control names that one; it is not an orphan.
      .filter((m) => !/<(input|select|textarea)\b/i.test(m[2]))
      .map((m) => m[6]);

    assert.deepEqual(orphans, [],
      `${orphans.length} control(s) in ${page} sit under a <label> that does not name them. `
      + `Add for="<id>" to the label. Affected ids: ${orphans.slice(0, 8).join(', ')}`
      + `${orphans.length > 8 ? ` (and ${orphans.length - 8} more)` : ''}`);
  });
}

/**
 * The inverse, so the fix cannot be undone by deleting ids rather than labels:
 * every `for=` must point at an element that exists on the page.
 */
for (const page of ENTRY_POINTS) {
  test(`${page}: every for= points at a real control`, () => {
    const html = fs.readFileSync(path.join(__dirname, '..', page), 'utf8');
    const ids = new Set([...html.matchAll(/\bid\s*=\s*"([^"]+)"/g)].map((m) => m[1]));
    const dangling = [...html.matchAll(/<label\b[^>]*\bfor\s*=\s*"([^"]+)"/gi)]
      .map((m) => m[1])
      .filter((target) => !ids.has(target));
    assert.deepEqual(dangling, [],
      `label for= names ${dangling.length} id(s) that are not on the page: ${dangling.slice(0, 8).join(', ')}`);
  });
}
