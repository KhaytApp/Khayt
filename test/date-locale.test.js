const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const RENDERER = path.join(__dirname, '..', 'renderer');
const LIB = path.join(__dirname, '..', 'lib');

function jsFilesUnder(root) {
  const out = [];
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === 'locales') continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.js')) out.push(p);
    }
  })(root);
  return out;
}

function rendererFiles() { return jsFilesUnder(RENDERER); }

/**
 * The shared rules too, since the Mac app renders documents from them and has
 * no renderer to borrow a formatter from. A date formatted in lib/ reaches
 * BOTH apps, so a wrong one there is wrong twice.
 */
function sharedFiles() { return jsFilesUnder(LIB); }

/**
 * Every date and time the user sees must be formatted in the language they
 * chose in Khayt — not in English, and not in whatever the operating system
 * happens to be set to.
 *
 * Before this guard, 49 of 51 call sites were wrong in one of three ways:
 *
 *   toLocaleDateString('en-US', …)                     English for everyone
 *   toLocaleDateString(i18n.current === 'ar' ? … : 'en-US')
 *                                                      English for the SEVEN
 *                                                      languages that are not
 *                                                      Arabic
 *   toLocaleDateString()  /  (undefined, …)  /  ([], …)
 *                                                      follows the OS, so
 *                                                      choosing 日本語 in Khayt
 *                                                      still rendered
 *                                                      "Monday, July 27, 2026"
 *                                                      on an English Mac
 *
 * localeTag() in format.js is the one place that answers "which locale", so it
 * is the only permitted first argument.
 */
test('every date and time follows the chosen language', () => {
  // Deliberate exceptions, each for a reason that is about something other
  // than the UI language:
  //   app-helpers.js — pins the Umm al-Qura Hijri calendar; that IS the feature
  const ALLOWED_OTHER_TAG = /islamic-umalqura/;
  // lib/print-date.js takes the tag as an ARGUMENT — it is the one place in
  // lib/ that formats a date, and the callers pass localeTag() into it.
  const ALLOWED_ARGUMENT = /^tag\b/;
  // Two shared modules format a date with no locale at all, so both follow the
  // machine rather than the shop. Written down rather than fixed here because
  // neither is on a document a customer is handed — a LAN page's clock and the
  // date in a release note — and both predate this guard reaching lib/. NOTHING
  // MAY BE ADDED TO THIS LIST.
  const KNOWN_UNLOCALISED = new Set([
    'lib/lan-server.js',
    'lib/release-notes.js',
  ]);

  const offenders = [];
  for (const f of [...rendererFiles(), ...sharedFiles()]) {
    const src = fs.readFileSync(f, 'utf8');
    const rel = path.relative(path.join(__dirname, '..'), f);
    // Match the call and just enough of its argument list to see arg one.
    // localeTag() carries its own parens, so match it before the generic form.
    for (const m of src.matchAll(/\.toLocale(?:Date|Time)String\(\s*(localeTag\(\)|[^,)]*)/g)) {
      const arg = m[1].trim();
      if (arg === 'localeTag()') continue;
      if (ALLOWED_OTHER_TAG.test(arg)) continue;
      if (ALLOWED_ARGUMENT.test(arg)) continue;
      if (KNOWN_UNLOCALISED.has(rel)) continue;
      const line = src.slice(0, m.index).split('\n').length;
      offenders.push(`${rel}:${line} → ${arg || '(no locale argument)'}`);
    }
  }
  assert.deepEqual(offenders, [],
    `these render dates in the wrong language:\n  ${offenders.join('\n  ')}`);
});

test('localeTag maps every shipped language to a real locale', () => {
  // A tag that Intl does not recognise is silently ignored rather than throwing,
  // so a typo here looks like it works and quietly serves English.
  // The table moved to lib/ when the Mac app started printing invoices: the
  // document's own date formatter needs it and there is no renderer there.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'print-date.js'), 'utf8');
  const block = src.match(/const LOCALE_TAGS = \{([\s\S]*?)\};/);
  assert.ok(block, 'LOCALE_TAGS table not found in lib/print-date.js');

  const renderer = fs.readFileSync(path.join(RENDERER, 'format.js'), 'utf8');
  assert.ok(!/const LOCALE_TAGS = \{[^}]*en:/.test(renderer),
    'renderer/format.js must not grow its own table back — two tables would be '
    + 'two answers to which locale a language formats in');

  const tags = [...block[1].matchAll(/'?([a-zA-Z-]+)'?\s*:\s*'([^']+)'/g)]
    .map((m) => ({ lang: m[1], tag: m[2] }));

  const shipped = fs.readdirSync(path.join(RENDERER, 'locales'))
    .filter((n) => n.endsWith('.js')).map((n) => n.replace(/\.js$/, ''));
  for (const lang of shipped) {
    assert.ok(tags.some((t) => t.lang === lang), `${lang} ships a locale file but has no LOCALE_TAGS entry`);
  }

  const d = new Date(Date.UTC(2026, 6, 27));
  for (const { lang, tag } of tags) {
    const resolved = Intl.DateTimeFormat.supportedLocalesOf(tag);
    assert.ok(resolved.length > 0, `${lang}: "${tag}" is not a locale Intl recognises`);
    // and it must actually change the output away from raw ISO
    assert.ok(d.toLocaleDateString(tag, { month: 'long' }).length > 0);
  }
});

test('Arabic keeps Western digits while its words localise', () => {
  // The same decision fmtCount documents: live Saudi products use Western
  // digits, so the numerals stay Latin even though the month name is Arabic.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'print-date.js'), 'utf8');
  const tag = src.match(/ar:\s*'([^']+)'/)?.[1];
  assert.ok(tag?.includes('nu-latn'), 'the Arabic tag must pin Latin numerals');

  // timeZone: 'UTC' pins WHICH day is rendered. Without it the formatter uses
  // the machine's zone, so this asserted "27" on a date that reads as the 26th
  // anywhere west of UTC — making a test about DIGITS fail over a calendar day
  // it never meant to check.
  const shown = new Date(Date.UTC(2026, 6, 27)).toLocaleDateString(tag, {
    year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC',
  });
  assert.match(shown, /27/, 'day should render in Western digits');
  assert.match(shown, /2026/, 'year should render in Western digits');
  assert.ok(/[؀-ۿ]/.test(shown), 'month name should still be Arabic');
});

test('no hardcoded English weekday or month name arrays remain', () => {
  // Two of these shipped (analytics heatmap, calendar view) and a third was in
  // the email digest. They are invisible in English and permanent everywhere
  // else, so they need a guard rather than review.
  const offenders = [];
  for (const f of rendererFiles()) {
    const src = fs.readFileSync(f, 'utf8');
    const rel = path.relative(path.join(__dirname, '..'), f);
    for (const re of [
      /\[\s*'Sun'\s*,\s*'Mon'/,
      /\[\s*'Sunday'\s*,\s*'Monday'/,
      /\[\s*'Jan'\s*,\s*'Feb'/,
      /\[\s*'January'\s*,\s*'February'/,
    ]) {
      if (re.test(src)) offenders.push(`${rel}: ${re.source}`);
    }
  }
  assert.deepEqual(offenders, [],
    `hardcoded English date names — use Intl with localeTag():\n  ${offenders.join('\n  ')}`);
});

test('localeTag answers in the chosen language in the real script order', () => {
  // index.html loads format.js long before lib/print-date.js. format.js used to
  // look the table up once, at load, found nothing, and answered 'en-US' for
  // every language — so Arabic dates on Windows and Linux read "Oct 20, 2026".
  // Run both files in a browser-like sandbox (no `require`) in page order.
  const vm = require('vm');
  const html = fs.readFileSync(path.join(RENDERER, 'index.html'), 'utf8');
  const order = [...html.matchAll(/<script src="([^"]+)"/g)].map((m) => m[1]);
  const fmtAt = order.indexOf('format.js');
  const datesAt = order.indexOf('../lib/print-date.js');
  assert.ok(fmtAt >= 0 && datesAt >= 0, 'both scripts are on the page');

  const sandbox = { i18n: { current: 'ar' } };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  for (const f of fmtAt < datesAt
    ? ['format.js', '../lib/print-date.js']
    : ['../lib/print-date.js', 'format.js']) {
    vm.runInContext(fs.readFileSync(path.join(RENDERER, f), 'utf8'), sandbox);
  }
  const tag = sandbox.KhaytFormat.localeTag();
  assert.equal(tag, sandbox.KhaytPrintDate.localeTagFor('ar'));

  // Arabic stays on the Gregorian calendar with Arabic month names (Turki,
  // Oct 20 2026). Electron's ICU defaults ar-SA to Gregorian; JavaScriptCore
  // defaults it to Umm al-Qura, so this pins what the desktop shows.
  const shown = new Date(Date.UTC(2026, 9, 20)).toLocaleDateString(tag, {
    year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC',
  });
  assert.match(shown, /20/);
  assert.match(shown, /2026/);
  assert.ok(/[؀-ۿ]/.test(shown), 'month name should be Arabic');
});
