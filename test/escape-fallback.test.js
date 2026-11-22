const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

/**
 * A helper called `esc` must never be a pass-through.
 *
 * Both of these used to fall back to the RAW string when the `escapeHtml`
 * global was missing. That is a guard that silently becomes a non-guard — the
 * shape of most of what the 2026-08-27 audits found, and the worst shape for a
 * security helper, because the call site still reads as escaped.
 *
 * The global IS always loaded in the app and `check:globals` enforces it, so
 * this was never reachable in production. It is pinned anyway: the reason it
 * was safe lives in another file's load order, which is not a property this
 * function should depend on.
 */
const root = path.join(__dirname, '..');

for (const file of ['renderer/calibration.js', 'renderer/queue-list.js']) {
  test(`${file}: esc() escapes even with no escapeHtml global`, () => {
    const src = fs.readFileSync(path.join(root, file), 'utf8');
    // Sliced rather than regex-matched with a length cap: the first version of
    // this test capped the match at 700 characters and broke the moment the
    // function grew a comment, which is a test failing for a reason unrelated
    // to what it checks.
    const start = src.search(/(?:const esc = |function esc)/);
    assert.notEqual(start, -1, 'esc() found');
    const end = src.indexOf('\n  }', start);
    assert.notEqual(end, -1, 'esc() body is delimited as expected');
    const body = src.slice(start, end);
    // The fallback branch must transform, not return the input untouched.
    assert.match(body, /&amp;/, 'the fallback escapes & itself');
    assert.match(body, /&lt;/, 'and <');
    assert.match(body, /&quot;|&#39;/, 'and at least one quote form');
    assert.ok(
      !/:\s*String\(s\s*(\?\?|==)/.test(body),
      'no branch returns the raw string',
    );
  });
}

test('the fallback actually neutralises a script tag', () => {
  // Executed rather than pattern-matched: the branch is lifted out and run with
  // no global in scope, which is the condition it exists for.
  const src = fs.readFileSync(path.join(root, 'renderer/queue-list.js'), 'utf8');
  const m = src.match(/function esc\(s\) \{[\s\S]*?\n  \}/);
  const fn = new Function(`${m[0]}; return esc;`)();
  const out = fn('<script>alert(1)</script>');
  assert.ok(!out.includes('<script>'), `still raw: ${out}`);
  assert.equal(out, '&lt;script&gt;alert(1)&lt;/script&gt;');
});
