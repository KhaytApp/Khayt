/**
 * A model's identity must not be computed as a side effect of drawing its picture.
 *
 * geometryKey is the ONLY key that still recognises a model after it has been
 * re-sliced. The other two do not survive it:
 *
 *   contentHash  hashes the file's bytes, and re-slicing changes them
 *   fileRef      is the filename, and a slicer that writes its own time estimate
 *                into it (SnapmakerOrca: MBS-ART-200mm-U1_PLA_5h36m.gcode)
 *                changes that too — the same model came back as _5h41m and
 *                _5h38m across three prints in the maintainer's own history
 *
 * So when geometryKey goes missing, per-file calibration silently falls back to
 * the machine-wide median, and every quote for that model is priced off the
 * shop's average mix instead of the model's own measured history. Nothing errors;
 * the number is just wrong. Measured on real data that fallback misquoted by
 * -21% on a tall part and +27% on a flat one.
 *
 * enrichPrintFile() used to compute it inside a block guarded by `!rec.thumb`
 * and by the presence of the thumbnail RENDERER, so a file that already had a
 * picture, or a flavour shipping without stl-thumbnail.js, got no key.
 *
 * Neither guard was failing when this was written — both call sites pass a fresh
 * record with thumb:null, and both HTML entry points load stl-thumbnail.js. This
 * is the same latent shape as the bug the source comment records having already
 * shipped once in this exact block, pinned before it costs anything rather than
 * after.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'printfiles.js'), 'utf8');

/** The body of one function, by name, matched on braces. */
function fn(name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start > -1, `${name}() not found in renderer/printfiles.js`);
  const open = src.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error(`could not find the end of ${name}()`);
}

const enrich = fn('enrichPrintFile');

/**
 * The `if (...)` condition that opens the STL branch.
 *
 * Paren-matched rather than `[^)]*`, which stopped at the first inner `)` and
 * silently returned half a condition — so `if ((ext === 'stl' || ext === 'obj')
 * && hub.parsePrintFile)` came back as `(ext === 'stl' || ext === 'obj'` and
 * every assertion about what the guard does NOT mention passed for free.
 */
function stlGuard(body) {
  /* Anchored from the CONDITION back to its own `if`, not forward from an `if`
   * to a condition.
   *
   * This searched `/if \([^{]*ext === 'stl'/` — "an `if (` with no brace between
   * it and the test". Whether that finds the right `if` depends on how many
   * braces happen to sit between the two, so removing a pair of braces from an
   * unrelated statement above it silently re-anchored the match to an earlier
   * `if` and the guard started reading a different condition entirely. That is
   * what happened when the thumbnail write became a one-line call.
   *
   * Second time this helper has been wrong in a way that changed what it was
   * checking rather than failing outright, so: find the thing, then find the
   * `if` that owns it. */
  const cond = body.indexOf("ext === 'stl'");
  assert.ok(cond > -1, 'no STL branch found in enrichPrintFile()');
  const at = body.lastIndexOf('if (', cond);
  assert.ok(at > -1, "found `ext === 'stl'` with no `if` before it");
  const open = body.indexOf('(', at);
  let depth = 0;
  for (let i = open; i < body.length; i++) {
    if (body[i] === '(') depth++;
    else if (body[i] === ')' && --depth === 0) return body.slice(open + 1, i);
  }
  throw new Error('unbalanced condition on the STL branch');
}

test('reading an STL for its geometry does not depend on wanting a thumbnail', () => {
  const guard = stlGuard(enrich);
  /* It no longer depends on the renderer's STL parser either, which is the
   * point carried further: the measurements come from the main-process read of
   * the file already on disk. Requiring `KhaytStl` here meant the whole model
   * had to be base64-ed across and parsed with keepTriangles — the expensive
   * shape — so a mesh too big to DRAW got no volume, no bounding box and no
   * identity, and per-file calibration silently fell back to the machine
   * median for it. */
  assert.match(guard, /hub\.parsePrintFile/,
    'geometry must come from the main-process read, not from shipping the file to the page');
  assert.doesNotMatch(guard, /!rec\.thumb/,
    'geometry is gated on the record having no picture: a file that already has one gets no geometryKey');
  assert.doesNotMatch(guard, /KhaytStlThumb/,
    'geometry is gated on the thumbnail RENDERER: an app without it gets no geometryKey');
  assert.doesNotMatch(guard, /printLibReadBytes/,
    'geometry is gated on the bytes crossing IPC, which is what a large model cannot afford');
});

test('the thumbnail keeps its own preconditions, where they belong', () => {
  // Moving them off the geometry branch must not mean rendering
  // unconditionally — that would overwrite a picture the file already had, or
  // throw on a build with no renderer.
  //
  // Asserted on the branch that FETCHES THE BYTES rather than the one that
  // draws: the transfer is the expensive half, and paying for it only to
  // discard the result at a nested guard would be the same waste one step in.
  const fetchGuard = enrich.match(/if \(([^)]*printLibReadBytes[^)]*)\)/);
  assert.ok(fetchGuard, 'nothing fetches the bytes for a thumbnail any more');
  assert.match(fetchGuard[1], /!rec\.thumb/, 'it would overwrite a picture the record already has');
  assert.match(fetchGuard[1], /KhaytStlThumb/, 'it would throw where the renderer is not loaded');

  const render = enrich.match(/if \(([^)]*)\)\s*\{\s*const r = KhaytStlThumb\.renderStlThumbnail/);
  assert.ok(render, 'the thumbnail render is no longer guarded at all');
});

test('the key is computed before the picture, so a render failure cannot cost it', () => {
  const key = enrich.indexOf('geometryKey = mi.geometryKey');
  const draw = enrich.indexOf('KhaytStlThumb.renderStlThumbnail');
  assert.ok(key > -1, 'geometryKey is no longer computed in enrichPrintFile()');
  assert.ok(draw > -1, 'the thumbnail render went missing');
  assert.ok(key < draw, 'a thumbnail that throws would take the identity down with it');
});

test('identity still goes through MI(), not a bare global', () => {
  // The bug this block already shipped once: the bare name threw a
  // ReferenceError into the catch, and geometry matching silently did nothing.
  assert.match(enrich, /const mi = MI\(\);/, 'MI() lookup gone');
  assert.doesNotMatch(enrich, /(?<!\.)\bKhaytModelIdentity\.geometryKey/,
    'a bare global throws where the module is absent, and the catch hides it');
});
