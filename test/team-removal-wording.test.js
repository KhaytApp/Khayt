/**
 * Removing a team member revokes their token. It does NOT erase what already
 * synced to their device, because that data is decrypted with a key the device
 * already holds. The dialog has to say so.
 *
 * See docs/KHAYT-3.0-ORG-DATA-KEY.md — the threat-model table's revoked-device
 * row is the one place a user's intuition ("I removed them, so they're cut off")
 * is wrong, and it gets worse with an org, where a removed device's key reaches
 * every branch rather than one. Rotation is deliberately not in v1, so the only
 * honest thing available is plain words.
 *
 * The locale-parity suite already checks the key exists everywhere and keeps its
 * {email} placeholder. What it cannot check is the two things this depends on:
 * that the text is actually two paragraphs, and that confirmModal renders a
 * newline as a newline. Either one silently reverting turns a clear warning into
 * one run-on line the user skims — which is how it read before.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const R = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
const LOCALES = ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh'];
const KEY = 'team.remove_q_access';

// The bundles attach themselves to globalThis.KhaytLocales rather than exporting,
// the way they do in the renderer; requiring them is what registers them.
const LOC_DIR = path.join(__dirname, '..', 'renderer', 'locales');
for (const f of fs.readdirSync(LOC_DIR).filter((f) => f.endsWith('.js'))) require(path.join(LOC_DIR, f));
const bundle = (loc) => (global.KhaytLocales || {})[loc] || {};

test('the removal dialog uses the key that states the limit', () => {
  const src = R('settings.js');
  assert.match(src, new RegExp(`t\\('${KEY.replace('.', '\\.')}'\\)`),
    'settings.js must ask for the honest string');
  // And the inline fallback must carry the same warning, for the case where a
  // locale bundle fails to load — a silent downgrade to "Remove X?" is exactly
  // the wording this guards against.
  const idx = src.indexOf(KEY);
  const around = src.slice(idx, idx + 900);
  assert.match(around, /reach back and erase/,
    'the inline English fallback must state the limit too');
});

test('every locale states it in two paragraphs, not one run-on line', () => {
  for (const loc of LOCALES) {
    const s = bundle(loc)[KEY];
    assert.ok(s, `${loc}: ${KEY} missing`);
    assert.ok(s.includes('\n\n'), `${loc}: needs a blank line between the question and the limit`);
    assert.ok(s.includes('{email}'), `${loc}: lost the {email} placeholder`);
    const [question, ...rest] = s.split('\n\n');
    assert.ok(question.trim().length > 0, `${loc}: empty question`);
    assert.ok(rest.join(' ').trim().length > 40,
      `${loc}: the second paragraph is too short to be saying anything`);
  }
});

test('confirmModal renders a newline as a newline', () => {
  // Without pre-line the browser collapses the blank line and both paragraphs
  // run together — the string would still be correct and the dialog still wrong.
  const src = R('shell.js');
  const m = src.match(/function confirmModal[\s\S]{0,1200}?<p[^>]*>/);
  assert.ok(m, 'could not find the message paragraph in confirmModal');
  assert.match(m[0], /white-space\s*:\s*pre-line/,
    'the confirm message paragraph must preserve newlines');
});
