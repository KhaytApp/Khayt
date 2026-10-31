'use strict';
/**
 * A ZATCA QR that scans and is invalid is worse than no QR at all.
 *
 * The code encodes five TLV tags and ZATCA requires all five present and
 * non-empty. buildZatcaTLV coerced every field with `|| ''`, so a shop that had
 * switched ZATCA on but never entered its VAT number produced this — decoded
 * from the real builder:
 *
 *     tag 1 len 15 value: "Khayt Test Shop"
 *     tag 2 len  0 value: ""            ← the VAT number
 *     tag 3 len 20 value: "2026-09-03T10:00:00Z"
 *     tag 4 len  6 value: "450.00"
 *     tag 5 len  5 value: "58.70"
 *
 * That QR SCANS. An empty box invites a question; a code that reads does not.
 * So the shop hands a customer an invoice that looks compliant and is not, and
 * nothing anywhere says so.
 *
 * The other half: when generation THREW, the catch logged to the console and
 * the invoice rendered with "QR unavailable" in 11px grey — English only, and
 * reading as a cosmetic gap rather than a compliance failure.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const src = read('renderer/invoicing.js');

/** Lift a top-level function out of the shipped source and drive it. */
function lift(name, deps = {}) {
  const at = src.indexOf(`function ${name}(`);
  assert.ok(at > 0, `${name} is gone`);
  const body = src.slice(at, src.indexOf('\n}', at) + 2);
  const keys = Object.keys(deps);
  return new Function(...keys, `${body}; return ${name};`)(...keys.map((k) => deps[k]));
}

/* The rule moved to lib/zatca-qr.js so a second app could produce a compliant
   invoice, and is CALLED here rather than lifted out of the renderer — a test
   that re-implements what it is checking agrees with your mistake.
   `sellerName` is an argument now: the shop's name lives in whichever content
   language it writes, and resolving that is the app's job, not the module's. */
const QR = require('../lib/zatca-qr.js');
const ready = (settings) => QR.readiness(settings, '');

test('a fully configured shop can produce a QR', () => {
  assert.deepEqual(ready({ bizName: 'Khayt Shop', vat: '300000000000003' }), { ok: true, missing: [] });
});

test('a missing VAT number is refused, and named', () => {
  const r = ready({ bizName: 'Khayt Shop', vat: '' });
  assert.equal(r.ok, false, 'a QR with an empty VAT tag would have been drawn');
  assert.deepEqual(r.missing, ['inv.qr_missing_vat']);
});

test('a missing business name is refused too', () => {
  assert.deepEqual(ready({ bizName: '', vat: '300000000000003' }).missing, ['inv.qr_missing_seller']);
});

test('whitespace is not a VAT number', () => {
  assert.equal(ready({ bizName: 'X', vat: '   ' }).ok, false);
  assert.equal(ready({ bizName: '  ', vat: '3000' }).ok, false);
});

test('both missing are both reported, so one fix does not reveal another', () => {
  assert.deepEqual(ready({}).missing, ['inv.qr_missing_seller', 'inv.qr_missing_vat']);
});

test('the builder still produces an empty tag if called directly', () => {
  // The gate is what protects the invoice; this pins WHY the gate is needed, so
  // removing it cannot look harmless.
  const b64 = QR.buildTLV(
    { sellerName: 'S', vatNumber: '', timestamp: 'T', total: '1', vatAmount: '0' },
    { base64: (b) => Buffer.from(b, 'binary').toString('base64') });
  const buf = Buffer.from(b64, 'base64');
  // tag 1 is 'S' (len 1), so tag 2 starts at offset 3.
  assert.equal(buf[3], 2, 'tag 2 is not where expected');
  assert.equal(buf[4], 0, 'the VAT tag is no longer empty — the gate may be unnecessary now');
});

test('the invoice refuses to draw an incomplete QR, and tells the shop', () => {
  const at = src.indexOf('if (settings.enableZatca && !proforma && window.hubAPI?.generateQR)');
  assert.ok(at > 0, 'the ZATCA block is gone');
  const body = src.slice(at, at + 2200);
  assert.match(body, /const ready = zatcaQrReadiness\(settings\)/, 'nothing checks readiness');
  assert.match(body, /if \(!ready\.ok\) throw new Error\('zatca-qr-not-ready'\)/,
    'an incomplete QR is still generated');
  // Specifically the READINESS branch. There are two toasts in this block — the
  // other is for a generation failure — and matching either let a mutation that
  // removed this one pass.
  const at2 = body.indexOf('if (!ready.ok) {');
  assert.ok(at2 > 0, 'the readiness branch is gone');
  const branch = body.slice(at2, body.indexOf('}', body.indexOf('toast', at2)) + 1);
  assert.match(branch, /toast\(t\('inv\.qr_not_compliant'\)/,
    'a shop with a missing VAT number is not told before it hands the invoice over');
});

test('a generation failure keeps its own reason, not the readiness one', () => {
  // "could not be generated" would send a shop with a missing VAT number
  // looking in entirely the wrong place.
  const at = src.indexOf("console.error('ZATCA QR error:'");
  assert.ok(at > 0, 'the catch is gone');
  const body = src.slice(at - 200, at + 400);
  assert.match(body, /if \(!qrProblem\) \{/, 'a readiness reason is overwritten by the generic one');
});

test('the document says it is not compliant, in the shop\'s language', () => {
  // The QR is DECIDED in renderer/invoicing.js — which needs the main process
  // to draw one — and DISPLAYED by lib/invoice-document.js, which is where the
  // empty-box problem is named. The claim follows the half it is about.
  const doc = fs.readFileSync(path.join(ROOT, 'lib', 'invoice-document.js'), 'utf8');
  assert.ok(!/>QR unavailable</.test(doc), 'the untranslated grey placeholder is back');
  assert.match(doc, /escapeHtml\(t\('inv\.qr_not_compliant'\)\)/, 'the document no longer names the problem');
  assert.match(doc, /escapeHtml\(qrProblem \|\| t\('inv\.qr_failed'\)\)/);
});

test('all four strings exist in every locale', () => {
  const dir = path.join(ROOT, 'renderer', 'locales');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  assert.equal(files.length, 9);
  for (const f of files) {
    const s2 = read(path.join('renderer', 'locales', f));
    for (const k of ['inv.qr_not_compliant', 'inv.qr_missing_vat', 'inv.qr_missing_seller', 'inv.qr_failed']) {
      assert.ok(s2.includes(`"${k}"`), `${f} is missing ${k}`);
    }
  }
});

/* ── The payload, now that something other than a browser can build it ─────── */

test('the base64 step is asked for, not guessed at', () => {
  // A module that silently produced no QR on a platform it did not recognise
  // is the failure this whole file exists to prevent. On a host with neither
  // btoa nor Buffer it must refuse loudly.
  const fields = { sellerName: 'S', vatNumber: 'V', timestamp: 'T', total: '1', vatAmount: '0' };
  assert.match(QR.buildTLV(fields, { base64: () => 'SUPPLIED' }), /SUPPLIED/,
    'the host base64 is ignored');
});

test('the five tags are the five tags, in order', () => {
  const b64 = QR.buildTLV({
    sellerName: 'Tuwaiq', vatNumber: '300000000000003',
    timestamp: '2026-09-04T09:15:00Z', total: '1150.00', vatAmount: '150.00',
  }, { base64: (b) => Buffer.from(b, 'binary').toString('base64') });
  const buf = Buffer.from(b64, 'base64');

  const tags = [];
  let i = 0;
  while (i < buf.length) {
    const tag = buf[i];
    const len = buf[i + 1];
    tags.push([tag, buf.subarray(i + 2, i + 2 + len).toString('utf8')]);
    i += 2 + len;
  }
  assert.deepEqual(tags, [
    [1, 'Tuwaiq'],
    [2, '300000000000003'],
    [3, '2026-09-04T09:15:00Z'],
    [4, '1150.00'],
    [5, '150.00'],
  ]);
});

test('a seller name past 127 bytes still encodes its length', () => {
  // BER-TLV needs a two-byte length above 127, and an Arabic shop name reaches
  // it quickly: every character is two bytes in UTF-8.
  const long = 'ت'.repeat(80);                       // 160 bytes
  const b64 = QR.buildTLV({ sellerName: long, vatNumber: 'V', timestamp: 'T', total: '1', vatAmount: '0' },
    { base64: (b) => Buffer.from(b, 'binary').toString('base64') });
  const buf = Buffer.from(b64, 'base64');
  assert.equal(buf[0], 1, 'tag 1');
  assert.equal(buf[1], 0x81, 'the long-form length marker');
  assert.equal(buf[2], 160, 'and the length itself');
  assert.equal(buf.subarray(3, 3 + 160).toString('utf8'), long);
});
