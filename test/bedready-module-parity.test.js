/**
 * Does Bed Ready load the modules its own screens reach for?
 *
 * Bed Ready and Khayt share renderer files but not shells: `bedready.html` deliberately
 * omits the business half. That works right up until a shared file that Bed Ready DOES load
 * reaches for a library only `index.html` includes — and then nothing errors usefully,
 * because the call sites are all guarded behind `X() || null` and simply return early.
 *
 * That is how geometry-based duplicate detection came to be dead in Bed Ready while a
 * "Setups" button sat on every file card doing nothing: `printfiles.js` shipped, and
 * `model-identity.js` and `print-setups.js` did not. No error, no symptom, two features
 * quietly absent.
 *
 * So this checks the join rather than the features: every Khayt* global a Bed Ready screen
 * depends on must be provided by a script Bed Ready actually loads.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const html = (f) => fs.readFileSync(path.join(ROOT, 'renderer', f), 'utf8');

/** The scripts a shell loads, as repo-relative paths. */
function loaded(shell) {
  return [...html(shell).matchAll(/<script src="([^"]+\.js)"/g)]
    .map((m) => m[1].replace(/^\.\.\//, '').replace(/^(?!lib\/)/, 'renderer/'));
}

/** Which Khayt* globals a file DEFINES. */
function provides(rel) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) return [];
  const src = fs.readFileSync(p, 'utf8');
  // Any assignment that lands the name on an object, whatever that object is called:
  // modules variously use `global.X =`, `g.X =`, `globalThis.X =` and plain `X =`.
  const out = new Set();
  for (const m of src.matchAll(/[\w$]+\.(Khayt[A-Za-z0-9_]+)\s*=[^=]/g)) out.add(m[1]);
  for (const m of src.matchAll(/(?:^|[;{}\n])\s*(?:var|let|const)?\s*(Khayt[A-Za-z0-9_]+)\s*=[^=]/g)) out.add(m[1]);
  return [...out];
}

/** Which Khayt* globals a file READS. */
function consumes(rel) {
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) return [];
  const src = fs.readFileSync(p, 'utf8');
  const out = new Set();
  for (const m of src.matchAll(/\b(Khayt[A-Za-z0-9_]+)\b/g)) out.add(m[1]);
  for (const d of provides(rel)) out.delete(d);
  return [...out];
}

const BR = loaded('bedready.html');

test('every module Bed Ready loads is a file that exists', () => {
  for (const rel of BR) {
    assert.ok(fs.existsSync(path.join(ROOT, rel)), rel + ' is loaded by bedready.html but not in the repo');
  }
});

/**
 * A read is safe if the name is guarded near where it is used — `typeof X`, `window.X`,
 * `globalThis.X`, `global.X`, or `X?.`. It is a bug only when it is BARE and the module
 * that defines it is absent, because then it throws.
 *
 * Nearness matters. printfiles.js guards KhaytModelIdentity behind an accessor at the top
 * of the file and then, four hundred lines down, read it bare anyway. A file-level check
 * would have called that guarded and found nothing.
 */
const GUARD_WINDOW = 200;
/** Blank out comments, keeping offsets so reported line numbers stay true. */
function codeOnly(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/(^|[^:\\])\/\/[^\n]*/g, (m, p1) => p1 + ' '.repeat(m.length - p1.length));
}

function unguardedReads(rel, name) {
  // Comments name these modules constantly — cloud-sync.js's own docstring explains the
  // merge in terms of KhaytSync.applyDeltas. Scanning prose finds bugs that aren't there.
  const src = codeOnly(fs.readFileSync(path.join(ROOT, rel), 'utf8'));
  const bare = new RegExp('(?<![.\\w$])' + name + '\\s*[.(]', 'g');
  const guard = new RegExp('typeof\\s+' + name + '|[\\w$]+\\.' + name + '|' + name + '\\s*\\?\\.');
  const out = [];
  for (const m of src.matchAll(bare)) {
    if (/\?\./.test(src.slice(m.index, m.index + name.length + 3))) continue;
    if (guard.test(src.slice(Math.max(0, m.index - GUARD_WINDOW), m.index))) continue;
    out.push(src.slice(0, m.index).split('\n').length);
  }
  return out;
}

test('no Bed Ready screen reads an absent module without guarding it', () => {
  const available = new Set();
  for (const rel of BR) for (const g of provides(rel)) available.add(g);

  // Sites that already exist, recorded so a NEW one fails rather than joining a crowd.
  // None is fixed here; each is a candidate for the same treatment printfiles.js just got.
  //
  //   dashboard.js       unreachable: bedready-home.js defines its own renderDashboard and
  //                      loads after dashboard.js, so Khayt's never runs in Bed Ready.
  //   app-state.js       throws into an enclosing try, which swallows it — and takes the
  //                      rest of that try block with it. Harmless only while Bed Ready has
  //                      no cloud sync.
  //   settings.js        reachable only once sync has produced resurrected records.
  //   wire-events.js     reachable if an intake path ever fires in Bed Ready, which has no
  //                      intake screen but does load the file that binds it.
  const KNOWN = new Set([
    'renderer/dashboard.js:KhaytAttention',
    'renderer/app-state.js:KhaytSync',
    'renderer/settings.js:KhaytSync',
    'renderer/wire-events.js:KhaytIntakeView',
  ]);

  const bad = [];
  for (const rel of BR) {
    if (!rel.startsWith('renderer/')) continue;
    for (const g of consumes(rel)) {
      if (available.has(g)) continue;             // present in this app; a bare read is fine
      if (KNOWN.has(rel + ':' + g)) continue;
      for (const line of unguardedReads(rel, g)) bad.push(`${rel}:${line} reads ${g} bare, and Bed Ready does not load it`);
    }
  }
  assert.deepEqual(bad, [], 'unguarded reads of modules Bed Ready does not ship:\n  ' + bad.join('\n  '));
});

test('the two that were missing are loaded, and by name', () => {
  // Named explicitly because the general check above passes the moment a call site is
  // deleted, and these two are features Bed Ready is supposed to HAVE.
  assert.ok(BR.includes('lib/model-identity.js'),
    'without model-identity, "already have this model" silently never matches by geometry');
  assert.ok(BR.includes('lib/print-setups.js'),
    'without print-setups, the Setups button on every file card opens nothing');
  assert.ok(BR.includes('lib/webcam.js'),
    'without webcam, machines.js draws no camera panel — Bed Ready monitors a printer it cannot see');
});

test('the camera module loads before the screen that draws it', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer/bedready.html'), 'utf8');
  assert.ok(html.indexOf('lib/webcam.js') < html.indexOf('src="machines.js"'),
    'machines.js reads KhaytWebcam while rendering, so the module has to exist by then');
});

test('print-file screens guard these behind an accessor, never a bare global', () => {
  // The bug was one bare `KhaytModelIdentity.` in a file whose every other use went through
  // MI(). A bare read throws where the module is absent, and the surrounding try/catch —
  // there for malformed meshes — swallowed it.
  const src = fs.readFileSync(path.join(ROOT, 'renderer/printfiles.js'), 'utf8');
  for (const g of ['KhaytModelIdentity', 'KhaytPrintSetups']) {
    const bare = [...src.matchAll(new RegExp('(?<![.\\w])' + g + '\\s*\\.', 'g'))];
    assert.equal(bare.length, 0, g + ' is read bare in printfiles.js; go through the guarded accessor');
  }
});
