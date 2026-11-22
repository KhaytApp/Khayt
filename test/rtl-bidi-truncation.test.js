const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

/**
 * `text-overflow: ellipsis` clips at the END edge of the container's OWN direction.
 * In an RTL locale that edge is on the left, so an English job name inside an Arabic
 * card truncated backwards — "…ousing batch" instead of "Gearbox hous…".
 *
 * Measured in a headless browser before fixing, because the intuitive fix is wrong:
 *
 *   no isolation          → head clipped, tail kept   ← the bug
 *   <bdi> wrapper         → head clipped, tail kept   ← STILL BROKEN
 *   dir="auto"            → correct, but flips computed direction to ltr
 *   unicode-bidi:plaintext→ correct, direction stays rtl   ← what we ship
 *
 * `<bdi>` fails because it isolates the inline run for reordering, while the ellipsis
 * is applied by the block container. Anyone "simplifying" this to <bdi> reintroduces
 * the bug invisibly — it only shows in an RTL locale with a Latin-named job.
 */

// Strip comments first — a prose comment sitting above a rule otherwise gets swept into
// that rule's selector list, and any comma inside it shreds the parse.
const css = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'styles.css'), 'utf8',
).replace(/\/\*[\s\S]*?\*\//g, '');

// Every one of these truncates a USER-SUPPLIED string — job, machine, client, file,
// path — so its script is not knowable from the UI language.
const USER_TEXT_SELECTORS = [
  '.dash-hero-name', '.dash-printer-name', '.dash-printer-job', '.ch-name',
  '.wa-tpl-preview', '.part-status-name', '.schedule-machine-label', '.schedule-block',
  '.quote-title', '.pf-name', '.cs-row-name', '.cs-plan-name', '.slicer-path',
  '.conv-batch-name', '.conv-cp-sub', '.pf-conv-name', '.cal-chip',
  '.vault-file-row .vf-name', '.attached-file-row .attached-file-name',
];

/** The selector list of every rule block whose body declares `unicode-bidi: plaintext`. */
function plaintextSelectors(source) {
  const out = [];
  const re = /([^{}]+)\{([^}]*)\}/g;
  let m;
  while ((m = re.exec(source))) {
    if (/unicode-bidi\s*:\s*plaintext/.test(m[2])) {
      out.push(...m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' ')));
    }
  }
  return out;
}

test('every truncated user-supplied string is bidi-isolated', () => {
  const isolated = new Set(plaintextSelectors(css));
  const missing = USER_TEXT_SELECTORS.filter((s) => !isolated.has(s));
  assert.deepEqual(missing, [],
    `these truncate user text but would clip the wrong end in RTL: ${missing.join(', ')}`);
});

test('the isolation is unicode-bidi, not a <bdi> wrapper', () => {
  // <bdi> measurably does NOT fix ellipsis direction; see the header comment.
  // Guards against a future "cleanup" that swaps one for the other.
  for (const sel of USER_TEXT_SELECTORS) {
    assert.ok(plaintextSelectors(css).includes(sel), `${sel} lost its unicode-bidi rule`);
  }
});

test('every isolated selector also gets an explicit RTL alignment', () => {
  // `plaintext` resolves alignment per line as well as direction, so a short
  // Latin name jumped LEFT while its Arabic neighbours stayed right — a ragged
  // column edge. Measured: `text-align: start` does not fix it; the alignment
  // must be physical. Shipping the isolation without this is a half-fix.
  const rtlAligned = new Set();
  const re = /([^{}]+)\{([^}]*)\}/g;
  let m;
  while ((m = re.exec(css))) {
    if (/text-align\s*:\s*right/.test(m[2])) {
      for (const sel of m[1].split(',')) {
        const s = sel.trim().replace(/\s+/g, ' ');
        if (s.startsWith('[dir="rtl"] ')) rtlAligned.add(s.slice('[dir="rtl"] '.length));
      }
    }
  }
  const missing = USER_TEXT_SELECTORS.filter((s) => !rtlAligned.has(s));
  assert.deepEqual(missing, [],
    `isolated but not re-aligned, so these go ragged in Arabic: ${missing.join(', ')}`);
});

test('a new truncating name class is caught by this list, not by a user in Riyadh', () => {
  // If someone adds `.foo-name { text-overflow: ellipsis }` for user text and forgets
  // the isolation, nothing here fails — so this test documents the intake rule and
  // pins the count, forcing a conscious decision when the list grows.
  assert.equal(USER_TEXT_SELECTORS.length, 19,
    'add the new selector to USER_TEXT_SELECTORS (and give it unicode-bidi: plaintext) ' +
    'if it truncates user-supplied text, or bump this count if it truncates UI text');
});
