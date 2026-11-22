'use strict';
/**
 * Two places where a value from outside the shop reached a link or the page
 * without being encoded.
 *
 * 1. A CLIENT'S EMAIL went into a mailto: URL raw. The LAN intake form accepts
 *    an email from anyone who can reach it — over the tunnel, that is anyone —
 *    and stores it after nothing but `trim().slice(0,500)`. An address ending
 *    `...?bcc=someone@else` injected a header into the shop's own reply, so the
 *    reply went to a stranger too, in a compose window that looked normal.
 *
 * 2. AN NFC TAG'S NUMBERS went into innerHTML raw. `parseOpenPrintTagCBOR`
 *    passed `data[34]`, `data[37]`, `data[57]` and friends straight through, and
 *    CBOR can carry a TEXT STRING under any key. The app's CSP (script-src
 *    'self', img-src 'self' data: blob:) stops injected markup running script or
 *    fetching anything, but it can still add controls the delegated [data-act]
 *    handler will act on — the same hole the G-code thumbnail had.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

/* ── 1. mailto ─────────────────────────────────────────────────────────── */

const HOSTILE_EMAIL = 'customer@example.com?bcc=attacker@evil.example&subject=';

test('an address with an injected header cannot add one', () => {
  const url = `mailto:${encodeURIComponent(HOSTILE_EMAIL)}?subject=${encodeURIComponent('Quote')}`;
  // Exactly one '?' — the one that starts the real parameters.
  assert.equal((url.match(/\?/g) || []).length, 1, 'the address introduced a second parameter list');
  assert.ok(!/[?&]bcc=/i.test(url), 'a bcc survived into the link');
  // And the address still round-trips, so ordinary mail is unaffected.
  assert.equal(decodeURIComponent(url.slice('mailto:'.length).split('?')[0]), HOSTILE_EMAIL);
});

test('every mailto in the app encodes its address', () => {
  const files = ['renderer/integrations.js', 'renderer/app-exports.js', 'renderer/expenses.js', 'renderer/shell.js'];
  for (const f of files) {
    for (const m of code(f).matchAll(/mailto:\$\{([^}]*)\}/g)) {
      assert.match(m[1], /encodeURIComponent\(/,
        `${f}: mailto address \`${m[1]}\` is not URL-encoded — a '?' in it injects headers`);
    }
  }
});

test('a plain address still produces a working link', () => {
  const url = `mailto:${encodeURIComponent('sales@shop.sa')}?subject=${encodeURIComponent('Hello')}`;
  assert.equal(url, 'mailto:sales%40shop.sa?subject=Hello');
});

/* ── 2. NFC tag values ─────────────────────────────────────────────────── */

/** parseOpenPrintTagCBOR's coercion, read out of the shipped source. */
function loadCborParser() {
  const src = read('renderer/inventory.js');
  const at = src.indexOf('function parseOpenPrintTagCBOR');
  assert.ok(at > 0, 'parseOpenPrintTagCBOR is gone');
  const end = src.indexOf('\n}', src.indexOf('} catch { return null; }', at));
  const body = src.slice(at, end + 2);
  // The parser needs the CBOR decoder and the material table; stub what it reads.
  const fn = new Function('_decodeCBOR', '_OPT_MATERIALS', `${body}; return parseOpenPrintTagCBOR;`);
  return (data) => fn(() => ({ v: data }), {})(new Uint8Array([0]));
}

const parseCbor = loadCborParser();
const MARKUP = '<button data-act="delete-log" data-id="O-1">x</button>';

test('a tag that puts markup in a temperature yields no markup', () => {
  const r = parseCbor({ 11: 'Brand', 34: MARKUP, 35: MARKUP, 37: MARKUP, 38: MARKUP, 57: MARKUP, 58: MARKUP });
  assert.ok(r, 'the tag did not parse at all');
  for (const k of ['minPrint', 'maxPrint', 'minBed', 'maxBed', 'dryTemp', 'dryTime']) {
    assert.equal(r[k], null, `${k} carried a string through to the page`);
  }
});

test('a tag with a string weight does not reach the page either', () => {
  const r = parseCbor({ 11: 'Brand', 16: MARKUP });
  assert.equal(r.weight, null);
});

test('real numbers are still read, including from a numeric string', () => {
  const r = parseCbor({ 11: 'Brand', 16: 1000, 34: 200, 35: 220, 37: 60, 38: 70, 57: '55', 58: 240 });
  assert.equal(r.weight, 1000);
  assert.equal(r.minPrint, 200);
  assert.equal(r.maxPrint, 220);
  assert.equal(r.dryTemp, 55, 'a numeric string is still a number');
  assert.equal(r.dryTime, 240);
});

test('the panel escapes these values even though the parser coerces them', () => {
  // Defence in depth: one parser forgetting a coercion must not be enough to put
  // markup on a screen built from a stranger's tag.
  const src = code('renderer/inventory.js');
  const at = src.indexOf('function applyNFCResult');
  assert.ok(at > 0, 'applyNFCResult is gone');
  const body = src.slice(at, at + 2500);
  for (const field of ['minPrint', 'maxPrint', 'minBed', 'maxBed', 'dryTemp', 'dryTime', 'weight', 'printTemp', 'bedTemp', 'density']) {
    const raw = new RegExp(`\\$\\{nfcData\\.${field}\\}`);
    assert.ok(!raw.test(body), `nfcData.${field} is interpolated into innerHTML unescaped`);
  }
});

/* ── 3. the same thing refused at the IPC boundary ─────────────────────── */

/** mailtoHasNoHiddenRecipients, loaded out of main.js rather than re-implemented. */
function loadMailtoGuard() {
  const src = read('main.js');
  const a = src.indexOf('function mailtoHasNoHiddenRecipients');
  const b = src.indexOf('function isAllowedExternalUrl');
  assert.ok(a > 0 && b > a, 'the mailto guard is gone from main.js');
  return new Function(`${src.slice(a, b)}; return mailtoHasNoHiddenRecipients;`)();
}

test('the main process refuses a mailto that names another recipient', () => {
  // Defence in depth. Fixed where the URL is built; refused here too, because
  // the main process should not open a recipient the shop cannot see.
  const ok = loadMailtoGuard();
  assert.equal(ok('mailto:a@b.com'), true, 'an address alone must still open');
  assert.equal(ok('mailto:a%40b.com?subject=Hi&body=There'), true, 'ordinary mail must still open');
  assert.equal(ok('mailto:a@b.com?bcc=evil@x.example'), false);
  assert.equal(ok('mailto:a@b.com?cc=evil@x.example'), false, 'nothing in Khayt sends a cc');
  assert.equal(ok('mailto:a@b.com?subject=Hi&to=evil@x.example'), false);
  assert.equal(ok(`mailto:${HOSTILE_EMAIL}?subject=Quote`), false,
    'the exact address an intake form would accept');
});

test('the allowlist consults that guard rather than waving mailto through', () => {
  const src = code('main.js');
  const at = src.indexOf('function isAllowedExternalUrl');
  const body = src.slice(at, at + 400);
  assert.ok(!/startsWith\('mailto:'\)\) return true;/.test(body),
    'any mailto: is opened again, whatever headers it carries');
  assert.match(body, /mailtoHasNoHiddenRecipients\(s\)/);
});
