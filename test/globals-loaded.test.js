const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { audit, findDefinitions, scriptsIn, isFlavourOwned } = require('../scripts/check-globals-loaded.js');

/**
 * The bug this catches never throws and never fails a unit test: a renderer
 * global that nothing loads simply is not there, and every guarded read of it
 * quietly takes the fallback. It has appeared three times in a week (#578, #581,
 * and my own #587).
 *
 * The delicate part is that a guarded read of a MISSING global is also exactly
 * what correct flavour gating looks like. These pin down the distinction: it is
 * the owner's location that decides, not the call site.
 */

/** Build a throwaway repo-shaped tree and audit it. */
function withTree(files, fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-globals-'));
  const cwd = process.cwd();
  try {
    for (const [rel, body] of Object.entries(files)) {
      const p = path.join(root, rel);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, body);
    }
    process.chdir(root);
    return fn(root);
  } finally {
    process.chdir(cwd);
    fs.rmSync(root, { recursive: true, force: true });
  }
}

const page = (...srcs) =>
  `<html><body>${srcs.map((s) => `<script src="${s}"></script>`).join('')}</body></html>`;

test('a global whose owner IS loaded raises nothing', () => {
  withTree({
    'lib/thing.js': 'globalThis.KhaytThing = {};',
    'renderer/user.js': 'if (typeof KhaytThing !== "undefined") KhaytThing.go();',
    'renderer/index.html': page('../lib/thing.js', 'user.js'),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    assert.deepEqual(audit('renderer/index.html', defs).violations, []);
  });
});

test('a global whose owner is NOT loaded is reported', () => {
  // #587 exactly: the reference was guarded, so it failed silently forever.
  withTree({
    'lib/thing.js': 'globalThis.KhaytThing = {};',
    'renderer/user.js': 'if (typeof KhaytThing !== "undefined") KhaytThing.go();',
    'renderer/index.html': page('user.js'),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    const v = audit('renderer/index.html', defs).violations;
    assert.equal(v.length, 1);
    assert.equal(v[0].global, 'KhaytThing');
    assert.equal(v[0].owner, 'lib/thing.js');
    assert.equal(v[0].user, 'renderer/user.js');
  });
});

test('a flavour-owned global may be absent — that is the gating pattern', () => {
  // window.KhaytBedReadyUI?.init?.() in a shared file is correct: Khayt does
  // not load Bed Ready's UI. Structurally identical to the bug above, so the
  // owner's location is what has to decide.
  withTree({
    'renderer/bedready/ui.js': 'window.KhaytBedReadyUI = {};',
    'renderer/shared.js': 'window.KhaytBedReadyUI?.init?.();',
    'renderer/index.html': page('shared.js'),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    assert.deepEqual(audit('renderer/index.html', defs).violations, []);
  });
  assert.equal(isFlavourOwned('renderer/bedready/ui.js'), true);
  assert.equal(isFlavourOwned('lib/estimate-calibration.js'), false);
});

test('all four assignment idioms in this codebase are recognised', () => {
  withTree({
    'lib/a.js': 'globalThis.KhaytA = 1;',
    'lib/b.js': 'window.KhaytB = 1;',
    'lib/c.js': '(function (g) { g.KhaytC = 1; })(globalThis);',
    'lib/d.js': 'Object.assign(global, { KhaytD: 1 });',
    'renderer/index.html': page(),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    for (const g of ['KhaytA', 'KhaytB', 'KhaytC', 'KhaytD']) {
      assert.ok(defs.has(g), `${g} should be recognised as defined`);
    }
  });
});

test('a global nothing in the repo defines is not our business', () => {
  // Could come from a dependency or a preload bridge; guessing would be noise.
  withTree({
    'renderer/user.js': 'KhaytSomethingElse.go();',
    'renderer/index.html': page('user.js'),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    assert.deepEqual(audit('renderer/index.html', defs).violations, []);
  });
});

test('remote script tags are ignored, not resolved as files', () => {
  withTree({
    'renderer/index.html': '<script src="https://cdn.example.com/x.js"></script><script src="a.js"></script>',
    'renderer/a.js': '',
  }, () => {
    const s = scriptsIn('renderer/index.html');
    assert.deepEqual([...s], ['renderer/a.js']);
  });
});

test('one missing global used by three files is reported once per file', () => {
  withTree({
    'lib/thing.js': 'globalThis.KhaytThing = {};',
    'renderer/a.js': 'KhaytThing;', 'renderer/b.js': 'KhaytThing;',
    'renderer/index.html': page('a.js', 'b.js'),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    const v = audit('renderer/index.html', defs).violations;
    assert.equal(v.length, 2, 'each call site is a separate thing to fix');
    assert.deepEqual(v.map((x) => x.user).sort(), ['renderer/a.js', 'renderer/b.js']);
  });
});

test('repeated references within one file are reported once', () => {
  withTree({
    'lib/thing.js': 'globalThis.KhaytThing = {};',
    'renderer/a.js': 'KhaytThing; KhaytThing; KhaytThing;',
    'renderer/index.html': page('a.js'),
  }, () => {
    const defs = findDefinitions(['lib', 'renderer']);
    assert.equal(audit('renderer/index.html', defs).violations.length, 1);
  });
});

test('the real Khayt entry point is clean', () => {
  // The regression this guard exists to prevent. If this fails, a feature in
  // Khayt is silently absent.
  const defs = findDefinitions(['lib', 'renderer']);
  const { violations } = audit('renderer/index.html', defs);
  assert.deepEqual(
    violations.map((v) => `${v.global} (${v.owner}) used by ${v.user}`),
    [],
  );
});
