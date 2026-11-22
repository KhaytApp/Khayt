'use strict';
/**
 * The design system's tokens still match the Mac app they were read out of.
 *
 * `design-system/` is a React mirror of the Mac app's vocabulary, uploaded to
 * Claude Design so the design agent builds with Khayt's own parts. Its colours,
 * card geometry, type scale and motion are GENERATED out of `Palette.swift`,
 * `Surface.swift`, `TypeScale.swift` and `Motion.swift` by
 * `.design-sync/extract-tokens.mjs`.
 *
 * ── WHAT THIS CATCHES THAT THE EXTRACTOR DOES NOT ──────────────────────────
 *
 * The extractor fails loudly when a value it reads is RENAMED or moved — that
 * is its whole design. What it cannot do is notice that nobody ran it. Change
 * a colour in `Palette.swift`, commit, and the generated stylesheet sitting in
 * `design-system/src/tokens/` still holds the old value; every design built in
 * Claude Design from then on is off-brand, and nothing says so.
 *
 * `.design-sync/NOTES.md` records that as a standing re-sync risk. This is the
 * half of it that can be mechanised: regenerate into a temp file and require
 * the committed stylesheet to match.
 *
 * ── WHAT IT STILL CANNOT CATCH ─────────────────────────────────────────────
 *
 * Only the token VALUES. If the Mac's card, board card or sidebar row changes
 * SHAPE, the mirror's components have to be updated by hand and no test
 * reports it. That limit is deliberate and written down; do not read a green
 * run here as "the mirror is current".
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.join(__dirname, '..');
const EXTRACTOR = path.join(ROOT, '.design-sync/extract-tokens.mjs');
const COMMITTED = path.join(ROOT, 'design-system/src/tokens/khayt.css');

test('the generated design tokens match the Swift they are read from', () => {
  // Skipped rather than failed where the design system is not checked out —
  // the sync inputs are committed, but a sparse checkout is a real thing and
  // a guard that cannot run should say so rather than invent a failure.
  if (!fs.existsSync(EXTRACTOR) || !fs.existsSync(COMMITTED)) {
    assert.ok(true, 'design-system is not present in this checkout');
    return;
  }

  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-tokens-')), 'khayt.css');
  execFileSync(process.execPath, [EXTRACTOR, '--out', out], { cwd: ROOT, stdio: 'pipe' });

  const fresh = fs.readFileSync(out, 'utf8');
  const committed = fs.readFileSync(COMMITTED, 'utf8');
  fs.rmSync(path.dirname(out), { recursive: true, force: true });

  // Not vacuous: the generated file really does carry the tokens.
  assert.match(fresh, /--khayt-brand:/, 'the extractor produced no colours');
  assert.match(fresh, /--khayt-motion-hover:/, 'the extractor produced no motion');

  assert.equal(fresh, committed,
    'design-system/src/tokens/khayt.css is stale — a design source in '
    + 'mac/KhaytCore/Sources/KhaytApp/ changed and the tokens were not '
    + 'regenerated. Run:\n'
    + '  node .design-sync/extract-tokens.mjs\n'
    + 'then rebuild and re-sync per .design-sync/NOTES.md. Every design built '
    + 'in Claude Design until then is off-brand.');
});

test('every Swift source the tokens come from is still there', () => {
  if (!fs.existsSync(EXTRACTOR)) { assert.ok(true, 'not present'); return; }
  // Named so that MOVING one of these is a failure here rather than a silent
  // change of meaning inside the extractor's regexes.
  for (const file of ['Palette.swift', 'Surface.swift', 'TypeScale.swift', 'Motion.swift']) {
    assert.ok(fs.existsSync(path.join(ROOT, 'mac/KhaytCore/Sources/KhaytApp', file)),
      `${file} is where design tokens are read from and it is not there any more`);
  }
});
