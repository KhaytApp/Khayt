'use strict';
/**
 * The Mac app's bundled logic must be `lib/` byte for byte.
 *
 * The native Mac app does not reimplement Khayt's business logic. It runs the
 * same modules in JavaScriptCore, so the tax engine, the pricing, the payment
 * plans and the split-order money are the code this suite already covers —
 * corrections from twenty-two review passes included.
 *
 * SPM resources have to live inside the package, so `mac/KhaytCore/.../JS/`
 * holds copies. A copy is a fork waiting to happen: `lib/` gets a fix, the copy
 * does not, and the Mac app quietly computes last month's VAT. Both would run.
 * Both would return a number.
 *
 * mac/KhaytCore has its own Swift test asserting the same thing AND that the two
 * engines produce identical values — but that needs macOS, and every job here
 * runs on Linux. A macOS runner bills at 10x, which is a decision rather than a
 * detail, so the free half of the guard lives here: the bytes must match. The
 * expensive half runs on a Mac.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const JS_DIR = path.join(ROOT, 'mac/KhaytCore/Sources/KhaytCore/JS');
const ENGINE = path.join(ROOT, 'mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift');

/**
 * The module list, read out of the Swift source rather than kept twice.
 *
 * The block ends at the closing bracket ON ITS OWN LINE. Ending it at the first
 * `]` after the opening one — which is what this did — meant a comment inside
 * the list mentioning `settings.slicers[]` cut the list in half, and everything
 * below that comment stopped being seen by this guard AND by sync-js.sh at the
 * same moment. Both read the list the same wrong way, so the two halves of the
 * drift guard agreed with each other about a list that was not the one the
 * Swift compiler saw.
 *
 * The entries are matched line by line for the same reason: a quoted word
 * inside a comment is not a module.
 */
function declaredModules() {
  const src = fs.readFileSync(ENGINE, 'utf8');
  const at = src.indexOf('static let modules = [');
  assert.ok(at > 0, 'KhaytEngine.modules is gone');
  const end = src.indexOf('\n    ]', at);
  assert.ok(end > at, 'KhaytEngine.modules has no closing bracket on its own line');
  return src.slice(at, end).split('\n')
    .map((line) => line.match(/^\s*"([a-z0-9-]+)",\s*$/))
    .filter(Boolean)
    .map((m) => m[1]);
}

/** The languages listed in KhaytEngine.locales. */
function bundledLocales() {
  const src = fs.readFileSync(path.join(ROOT, 'mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift'), 'utf8');
  const at = src.indexOf('static let locales = [');
  assert.ok(at > 0, 'KhaytEngine.locales is gone');
  // One line, so the first `]` is the right one — but only because it is one
  // line. See the note on `declaredModules`.
  const block = src.slice(at, src.indexOf(']', at));
  return [...block.matchAll(/"([a-zA-Z-]+)"/g)].map((m) => m[1]);
}

test('the module list is read whole, not up to the first bracket in a comment', () => {
  const src = fs.readFileSync(ENGINE, 'utf8');
  const at = src.indexOf('static let modules = [');
  const end = src.indexOf('\n    ]', at);
  const block = src.slice(at, end);

  // The comments in that list explain why each module is there and in that
  // order, and one of them mentions `settings.slicers[]`. A reader that stopped
  // at the first `]` therefore saw 59 of 62 modules — and BOTH halves of this
  // guard read it that way, so they agreed with each other about a list the
  // Swift compiler did not have. The app would have failed at startup loading a
  // file the sync script had stopped copying.
  //
  // This asserts the hazard still exists in the source, so the test is not
  // quietly passing because somebody removed the comment.
  const firstBracket = block.indexOf(']');
  assert.ok(firstBracket > 0, 'no bracket inside the list — this test is no longer testing anything');

  const declared = declaredModules();
  const afterTheBracket = [...block.slice(firstBracket).matchAll(/^\s*"([a-z0-9-]+)",\s*$/gm)]
    .map((m) => m[1]);
  assert.ok(afterTheBracket.length > 0, 'no modules listed after that bracket');
  for (const name of afterTheBracket) {
    assert.ok(declared.includes(name), `${name} is listed after a bracket in a comment and was not read`);
  }
});

test("every locale the Mac app bundles is identical to the renderer's", () => {
  // Same argument as the modules, with a sharper edge: a stale copy here does
  // not compute the wrong number, it shows a shop a word its other app stopped
  // using. Translations are corrected far more often than tax rules.
  const locales = bundledLocales();
  assert.ok(locales.length > 0, 'no locales listed');
  for (const lang of locales) {
    const source = path.join(ROOT, 'renderer/locales', `${lang}.js`);
    const copy = path.join(JS_DIR, `locale-${lang}.js`);
    assert.ok(fs.existsSync(copy), `mac/…/JS/locale-${lang}.js is missing — run mac/sync-js.sh`);
    assert.equal(
      fs.readFileSync(copy, 'utf8'), fs.readFileSync(source, 'utf8'),
      `locale-${lang}.js has drifted from renderer/locales/${lang}.js — run mac/sync-js.sh`
    );
  }
});

test('every module the Mac app bundles is identical to lib/', () => {
  for (const m of declaredModules()) {
    const original = fs.readFileSync(path.join(ROOT, 'lib', `${m}.js`));
    const copy = fs.readFileSync(path.join(JS_DIR, `${m}.js`));
    assert.ok(original.equals(copy),
      `mac/…/JS/${m}.js has drifted from lib/${m}.js — the Mac app would compute `
      + 'different numbers from the Electron app. Run mac/sync-js.sh; do not edit the copy.');
  }
});

test('the Swift list and the bundled folder agree', () => {
  const onDisk = fs.readdirSync(JS_DIR).filter((f) => f.endsWith('.js')).map((f) => f.slice(0, -3)).sort();
  const expected = [...declaredModules(), ...bundledLocales().map((l) => `locale-${l}`)].sort();
  assert.deepEqual(onDisk, expected,
    'a bundled file nobody loads is dead weight; a listed module with no file fails at startup');
});

test('nothing the Mac app bundles needs Node', () => {
  // JavaScriptCore has no `require`, no `fs`, no `process`. A module that grew
  // one of those in lib/ would load here and throw at its first call — from
  // inside a screen, with no clue why.
  //
  // ── CODE THIS MODULE RUNS, NOT CODE IT WRITES ───────────────────────────
  //
  // `medusa-subscriber.js` EMITS TypeScript for the shop's own Medusa project,
  // and that file reads `process.env.MEDUSA_ADMIN_URL` — in Node, on the shop's
  // server, where `process` exists. Read as a flat string the module contains
  // "process.", and this refused to bundle it.
  //
  // So the text INSIDE a template literal is dropped and its `${…}`
  // interpolations are kept. Those are the only part of a template that this
  // runtime evaluates, so a module genuinely reaching for `process.env` in one
  // is still caught — which was checked by putting it there and watching this
  // fail, rather than assumed.
  const runnable = (src) => src.replace(/`(?:[^`\\]|\\.)*`/g, (t) =>
    (t.match(/\$\{[\s\S]*?\}/g) || []).join(' '));
  for (const m of declaredModules()) {
    // ORDER MATTERS. Block comments first — they hold most of the backticks in
    // this repo, as prose. Then TEMPLATES, then line comments: the emitted
    // subscriber opens with `` `// ${SUBSCRIBER_PATH} ``, and stripping line
    // comments first eats that and leaves an unterminated backtick, so the
    // template scanner swallows the wrong half of the file.
    const src = runnable(
      fs.readFileSync(path.join(ROOT, 'lib', `${m}.js`), 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, ''),
    ).replace(/(^|[^:])\/\/.*$/gm, '$1');
    for (const forbidden of ["require('fs')", "require('path')", "require('crypto')", 'process.']) {
      assert.ok(!src.includes(forbidden),
        `lib/${m}.js now uses ${forbidden}, which does not exist in JavaScriptCore — `
        + 'either drop it or take the module off KhaytEngine.modules');
    }
  }
});

test('sync-js.sh exists and reads the same list', () => {
  // The fix for a drift failure. If it kept its own copy of the module list, it
  // would sync the wrong set and the guard above would stay red.
  const sh = fs.readFileSync(path.join(ROOT, 'mac/sync-js.sh'), 'utf8');
  assert.match(sh, /KhaytEngine\.swift/, 'sync-js.sh keeps its own module list instead of reading the Swift one');
});

/* ------------------------------------------------------------------
 * What a Khayt backup does NOT carry, and the Mac restore has to.
 *
 * A backup is built from the renderer's export payload, and two kinds of field
 * never reach the renderer: the credentials (masked as `__KHAYT_MASKED__` on
 * the way out and merged back from disk on every save) and the keys the main
 * process owns. Electron survives that because `mergeStoreSecretsFromDisk`
 * runs on the way to disk; the Mac's Restore.swift does the same thing, and
 * the two constants it needs are pinned here.
 *
 * The failure they guard is silent. Get either wrong and a restore writes the
 * mask over a shop's printer API keys, LAN access codes, Telegram token and
 * cloud token — and the only symptom is printers that stop answering.
 * ------------------------------------------------------------------ */

/** A `static let name = [...]` or `= "..."` out of a Swift source file. */
function swiftConstant(file, name) {
  const src = fs.readFileSync(path.join(ROOT, file), 'utf8');
  const at = src.indexOf(`static let ${name} =`);
  assert.ok(at > 0, `${file} no longer declares ${name}`);
  const line = src.slice(at, src.indexOf('\n', at));
  return [...line.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
}

test('the Mac restore knows every key the main process owns', () => {
  const { MAIN_OWNED_KEYS } = require('../lib/store-io.js');
  assert.deepEqual(
    swiftConstant('mac/KhaytCore/Sources/KhaytApp/Restore.swift', 'mainOwnedKeys'),
    MAIN_OWNED_KEYS,
    'Restore.mainOwnedKeys has drifted from MAIN_OWNED_KEYS in lib/store-io.js — '
    + 'a key missing there is a key a restore deletes from a shop\'s book');
});

test('the Mac restore recognises the mask the renderer holds', () => {
  const { STORE_SECRET_MASK } = require('../lib/store-io.js');
  assert.deepEqual(
    swiftConstant('mac/KhaytCore/Sources/KhaytApp/Restore.swift', 'secretMask'),
    [STORE_SECRET_MASK],
    'Restore.secretMask has drifted from STORE_SECRET_MASK in lib/store-io.js — '
    + 'the restore would no longer recognise a masked credential and would write it to disk');
});
