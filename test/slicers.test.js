'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { listSlicers, defaultSlicer, getSlicer, slicerDisplayName, isAllowedSlicerBinary } = require('../lib/slicers');

test('slicerDisplayName: friendly names from exe paths', () => {
  assert.equal(slicerDisplayName('/Applications/PrusaSlicer.app'), 'PrusaSlicer');
  assert.equal(slicerDisplayName('C:/Program Files/OrcaSlicer/orca-slicer.exe').toLowerCase().includes('orca'), true);
  assert.equal(slicerDisplayName('/opt/BambuStudio.AppImage'), 'Bambu Studio');
  assert.equal(slicerDisplayName('/usr/bin/some-custom-tool'), 'some-custom-tool');
  assert.equal(slicerDisplayName(''), '');
});

test('listSlicers: prefers settings.slicers, drops path-less entries', () => {
  const s = { slicers: [
    { id: 'a', name: 'Prusa', path: '/p/prusa' },
    { name: 'NoPath' },                      // dropped (no path)
    { path: '/p/orca.exe' },                 // id + name derived
  ] };
  const list = listSlicers(s);
  assert.equal(list.length, 2);
  assert.equal(list[0].id, 'a');
  assert.equal(list[1].id, 'sl1');           // index-based id (post-filter position)
  assert.ok(list[1].name.length > 0);        // name derived from path
});

test('listSlicers: falls back to legacy single settings.slicer', () => {
  assert.deepEqual(listSlicers({ slicer: { path: '/p/PrusaSlicer.app', args: '-x' } }),
    [{ id: 'default', name: 'PrusaSlicer', path: '/p/PrusaSlicer.app', args: '-x' }]);
  assert.deepEqual(listSlicers({}), []);
  assert.deepEqual(listSlicers({ slicer: {} }), []);
});

test('defaultSlicer: honours defaultSlicerId, else first, else null', () => {
  const s = { slicers: [{ id: 'a', path: '/a' }, { id: 'b', path: '/b' }], defaultSlicerId: 'b' };
  assert.equal(defaultSlicer(s).id, 'b');
  assert.equal(defaultSlicer({ slicers: [{ id: 'a', path: '/a' }, { id: 'b', path: '/b' }] }).id, 'a');
  assert.equal(defaultSlicer({}), null);
});

test('getSlicer: by id or null', () => {
  const s = { slicers: [{ id: 'a', path: '/a' }, { id: 'b', path: '/b' }] };
  assert.equal(getSlicer(s, 'b').path, '/b');
  assert.equal(getSlicer(s, 'zzz'), null);
});

test('isAllowedSlicerBinary: accepts real slicers across platforms', () => {
  const ok = [
    '/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer',
    '/Applications/OrcaSlicer.app', 'C:/Program Files/OrcaSlicer/orca-slicer.exe',
    '/opt/BambuStudio.AppImage', '/usr/bin/UltiMaker-Cura', '/Applications/SuperSlicer.app',
    '/opt/Slic3r', '/Applications/QIDIStudio.app', '/opt/CrealityPrint',
    '/Applications/CHITUBOX.app', '/opt/ElegooSlicer', '/Applications/Snapmaker Orca.app/Contents/MacOS/Snapmaker_Orca',
    '/usr/local/bin/ideaMaker', '/opt/FlashPrint', '/opt/KISSlicer', '/opt/IceSL',
  ];
  for (const p of ok) assert.equal(isAllowedSlicerBinary(p), true, `should allow ${p}`);
});

test('isAllowedSlicerBinary: rejects living-off-the-land binaries (RCE guard)', () => {
  // A poisoned settings.slicers[] snapshot must not turn any of these into command
  // execution. None is a shell, so the old interpreter denylist let them through.
  const bad = [
    '/usr/bin/find', '/usr/bin/awk', '/usr/bin/gawk', '/usr/bin/xargs', '/usr/bin/gdb',
    '/usr/bin/make', '/usr/bin/tclsh', '/usr/bin/lua', '/bin/busybox', '/usr/bin/git',
    '/usr/bin/zip', '/usr/bin/tar', '/usr/bin/ssh', '/usr/bin/vim', '/usr/bin/expect',
    '/bin/bash', '/usr/bin/python3', '/usr/bin/node', '/usr/bin/perl', '/usr/bin/env',
    'C:/Windows/System32/cmd.exe', 'C:/Windows/System32/rundll32.exe',
    '', '/', '   ', '/usr/bin/', '/usr/local/bin/totally-legit',
  ];
  for (const p of bad) assert.equal(isAllowedSlicerBinary(p), false, `should reject ${p}`);
});

/**
 * THE GUARD HAS TO BE THE ONE THAT IS CALLED.
 *
 * `isAllowedSlicerBinary` above shipped with its reasoning and both of those
 * tests, and for as long as it existed **nothing called it**. Every one of the
 * three places that launch a slicer used a denylist of interpreter names in
 * main.js instead — the very thing the comment on the module says cannot work —
 * so `awk`, `find`, `xargs`, `gdb`, `make`, `tclsh`, `busybox`, `git` and
 * `expect` were all accepted as slicers from a settings blob that can arrive in
 * a restored backup or a cloud sync.
 *
 * A passing test on an uncalled function is worth nothing. This is the test
 * that would have caught it.
 */
test('main.js launches slicers through the shared allowlist, and keeps no second opinion', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

  assert.match(main, /require\('\.\/lib\/slicers'\)/,
    'main.js must reach the shared module');
  assert.match(main, /\bisAllowedSlicerBinary\b/,
    'main.js must use the allowlist by name');

  // The denylist and its Set are gone, not merely unused: a dead one beside a
  // live one is an invitation to call the wrong thing next time.
  assert.doesNotMatch(main, /isSafeSlicerBinary/,
    'the denylist guard must be gone from main.js');
  assert.doesNotMatch(main, /DISALLOWED_SLICER_BINARIES/,
    'the interpreter denylist must be gone from main.js');

  // Every spawn of a slicer is gated. Three call sites today; the count is
  // asserted so a fourth added without a guard shows up here.
  const guarded = main.match(/isAllowedSlicerBinary\(/g) || [];
  assert.ok(guarded.length >= 4,
    `expected the allowlist at every slicer call site, found ${guarded.length}`);

  // And the scanner that OFFERS slicers asks the same question, rather than
  // carrying its own copy of the token list. Two copies is how a shop is shown
  // a slicer that the guard then refuses to launch.
  assert.doesNotMatch(main, /SLICER_APP_RE\s*=/,
    'the scanner must not keep a second token list');
});

/**
 * ── THE ARGV A SLICER IS ACTUALLY LAUNCHED WITH ────────────────────────────
 *
 * `settings.slicers[].args` is untrusted — it arrives in a restored backup or
 * a cloud sync, like the path beside it that `isAllowedSlicerBinary` guards.
 * `spawn` runs with `shell:false`, so metacharacters cannot reach a shell, but
 * the SPLIT still decides what becomes a separate argument.
 *
 * This lived in `main.js` with no test and no second reader. The Mac needs the
 * same split to launch the same slicer, and a Swift copy of a security
 * decision is the divergence `lib/` exists to prevent. Copied here verbatim
 * from where it stood, and compared.
 */
const S = require('../lib/slicers');

function originalTokenize(template) {
  const out = []; let cur = ''; let q = null; let has = false;
  for (const ch of String(template || '')) {
    if (q) { if (ch === q) q = null; else { cur += ch; has = true; } }
    else if (ch === '"' || ch === "'") { q = ch; has = true; }
    else if (/\s/.test(ch)) { if (has) { out.push(cur); cur = ''; has = false; } }
    else { cur += ch; has = true; }
  }
  if (has) out.push(cur);
  return out;
}

test('the split is the one main.js used, character for character', () => {
  const templates = [
    '--export-gcode -o {output} {model}',
    '', null, undefined, '   ',
    '--load "my profile.ini" -o {output} {model}',
    "--load 'a b.ini' {model}",
    '--single   --spaced\t--tabbed\n--newlined',
    '"" -o {output}',
    'unclosed "quote {model}',
    "mixed'quotes\"here",
    '--flag={model}',
  ];
  for (const t of templates) {
    assert.deepEqual(S.tokenizeSliceArgs(t), originalTokenize(t), JSON.stringify(t));
  }
});

test('placeholders are filled AFTER the split, so a path with a space stays one argument', () => {
  const argv = S.sliceArgv('-o {output} {model}', {
    model: '/Users/x/My Models/dragon.stl',
    output: '/tmp/out dir/out.gcode',
  });
  assert.deepEqual(argv, ['-o', '/tmp/out dir/out.gcode', '/Users/x/My Models/dragon.stl']);

  // A path chosen to look like an argument cannot become one: it is filled
  // into an already-final token.
  const nasty = S.sliceArgv('-o {output} {model}', {
    model: 'a.stl --load /etc/evil.ini',
    output: '/tmp/o.gcode',
  });
  assert.equal(nasty.length, 3);
  assert.equal(nasty[2], 'a.stl --load /etc/evil.ini');

  // A quote in a path cannot close one either.
  const quoted = S.sliceArgv('{model}', { model: 'x" --foo "y.stl' });
  assert.deepEqual(quoted, ['x" --foo "y.stl']);
});

test('no template is the documented default, and every placeholder is understood', () => {
  assert.equal(S.DEFAULT_SLICE_ARGS, '--export-gcode -o {output} {model}');
  assert.deepEqual(S.sliceArgv(null, { model: 'm.stl', output: 'o.gcode' }),
    ['--export-gcode', '-o', 'o.gcode', 'm.stl']);
  assert.deepEqual(S.sliceArgv('{outdir} {model} {output}', { model: 'm', output: 'o', outdir: 'd' }),
    ['d', 'm', 'o']);
  // An unsupplied placeholder becomes empty rather than staying a literal
  // `{model}` that a slicer would try to open.
  assert.deepEqual(S.sliceArgv('{model}', {}), ['']);
});

test('main.js builds its argv from the shared rule, not its own copy', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.ok(src.includes('sliceArgv(args, {'), 'runSlice no longer asks the shared rule');
  assert.ok(!src.includes('function tokenizeSliceArgs'), 'main.js has its own tokenizer again');
});
