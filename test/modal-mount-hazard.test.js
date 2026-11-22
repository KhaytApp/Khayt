/**
 * A modal opened inside onSave is destroyed by the close that follows it.
 *
 * `openFormModal` (renderer/shell.js) renders into ONE shared `#modalMount`, and
 * its private close() does `mount.innerHTML = ''`. The save handler is:
 *
 *     const result = await onSave(modal);
 *     if (result !== false) close();
 *
 * So any modal opened from inside onSave is wiped the instant onSave returns
 * true. Nothing throws. The second modal simply never appears.
 *
 * This is not hypothetical: it was written after the organisation flow did
 * exactly that and silently swallowed the org RECOVERY KEY — shown once, never
 * re-issued, and the only spare way into every branch. Running the app is what
 * found it; no unit test could have, because the code was correct in isolation.
 *
 * The fix is to defer past the close (`setTimeout(..., 0)`) or to open the modal
 * from a plain click handler instead, which is what the shop signup already does.
 *
 * WHAT THIS GUARD CANNOT SEE
 *
 * It reads one onSave body at a time, so it only catches a modal opened INSIDE
 * that body. The same trap fires one level of indirection deeper: an onSave that
 * resolves a promise, whose CONSUMER opens a modal, still races the close — which
 * is exactly how the organisation overview came to open and vanish. Following
 * that statically would mean tracking a promise across functions, which is a type
 * checker's job, not a regex's.
 *
 * So: this catches the common shape, and the uncommon one is still found by
 * running the app. Written down because a guard that is quietly incomplete is
 * worse than one that says where it stops.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', 'renderer');
const FILES = fs.readdirSync(DIR).filter((f) => f.endsWith('.js'));

/**
 * Bodies of every `onSave(...) { ... }` / `onSave: async (...) => { ... }`.
 * Brace-matched rather than regex-bounded, so a nested block cannot end it early.
 */
function onSaveBodies(src) {
  const out = [];
  const re = /onSave\s*:?\s*(?:async\s*)?\(?[^)\n]*\)?\s*=>\s*\{|onSave\s*\(([^)]*)\)\s*\{/g;
  let m;
  while ((m = re.exec(src))) {
    let i = src.indexOf('{', m.index + m[0].length - 1);
    if (i === -1) continue;
    let depth = 0;
    let j = i;
    for (; j < src.length; j++) {
      if (src[j] === '{') depth++;
      else if (src[j] === '}') { depth--; if (depth === 0) break; }
    }
    out.push({ body: src.slice(i, j + 1), at: src.slice(0, m.index).split('\n').length });
  }
  return out;
}

test('no onSave opens another modal and then returns true', () => {
  const offenders = [];
  let scanned = 0;
  for (const f of FILES) {
    const src = fs.readFileSync(path.join(DIR, f), 'utf8');
    for (const { body, at } of onSaveBodies(src)) {
      scanned++;
      // Only the synchronous path matters: a deferred open lands after close().
      // `confirmModal` is deliberately NOT in this list. It is awaited to
      // completion — its own cleanup removes the overlay before the promise
      // resolves — so by the time `return true` runs there is nothing left to
      // wipe. Three call sites do exactly that and are correct. Flagging them
      // would have made this guard noise, and noise gets suppressed.
      const opensModal = /\b(?:show[A-Z]\w*Modal|openFormModal|appendStackedModal)\s*\(/.test(
        body.replace(/setTimeout\([\s\S]*?\);/g, ''),   // deferring is the fix, not the bug
      );
      const returnsTrue = /return\s+true\s*;/.test(body);
      if (opensModal && returnsTrue) offenders.push(`${f}:${at}`);
    }
  }
  assert.ok(scanned >= 10, `only found ${scanned} onSave handlers — the extraction broke, this test is blind`);
  assert.deepEqual(offenders, [],
    'these open a modal inside onSave and then return true, which empties the shared mount and destroys it');
});

test('the check can actually see the hazard it is looking for', () => {
  // A test that can only pass is not a test. Feed it the exact broken shape.
  const broken = `
    openFormModal({
      onSave: async (modal) => {
        const r = await doWork();
        showOrgRecoveryKeyModal(r.recoveryKey);
        return true;
      },
    });`;
  const bodies = onSaveBodies(broken);
  assert.equal(bodies.length, 1, 'the extractor found the handler');
  assert.match(bodies[0].body, /showOrgRecoveryKeyModal\(/);
  assert.match(bodies[0].body, /return\s+true\s*;/);

  // And the fixed shape must NOT look like the hazard.
  const fixed = broken.replace('showOrgRecoveryKeyModal(r.recoveryKey);',
    'setTimeout(() => showOrgRecoveryKeyModal(r.recoveryKey), 0);');
  const fixedBody = onSaveBodies(fixed)[0].body.replace(/setTimeout\([\s\S]*?\);/g, '');
  assert.ok(!/show[A-Z]\w*Modal\s*\(/.test(fixedBody), 'a deferred open is not flagged');
});
