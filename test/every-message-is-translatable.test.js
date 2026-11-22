'use strict';
/**
 * A message a shop reads must go through t().
 *
 * Khayt ships nine locales and its first market reads Arabic. Sixty-five
 * user-visible messages were English literals that never reached the
 * translation layer — so an Arabic shop saw "Model saved ✓", "Shift started!"
 * and "⚠ Data file could not be read — starting fresh" in English, including
 * the message about its data file being unreadable.
 *
 * The locale-parity guard could not see any of this: every locale had every
 * KEY, and these strings had no key at all.
 *
 * The families collapsed on the way through. Seven "X module not loaded" and
 * seven "…unavailable" say one thing to a shop — the feature is not there — so
 * they share `common.feature_missing`. Naming the module was developer detail.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RENDERER = path.join(ROOT, 'renderer');

/** A literal long enough, and sentence-like enough, to be prose a person reads. */
const LOOKS_LIKE_PROSE = /[a-z]{3}\s+[a-z]{3}/;

/**
 * Calls whose FIRST argument is shown to a person.
 *
 * confirmModal and alert put it in front of them and wait; toast puts it on
 * screen. Anything else — console.warn, an Error message, a key — is not a
 * message a shop reads, and pulling those in would make this guard noise.
 */
const USER_FACING = /\b(toast|confirmModal|alert)\(\s*(['"])((?:[^'"\\]|\\.){8,160})\2/g;

function offenders() {
  const out = [];
  for (const f of fs.readdirSync(RENDERER)) {
    if (!f.endsWith('.js')) continue;
    const src = fs.readFileSync(path.join(RENDERER, f), 'utf8');
    for (const m of src.matchAll(USER_FACING)) {
      if (!LOOKS_LIKE_PROSE.test(m[3])) continue;
      out.push(`renderer/${f}:${src.slice(0, m.index).split('\n').length}  ${m[1]}("${m[3].slice(0, 60)}")`);
    }
  }
  return out;
}

test('no user-visible message is a bare English literal', () => {
  assert.deepEqual(offenders(), [],
    'a message a shop reads does not go through t() — every locale would show it in English');
});

test('the guard can still see one when it is there', () => {
  // A guard that cannot fail is not a guard. This is the exact shape it caught.
  const sample = `function x(){ toast('Model saved and everything is fine'); }`;
  const found = [...sample.matchAll(USER_FACING)].filter((m) => LOOKS_LIKE_PROSE.test(m[3]));
  assert.equal(found.length, 1, 'the pattern no longer matches a bare literal');
});

test('it does not fire on a t() call or a short label', () => {
  // Over-firing would get the guard disabled, which is worse than not having it.
  for (const s of [
    "toast(t('cal.model_saved'))",
    "toast(t('x') || 'Model saved')",          // the fallback idiom is fine
    "toast('OK')",
    "toast('12/34')",
    "confirmModal(t('set.wipe_q'), { danger: true })",
  ]) {
    const found = [...s.matchAll(USER_FACING)].filter((m) => LOOKS_LIKE_PROSE.test(m[3]));
    assert.deepEqual(found.map((m) => m[3]), [], `false positive on: ${s}`);
  }
});

test('the keys that replaced them exist in all nine locales', () => {
  const dir = path.join(RENDERER, 'locales');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  assert.equal(files.length, 9);
  const SAMPLE = [
    'common.feature_missing', 'common.export_failed', 'store.unreadable',
    'cal.model_saved', 'shift.started', 'tg.error', 'mail.send_failed',
  ];
  for (const f of files) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const k of SAMPLE) assert.ok(src.includes(`"${k}"`), `${f} is missing ${k}`);
  }
});

test('the collapsed families really are one key', () => {
  // Seven "module not loaded" and seven "unavailable" became one message. If a
  // later change splits them apart again, that is a decision worth noticing.
  const all = fs.readdirSync(RENDERER).filter((f) => f.endsWith('.js'))
    .map((f) => fs.readFileSync(path.join(RENDERER, f), 'utf8')).join('\n');
  const uses = (all.match(/t\('common\.feature_missing'\)/g) || []).length;
  assert.ok(uses >= 10, `common.feature_missing is used ${uses} times — the family was split up again`);
});

test('the Arabic file is really Arabic, not the English copied across', () => {
  // The failure mode of a bulk translation is nine copies of English. Sampling
  // for Arabic script is enough to catch that.
  const ar = fs.readFileSync(path.join(RENDERER, 'locales', 'ar.js'), 'utf8');
  for (const k of ['common.feature_missing', 'store.unreadable', 'cal.model_saved']) {
    const m = ar.match(new RegExp(`"${k.replace('.', '\\.')}":\\s*"([^"]*)"`));
    assert.ok(m, `ar.js is missing ${k}`);
    assert.match(m[1], /[؀-ۿ]/, `ar.js "${k}" has no Arabic in it`);
  }
});
