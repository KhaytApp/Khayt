const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

/**
 * Renderer files load as classic <script> tags and most are IIFE-wrapped. Anything
 * declared inside the IIFE and NOT placed in that file's exported `api` is module-scoped:
 * another file referencing it gets a ReferenceError at runtime (or, for a bare assignment
 * in sloppy mode, silently creates a stray global that nothing reads).
 *
 * Unit tests never caught this class because the references live in boot wiring and
 * timers. Real instances found: `globalSearchOpen` (every keystroke threw and Cmd+K never
 * opened search) and `buildDigestEmailHtml` (the scheduled digest email never sent, retried
 * every 5 minutes forever). Five more were `typeof`-guarded, so the guard was permanently
 * false and the feature silently dead — including an accounting retry that never ran.
 *
 * This test pins the identifiers that are known to be referenced across files.
 */
const root = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(root, 'renderer', f), 'utf8');

// name → the file that must export it (verified cross-file references).
const MUST_EXPORT = {
  'settings.js':  ['buildDigestEmailHtml'],
  'expenses.js':  ['retryFailedAccountingPushes'],
  'machines.js':  ['MACHINE_COLORS'],
  'shell.js':     ['wireFormLabels', 'isGlobalSearchOpen'],
  'online.js':    ['copyOnlineIntakeUrl'],
  'inventory.js': ['partGramsConsumed'],
};

test('identifiers referenced across renderer files are actually exported', () => {
  for (const [file, names] of Object.entries(MUST_EXPORT)) {
    const src = read(file);
    // The exported surface: the last `const api = { ... }` literal in the file.
    const start = src.lastIndexOf('const api = {');
    assert.ok(start !== -1, `${file}: no api object found`);
    const apiBlock = src.slice(start, src.indexOf('};', start));
    for (const name of names) {
      assert.ok(
        new RegExp(`(^|[\\s{,])${name}\\s*[,:]`).test(apiBlock),
        `${file} does NOT export ${name}, but another renderer file references it — ` +
        `at runtime that is a ReferenceError, or a silently dead typeof-guarded branch.`,
      );
    }
  }
});

test('no renderer file assigns to another file’s module-scoped binding', () => {
  // `calendarViewMonth = null` in wire-events.js targeted views.js's IIFE-private `let`.
  // In sloppy mode that creates a NEW global instead of resetting the real one, so the
  // calendar reopened on a stale month.
  const wireEvents = read('wire-events.js');
  assert.ok(
    !/^\s*calendarViewMonth\s*=/m.test(wireEvents),
    'wire-events.js assigns calendarViewMonth directly; call the exported reset instead',
  );
});
