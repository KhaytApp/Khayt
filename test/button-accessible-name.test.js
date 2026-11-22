/**
 * Every button must say something to a screen reader.
 *
 * A button whose entire content is an icon — `🗑`, `×`, `⌫` — is a blank button
 * to anyone not looking at it. Nothing breaks, nothing throws, and the two found
 * when this check was written were both DELETE controls, which is the worst kind
 * to leave unlabelled: the user cannot tell it apart from any other unnamed
 * button until after they press it.
 *
 * The check works the way a screen reader does. It takes what is announced —
 * `aria-label`, `data-i18n-aria`, `aria-labelledby`, `title` — and otherwise
 * falls back to the visible text with markup, HTML entities, emoji and template
 * expressions stripped out. What remains is what a user actually hears. If that
 * is empty, the button has no name.
 *
 * Deliberately not an "accessibility test suite". It checks one thing that is
 * cheap to verify and expensive to get wrong, which is what makes it a guard
 * rather than an aspiration.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RENDERER = path.join(ROOT, 'renderer');

function sources() {
  const files = [];
  for (const html of ['index.html', 'bedready.html']) {
    const p = path.join(RENDERER, html);
    if (fs.existsSync(p)) files.push(p);
  }
  for (const f of fs.readdirSync(RENDERER)) {
    if (f.endsWith('.js')) files.push(path.join(RENDERER, f));
  }
  return files;
}

// Emoji, arrows, dingbats, the multiplication sign used as a close button, and
// the zero-width joiner — none of which a screen reader announces usefully.
const DECORATIVE = /[\u{1F300}-\u{1FAFF}\u{2190}-\u{2BFF}\u{FE0F}\u{200D}\u{00D7}\u{2026}]/gu;

/** What a screen reader would announce for this button, or '' if nothing. */
function accessibleName(attrs, inner) {
  if (/aria-label|data-i18n-aria|aria-labelledby|title=/.test(attrs)) return 'labelled';
  return inner
    .replace(/<[^>]*>/g, ' ')          // nested markup contributes its own text
    .replace(/&[a-z#0-9]+;/gi, ' ')    // &times; &nbsp; &#8230;
    .replace(/\$\{[^}]*\}/g, 'X')      // a template expression may well be text
    .replace(DECORATIVE, '')
    .trim();
}

function namelessButtons() {
  const out = [];
  for (const file of sources()) {
    const src = fs.readFileSync(file, 'utf8');
    for (const m of src.matchAll(/<button\b([^>]*)>([\s\S]{0,300}?)<\/button>/g)) {
      if (!accessibleName(m[1], m[2])) {
        out.push(`${path.basename(file)}: ${m[0].slice(0, 100).replace(/\s+/g, ' ')}`);
      }
    }
  }
  return out;
}


/** What a sighted user can read on the button itself — icons and markup removed. */
function visibleText(inner) {
  return String(inner || '')
    .replace(/<span[^>]*aria-hidden="true"[^>]*>[\s\S]*?<\/span>/g, '')
    .replace(/\$\{[^}]*(svg|_mIco|ico)[^}]*\}/gi, '')
    .replace(/<svg[\s\S]*?<\/svg>/g, '')
    .replace(/<[^>]+>/g, '')
    .replace(/[\u{1F300}-\u{1FAFF}\u{2190}-\u{2BFF}\u{FE0F}\u{00D7}\u{2026}]/gu, '')
    .replace(/\$\{[^}]*\}/g, '')
    .trim();
}

test('no button is silent to a screen reader', () => {
  const nameless = namelessButtons();
  assert.deepEqual(nameless, [],
    `these buttons announce nothing:\n  ${nameless.join('\n  ')}`);
});

test('the check is actually looking at the buttons', () => {
  // Guards the guard. If the <button> regex or the source list ever stopped
  // matching, the test above would pass on an empty set and quietly protect
  // nothing — which is how the settings-export list drifted in the first place.
  let total = 0;
  for (const file of sources()) {
    total += [...fs.readFileSync(file, 'utf8').matchAll(/<button\b/g)].length;
  }
  assert.ok(total > 500, `expected the app's many buttons, scanned ${total}`);
});

test('an icon-only button is recognised as nameless, a labelled one is not', () => {
  // Pins the rule itself, so the emoji/entity stripping cannot silently relax.
  assert.equal(accessibleName('', '🗑'), '', 'a bare emoji says nothing');
  assert.equal(accessibleName('', '×'), '', 'nor does a multiplication sign');
  assert.equal(accessibleName('', '&times;'), '', 'nor its entity');
  assert.equal(accessibleName('', '⌫'), '', 'nor a backspace glyph');
  assert.ok(accessibleName('', 'Save'), 'plain text is a name');
  assert.ok(accessibleName('', '🗑 Delete'), 'an icon beside text is fine');
  assert.ok(accessibleName('aria-label="Delete"', '🗑'), 'an aria-label is a name');
  assert.ok(accessibleName('data-i18n-aria="common.delete"', '🗑'), 'and so is the i18n form');
});

test('an icon-only button also says what it does on hover', () => {
  /* `aria-label` is for a screen reader. It produces NO tooltip, so a sighted
   * shop hovering an icon gets nothing — reported as "when floating over a
   * button the description is not shown; it's confusing knowing what each
   * button does when it's only an icon".
   *
   * Fifty buttons were in that state, and the reason is visible in this file:
   * the test above enforces the accessible name and nothing enforced the
   * hover. Passing an accessibility check is not the same as being usable.
   *
   * `title` must match `aria-label`: for an icon-only button they state the
   * same fact, and two wordings would drift apart.
   */
  const missing = [];
  for (const file of sources()) {
    const src = fs.readFileSync(file, 'utf8');
    for (const m of src.matchAll(/<button([^>]*)>([\s\S]{0,200}?)<\/button>/g)) {
      const [, attrs, inner] = m;
      if (!/aria-label=/.test(attrs)) continue;
      if (visibleText(inner)) continue;          // has a label of its own
      if (/title=/.test(attrs)) continue;
      const line = src.slice(0, m.index).split('\n').length;
      missing.push(`${path.basename(file)}:${line}`);
    }
  }
  assert.deepEqual(missing, [],
    `these icon-only buttons show nothing on hover:\n  ${missing.join('\n  ')}`);
});
